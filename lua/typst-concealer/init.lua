--- @class typstconcealer
local M = {}

local kitty_codes = require("typst-concealer.kitty-codes")
local pngData = require("typst-concealer.png-lua")
local truecolor = vim.env.COLORTERM == "truecolor" or vim.env.COLORTERM == "24bit"
-- Just hope there aren't collisions...
-- This is a poor solution
-- FIXME: use some sort of incrementing counter somehow
local pid = vim.fn.getpid() % 256
local full_pid = vim.fn.getpid()

local ffi = require("ffi")
ffi.cdef([[
  typedef struct { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; } winsize_t;
  int ioctl(int fd, unsigned long request, ...);
]])
local TIOCGWINSZ = vim.fn.has("mac") == 1 and 0x40087468 or 0x5413
local _cell_px_w, _cell_px_h
--- PPI computed so that 1 typst text line ≈ 1 terminal cell height (1:1 pixel mapping).
--- nil until refresh_cell_px_size() is called after M.setup().
local _render_ppi

local function refresh_cell_px_size()
  local ws = ffi.new("winsize_t")
  if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_xpixel > 0 and ws.ws_col > 0 then
    _cell_px_w = ws.ws_xpixel / ws.ws_col
    _cell_px_h = ws.ws_ypixel / ws.ws_row
    -- Derive a PPI so "1 line of typst math at math_baseline_pt" == "_cell_px_h px".
    -- math_baseline_pt ≈ ascender+descender height of the typst font in points.
    -- Default 10 pt matches Libertine 11 pt with top/bottom-edge ascender/descender metrics.
    local baseline_pt = (M.config and M.config.math_baseline_pt) or 10
    _render_ppi = math.max(72, math.floor(_cell_px_h * 72 / baseline_pt))
  end
end

--- @class autocmd_event
--- @field id integer
--- @field event string
--- @field group number | nil
--- @field match string
--- @field buf number
--- @field file string
--- @field data any

--- @class typst_ts_match
--- @field [1]? {[1]: TSNode} call_ident
--- @field [2]? {[1]: TSNode} code
--- @field [3] {[1]: TSNode} block

--- @type { [integer]: boolean }
M._enabled_buffers = {}

local is_tmux = vim.env.TMUX ~= nil

--- Sets up the constant typst prelude string
local function setup_prelude()
  if M.config.styling_type == "colorscheme" then
    local color = M.config.color
    if color == nil then
      color = string.format('rgb("#%06X")', vim.api.nvim_get_hl(0, { name = "Normal" })["fg"])
    end
    -- FIXME: lists everything. agony. hope https://github.com/typst/typst/issues/3356 is resolved.
    M._styling_prelude = ""
      .. "#set page(width: auto, height: auto, margin: (x: 0pt, y: 0pt), fill: none)\n"
      .. "#set text("
      .. color
      .. ', top-edge: "ascender", bottom-edge: "descender")\n'
      .. "#set line(stroke: "
      .. color
      .. ")\n"
      .. "#set table(stroke: "
      .. color
      .. ")\n"
      .. "#set circle(stroke: "
      .. color
      .. ")\n"
      .. "#set ellipse(stroke: "
      .. color
      .. ")\n"
      .. "#set line(stroke: "
      .. color
      .. ")\n"
      .. "#set curve(stroke: "
      .. color
      .. ")\n"
      .. "#set polygon(stroke: "
      .. color
      .. ")\n"
      .. "#set rect(stroke: "
      .. color
      .. ")\n"
      .. "#set square(stroke: "
      .. color
      .. ")\n"
      .. ""
  elseif M.config.styling_type == "simple" then
    M._styling_prelude = ""
      .. "#set page(width: auto, height: auto, margin: 0.75pt)\n"
      .. '#set text(top-edge: "ascender", bottom-edge: "descender")\n'
      .. ""
  elseif M.config.styling_type == "none" then
    M._styling_prelude = ""
  end
  --M._styling_prelude = M._styling_prelude .. "#let NVIM_TYPST_CONCEALER = true\n"
end

--- Takes in a value, and if it is nil, return the provided default
--- @generic T
--- @param val T?
--- @param default_val T
--- @return T
local function default(val, default_val)
  if val == nil then
    return default_val
  end
  return val
end

local ns_id = vim.api.nvim_create_namespace("typst-concealer")
-- used for each line of a multiline image
-- please tell me if you know of a better way of overlaying mulitline text
local ns_id2 = vim.api.nvim_create_namespace("typst-concealer-2")
-- used for virt_lines of block-level multi-line formulas (separate from conceal_lines extmark)
local ns_id3 = vim.api.nvim_create_namespace("typst-concealer-3")

--- Escapes a given escape sequence so tmux will pass it through
--- @param message string
--- @return string
local function tmux_escape(message)
  -- Thanks image.nvim
  return "\x1bPtmux;" .. message:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
end

local vim_stdout = assert(vim.loop.new_tty(1, false))
--- Sends a kitty graphics message, adding the APC escape code stuff
--- @param message string
local function send_kitty_escape(message)
  if is_tmux then
    vim_stdout:write(tmux_escape("\x1b_G" .. message .. "\x1b\\"))
  else
    vim_stdout:write("\x1b_G" .. message .. "\x1b\\")
  end
end

---@param range Range4
---@return integer height
local function range_to_height(range)
  local start_row, end_row = range[1], range[3]
  return end_row - start_row + 1
end

-- Thanks https://github.com/3rd/image.nvim/issues/259 for showing how to do this with a code example!

--- @type { [integer]: integer[] | nil }
--- Goes from a text-less multiline ns_id mark to a list of one line ns_id2 marks for concealing
local multiline_marks = {}
--- @type { [integer]: integer }
--- Maps ns_id extmark_id -> ns_id3 virt_lines extmark_id for block multiline formulas
local block_virt_lines_marks = {}
--- @type { [integer]: integer }
local image_id_to_extmark = {}
--- @type { [integer]: boolean }
--- Tracks which image_ids correspond to block-level (display) formulas that
--- should be centered and immune to line wrapping.
local block_formula_ids = {}

--- @class typst_watch_session
--- @field kind 'full' | 'preview'
--- @field bufnr integer
--- @field handle uv_process_t|nil
--- @field stdout uv_pipe_t|nil
--- @field stderr uv_pipe_t|nil
--- @field input_path string
--- @field output_prefix string
--- @field output_template string
--- @field poll_timer uv_timer_t|nil
--- @field items table[]
--- @field page_state table
--- @field last_page_count integer
--- @field stderr_chunks string[]
--- @field dead boolean|nil

--- @type { [integer]: { full?: typst_watch_session, preview?: typst_watch_session } }
local watch_sessions = {}

--- @type { [integer]: { full_items?: table[] } }
local buffer_render_state = {}

local make_sizing_wrap
local on_page_rendered
local clear_image
local hide_extmarks_at_cursor

local function get_buf_dir(bufnr)
  local buf_file = vim.api.nvim_buf_get_name(bufnr)
  if buf_file == nil or buf_file == "" then
    return vim.uv.cwd()
  end
  return vim.fn.fnamemodify(buf_file, ":h")
end

--- Generates the fixed input path for a watch session.
--- @param bufnr integer
--- @param kind 'full' | 'preview'
--- @return string
local function session_input_path(bufnr, kind)
  local dir = get_buf_dir(bufnr)
  local suffix = kind == "preview" and "-preview" or ""
  return dir .. "/.typst-concealer-" .. full_pid .. "-" .. bufnr .. suffix .. ".typ"
end

--- Generates the fixed output template/prefix for a watch session.
--- @param bufnr integer
--- @param kind 'full' | 'preview'
--- @return string template, string prefix
local function session_output_template(bufnr, kind)
  local suffix = kind == "preview" and "-preview" or ""
  local prefix = "/tmp/tty-graphics-protocol-typst-concealer-" .. full_pid .. "-" .. bufnr .. suffix
  return prefix .. "-{p}.png", prefix
end

--- @param path string
local function safe_unlink(path)
  local stat = vim.uv.fs_stat(path)
  if stat ~= nil then
    vim.uv.fs_unlink(path)
  end
end

--- Overwrite a file in-place so watch sees content changes on a stable path.
--- @param path string
--- @param text string
--- @return boolean, string?
local function write_file_in_place(path, text)
  local fd, open_err = vim.uv.fs_open(path, "w", tonumber("644", 8))
  if not fd then
    return false, open_err
  end
  local _, write_err = vim.uv.fs_write(fd, text, 0)
  vim.uv.fs_close(fd)
  if write_err ~= nil then
    return false, write_err
  end
  return true
end

--- @param bufnr integer
--- @param kind 'full' | 'preview'
--- @return typst_watch_session|nil
local function get_watch_session(bufnr, kind)
  local bucket = watch_sessions[bufnr]
  return bucket and bucket[kind] or nil
end

--- @param bufnr integer
--- @param extmark_id integer
local function prepare_extmark_reuse(bufnr, extmark_id)
  local mm = multiline_marks[extmark_id]
  if mm ~= nil then
    if mm.virt_lines then
      local vl_id = block_virt_lines_marks[extmark_id]
      if vl_id then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id3, vl_id)
      end
      block_virt_lines_marks[extmark_id] = nil
    else
      for _, id in pairs(mm) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id2, id)
      end
    end
    multiline_marks[extmark_id] = nil
  end
  Currently_hidden_extmark_ids[extmark_id] = nil
end

--- @param bufnr integer
--- @param item { image_id: integer, extmark_id: integer }|nil
--- @param clear_image_too boolean?
local function cleanup_render_item(bufnr, item, clear_image_too)
  if item == nil then
    return
  end
  prepare_extmark_reuse(bufnr, item.extmark_id)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns_id, item.extmark_id)
  if clear_image_too ~= false then
    clear_image(item.image_id)
  end
  image_id_to_extmark[item.image_id] = nil
  block_formula_ids[item.image_id] = nil
end

--- @param bufnr integer
--- @param kind 'full' | 'preview'
local function stop_watch_session(bufnr, kind)
  local bucket = watch_sessions[bufnr]
  if bucket == nil or bucket[kind] == nil then
    return
  end
  local session = bucket[kind]

  if session.poll_timer and not session.poll_timer:is_closing() then
    session.poll_timer:stop()
    session.poll_timer:close()
  end

  if session.stdout and not session.stdout:is_closing() then
    session.stdout:close()
  end
  if session.stderr and not session.stderr:is_closing() then
    session.stderr:close()
  end
  if session.handle and not session.handle:is_closing() then
    session.handle:kill(15)
    session.handle:close()
  end

  safe_unlink(session.input_path)
  for i = 1, session.last_page_count or 0 do
    safe_unlink(session.output_prefix .. "-" .. i .. ".png")
  end

  bucket[kind] = nil
  if next(bucket) == nil then
    watch_sessions[bufnr] = nil
  end
end

--- @param bufnr integer
local function stop_watch_sessions_for_buf(bufnr)
  stop_watch_session(bufnr, "full")
  stop_watch_session(bufnr, "preview")
end

--- Builds the multi-page typst source for a batch render.
--- @param items { image_id: integer, extmark_id: integer, range: Range4, str: string, prelude_count: integer, is_block?: boolean, needs_swap?: boolean }[]
--- @return string
local function build_batch_document(items)
  local doc = {}

  if M.config.header and M.config.header ~= "" then
    doc[#doc + 1] = M.config.header .. "\n"
  end
  doc[#doc + 1] = M._styling_prelude

  for idx, item in ipairs(items) do
    if idx > 1 then
      doc[#doc + 1] = "#pagebreak()\n"
    end
    for i = 1, item.prelude_count do
      doc[#doc + 1] = runtime_preludes[i]
    end
    local source_rows = item.range[3] - item.range[1] + 1
    local wrap_prefix, wrap_suffix = make_sizing_wrap(source_rows)
    if wrap_prefix ~= "" then
      doc[#doc + 1] = wrap_prefix
    end
    local str = item.str
    if type(str) == "table" then
      for _, s in ipairs(str) do
        doc[#doc + 1] = s
      end
    else
      doc[#doc + 1] = str
    end
    if wrap_suffix ~= "" then
      doc[#doc + 1] = wrap_suffix
    else
      doc[#doc + 1] = "\n"
    end
  end

  return table.concat(doc)
end

--- @param session typst_watch_session
--- @param i integer
--- @param item { image_id: integer, extmark_id: integer, range: Range4, str: string, prelude_count: integer, is_block?: boolean, needs_swap?: boolean }
local function try_render_session_page(session, i, item)
  local page_path = session.output_prefix .. "-" .. i .. ".png"
  local stat = vim.uv.fs_stat(page_path)
  if stat == nil or stat.size == 0 then
    return
  end

  local stamp = tostring(stat.mtime.sec) .. ":" .. tostring(stat.mtime.nsec) .. ":" .. tostring(stat.size)
  local page_state = session.page_state[i] or {}

  -- first sighting after a change: remember only
  if page_state.last_seen ~= stamp then
    page_state.last_seen = stamp
    session.page_state[i] = page_state
    return
  end

  -- second consecutive sighting of same stamp: assume write is stable and render once
  if page_state.rendered == stamp then
    return
  end
  page_state.rendered = stamp
  session.page_state[i] = page_state

  vim.schedule(function()
    local current = get_watch_session(session.bufnr, session.kind)
    if current ~= session then
      return
    end
    on_page_rendered(session.bufnr, page_path, item.image_id, item.extmark_id, item.range)
  end)
end

--- @param session typst_watch_session
local function ensure_session_poller(session)
  if session.poll_timer ~= nil and not session.poll_timer:is_closing() then
    return
  end

  session.poll_timer = vim.uv.new_timer()
  session.poll_timer:start(
    80,
    80,
    vim.schedule_wrap(function()
      if session.dead then
        return
      end
      for i, item in ipairs(session.items or {}) do
        try_render_session_page(session, i, item)
      end
    end)
  )
end

--- @param bufnr integer
--- @param kind 'full' | 'preview'
--- @return typst_watch_session|nil
local function ensure_watch_session(bufnr, kind)
  local existing = get_watch_session(bufnr, kind)
  if existing ~= nil and existing.handle ~= nil and not existing.dead then
    return existing
  end

  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()
  local input_path = session_input_path(bufnr, kind)
  local template, prefix = session_output_template(bufnr, kind)

  local args = { "watch", input_path, template, "--ppi=" .. (_render_ppi or M.config.ppi) }
  if M.config.compiler_args then
    for _, arg in ipairs(M.config.compiler_args) do
      table.insert(args, arg)
    end
  end

  -- typst watch expects the input file to exist before startup.
  local ok, err = write_file_in_place(input_path, M._styling_prelude)
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to create watch input: " .. tostring(err), vim.log.levels.ERROR)
    end)
    return nil
  end

  local session = {
    kind = kind,
    bufnr = bufnr,
    handle = nil,
    stdout = stdout,
    stderr = stderr,
    input_path = input_path,
    output_prefix = prefix,
    output_template = template,
    poll_timer = nil,
    items = {},
    page_state = {},
    last_page_count = 0,
    stderr_chunks = {},
    dead = false,
  }

  local handle
  handle = vim.uv.spawn(M.config.typst_location, {
    stdio = { nil, stdout, stderr },
    args = args,
  }, function()
    session.dead = true
    if session.poll_timer and not session.poll_timer:is_closing() then
      session.poll_timer:stop()
      session.poll_timer:close()
      session.poll_timer = nil
    end
    if stdout and not stdout:is_closing() then
      stdout:close()
    end
    if stderr and not stderr:is_closing() then
      stderr:close()
    end
    if handle and not handle:is_closing() then
      handle:close()
    end
  end)

  if handle == nil then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to spawn typst watch", vim.log.levels.ERROR)
    end)
    return nil
  end

  session.handle = handle

  stdout:read_start(function() end)
  stderr:read_start(function(err2, data)
    if err2 ~= nil then
      return
    end
    if data ~= nil and data ~= "" then
      session.stderr_chunks[#session.stderr_chunks + 1] = data
      if #session.stderr_chunks > 32 then
        table.remove(session.stderr_chunks, 1)
      end
    end
  end)

  watch_sessions[bufnr] = watch_sessions[bufnr] or {}
  watch_sessions[bufnr][kind] = session
  ensure_session_poller(session)
  return session
end

--- @param bufnr integer
--- @param items { image_id: integer, extmark_id: integer, range: Range4, str: string, prelude_count: integer, is_block?: boolean, needs_swap?: boolean }[]
--- @param kind 'full' | 'preview'
local function render_items_via_watch(bufnr, items, kind)
  if #items == 0 then
    stop_watch_session(bufnr, kind)
    return
  end

  local session = ensure_watch_session(bufnr, kind)
  if session == nil then
    return
  end

  for i = #items + 1, session.last_page_count do
    safe_unlink(session.output_prefix .. "-" .. i .. ".png")
  end

  session.items = items
  session.page_state = {}
  session.last_page_count = #items

  local doc_str = build_batch_document(items)
  local ok, err = write_file_in_place(session.input_path, doc_str)
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to update watch input: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

--- Checks whether a math/code range is a block-level (display) formula that
--- occupies its own line(s), as opposed to inline content within a paragraph.
--- @param range Range4
--- @param bufnr integer
--- @param block_type? string treesitter node type ("math" or "code")
--- @return boolean
local function is_block_formula(range, bufnr, block_type)
  local start_row, start_col, end_row, end_col = range[1], range[2], range[3], range[4]
  -- Multiline formulas are always block-level
  if end_row > start_row then
    return true
  end
  -- Single-line code expressions (#tag.idea, #var, etc.) are always inline
  if block_type == "code" then
    return false
  end
  -- Single-line math: block-level if the formula occupies the entire (trimmed) line
  local line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1] or ""
  local trimmed = line:match("^%s*(.-)%s*$") or ""
  local formula_text = line:sub(start_col + 1, end_col)
  return trimmed == formula_text
end

--- Returns the number of padding columns to center an image of the given width.
--- @param natural_cols integer  image width in terminal cells
--- @return integer padding  number of leading space characters (0 if image >= window)
local function center_padding(natural_cols)
  local win_width = vim.api.nvim_win_get_width(0)
  if natural_cols >= win_width then
    return 0
  end
  return math.floor((win_width - natural_cols) / 2)
end

--- Places the unicode characters to render a given image id over a range
--- @param image_id integer
--- @param range Range4
--- @param extmark_id? integer|nil
--- @param concealing? boolean should the text be concealing or non-concealing
--- @param is_block? boolean whether this is a block-level (display) formula
--- @return integer
local function place_image_extmark(image_id, range, extmark_id, concealing, is_block)
  -- TODO: take bufnr
  local start_row, start_col, end_row, end_col = range[1], range[2], range[3], range[4]
  local height = range_to_height(range)
  --- @type integer
  local new_extmark_id = nil

  if is_block then
    block_formula_ids[image_id] = true
  else
    block_formula_ids[image_id] = nil
  end

  if height == 1 then
    if concealing == false then
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, ns_id, start_row, start_col, {
        id = extmark_id,
        virt_lines = { { { "" } } },
        virt_text_pos = "overlay",
        invalidate = true,
        end_col = end_col,
        end_row = end_row,
      })
    elseif is_block then
      -- Block-level single-line: use overlay to avoid line wrapping, will be centered later
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, ns_id, start_row, start_col, {
        id = extmark_id,
        virt_text = { { "" } },
        virt_text_pos = "overlay",
        conceal = "",
        invalidate = true,
        end_col = end_col,
        end_row = end_row,
      })
    else
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, ns_id, start_row, start_col, {
        id = extmark_id,
        virt_text = { { "" } },
        virt_text_pos = "inline",
        conceal = "",
        invalidate = true,
        end_col = end_col,
        end_row = end_row,
      })
    end
  else
    if concealing == false then
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, ns_id, start_row, start_col, {
        id = extmark_id,
        invalidate = true,
        virt_text = { { "" } },
        -- this is used for determining the virt_text_pos of the child ns_id2 extmarks
        -- this extmark will never actually have text
        virt_text_pos = "right_align",
        end_col = end_col,
        end_row = end_row,
      })
    elseif is_block then
      -- Block-level multi-line: use conceal_lines (ns_id) + virt_lines (ns_id3) so that
      -- 'wrap' does not insert phantom screen lines between image rows.
      -- conceal_lines and virt_lines must live in separate extmarks/namespaces because
      -- Neovim does not render virt_lines on a line that is itself concealed.
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, ns_id, start_row, start_col, {
        id = extmark_id,
        invalidate = true,
        --- @diagnostic disable-next-line: assign-type-mismatch
        conceal_lines = "",
        end_col = end_col,
        end_row = end_row,
      })
      -- Place a separate ns_id3 extmark on the line AFTER the concealed range so that
      -- its virt_lines (above = true) appear right where the formula was.
      local line_count = vim.api.nvim_buf_line_count(0)
      local vl_row = end_row + 1
      if vl_row >= line_count then
        vim.api.nvim_buf_set_lines(0, line_count, line_count, false, { "" })
      end
      local vl_id = vim.api.nvim_buf_set_extmark(0, ns_id3, vl_row, 0, {
        virt_lines = { { { "", "" } } }, -- placeholder, filled in conceal_for_image_id
        virt_lines_above = true,
      })
      block_virt_lines_marks[new_extmark_id] = vl_id
      -- multiline_marks entry marks this as a virt_lines-based multiline block
      multiline_marks[new_extmark_id] = { virt_lines = true }
    else
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, ns_id, start_row, start_col, {
        id = extmark_id,
        invalidate = true,
        virt_text = { { "" } },
        -- this is used for determining the virt_text_pos of the child ns_id2 extmarks
        -- this extmark will never actually have text
        virt_text_pos = "overlay",
        end_col = end_col,
        end_row = end_row,
      })
      -- the extmarks will be added later
      multiline_marks[new_extmark_id] = {}
    end
  end

  image_id_to_extmark[image_id] = new_extmark_id
  return new_extmark_id
end

--- Rebuild an existing extmark in-place for a new range only when the new image is ready.
--- This keeps the old rendered image visible until swap time.
--- @param bufnr integer
--- @param image_id integer
--- @param extmark_id integer
--- @param range Range4
--- @param is_block boolean
local function swap_extmark_to_range(bufnr, image_id, extmark_id, range, is_block)
  prepare_extmark_reuse(bufnr, extmark_id)
  local new_id = place_image_extmark(image_id, range, extmark_id, nil, is_block)
  image_id_to_extmark[image_id] = new_id
end

--- Updates the text for an existing extmark
--- @param bufnr integer
--- @param extmark_id integer
--- @param virt_text_data table  virt_text format: { {text, hl_group}, ... } or table of such for multiline
--- @param skip_hide_check? boolean | nil
local function update_extmark_text(bufnr, extmark_id, virt_text_data, skip_hide_check)
  if (skip_hide_check ~= true) and Currently_hidden_extmark_ids[extmark_id] ~= nil then
    Currently_hidden_extmark_ids[extmark_id] = virt_text_data
    return
  end
  local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns_id, extmark_id, { details = true })
  if #m == 0 then
    -- The extmark is missing.
    -- This just means it was deleted at some point between creation and the image finishing rendering, which is bound to happen sometimes.
    -- This is okay, it just means we can't actually display text, not a catastrophic failure so we just fail quietly.
    return
  end
  --- @type integer, integer, vim.api.keyset.extmark_details
  local row, col, opts = m[1], m[2], m[3]

  local height = range_to_height({ row, col, opts.end_row, opts.end_col })
  if height ~= 1 then
    local mm = multiline_marks[extmark_id]
    -- virt_lines-based block multiline: update is handled in conceal_for_image_id, skip here
    if mm and mm.virt_lines then
      return
    end
    if mm then
      for _, id in pairs(mm) do
        vim.api.nvim_buf_del_extmark(bufnr, ns_id2, id)
      end
    end
    multiline_marks[extmark_id] = {}
    for i = 1, height do
      local lines = vim.api.nvim_buf_get_lines(0, row, opts.end_row + 1, false)
      local conceal = nil
      if opts.virt_text_pos ~= "right_align" then
        conceal = ""
      end
      local virt_text_line = virt_text_data[i]
      -- Ensure virt_text_line is in the correct format: { {text, hl}, ... }
      if
        type(virt_text_line) == "string" or (type(virt_text_line) == "table" and type(virt_text_line[1]) == "string")
      then
        -- If it's a string or {string, hl}, wrap it
        virt_text_line = { virt_text_line }
      end
      local new_id = vim.api.nvim_buf_set_extmark(0, ns_id2, row + i - 1, 0, {
        virt_text = virt_text_line,
        conceal = conceal,
        virt_text_pos = opts.virt_text_pos,
        end_col = #lines[i],
        end_row = row + i - 1,
      })
      table.insert(multiline_marks[extmark_id], new_id)
    end
  elseif opts.virt_text_pos == "inline" or (opts.virt_text_pos == "overlay" and opts.conceal == "") then
    vim.api.nvim_buf_set_extmark(0, ns_id, row, col, {
      id = extmark_id,
      virt_text = virt_text_data,
      virt_text_pos = opts.virt_text_pos,
      invalidate = opts.invalidate,
      end_col = opts.end_col,
      end_row = opts.end_row,
      --- @diagnostic disable-next-line nvim type is wrong
      conceal = "",
    })
  else
    vim.api.nvim_buf_set_extmark(0, ns_id, row, col, {
      id = extmark_id,
      virt_lines = { virt_text_data },
      virt_text_pos = opts.virt_text_pos,
      invalidate = opts.invalidate,
      end_col = opts.end_col,
      end_row = opts.end_row,
      --- @diagnostic disable-next-line nvim type is wrong
      conceal = opts.conceal,
    })
  end
end

--- Adds the concealing unicode characters to the relevant extmark(s) for the given image_id
--- @param bufnr integer
--- @param image_id integer
--- @param natural_cols integer
--- @param natural_rows integer
--- @param source_rows integer
local function conceal_for_image_id(bufnr, image_id, natural_cols, natural_rows, source_rows)
  local extmark_id = image_id_to_extmark[image_id]
  local multiline_extmark_ids = multiline_marks[extmark_id]

  local hl_group = "typst-concealer-image-id-" .. tostring(image_id)
  vim.api.nvim_set_hl(0, hl_group, { fg = string.format("#%06X", image_id) })

  local is_block = block_formula_ids[image_id]
  local pad = is_block and center_padding(natural_cols) or 0
  local pad_str = pad > 0 and string.rep(" ", pad) or nil

  local function make_row_list(i)
    local line = ""
    for j = 0, natural_cols - 1 do
      line = line .. kitty_codes.placeholder .. kitty_codes.diacritics[i] .. kitty_codes.diacritics[j + 1]
    end
    if pad_str then
      return { { pad_str, "" }, { line, hl_group } }
    end
    return { { line, hl_group } }
  end

  if multiline_extmark_ids == nil then
    update_extmark_text(bufnr, extmark_id, make_row_list(1))
  elseif multiline_extmark_ids.virt_lines then
    local render_rows = natural_rows
    local lines = {}
    local above_blank = 0
    if natural_rows < source_rows then
      above_blank = math.floor((source_rows - natural_rows) / 2)
      render_rows = source_rows
    end
    for i = 1, render_rows do
      local image_row = i - above_blank
      if image_row < 1 or image_row > natural_rows then
        lines[i] = { { "", hl_group } }
      elseif image_row >= #kitty_codes.diacritics then
        lines[i] = {
          {
            "This image attempted to render taller than "
              .. #kitty_codes.diacritics
              .. " lines. If you legitimately see this in a real document, open an issue.",
            hl_group,
          },
        }
      else
        lines[i] = make_row_list(image_row)
      end
    end
    if Currently_hidden_extmark_ids[extmark_id] ~= nil then
      Currently_hidden_extmark_ids[extmark_id] = { block_virt_lines = true, virt_lines_data = lines }
      return
    end
    local vl_id = block_virt_lines_marks[extmark_id]
    if vl_id then
      local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns_id3, vl_id, { details = true })
      if #m > 0 then
        local row, col = m[1], m[2]
        vim.api.nvim_buf_set_extmark(bufnr, ns_id3, row, col, {
          id = vl_id,
          virt_lines = lines,
          virt_lines_above = true,
        })
      end
    end
  else
    local lines = {}
    if natural_rows < source_rows then
      local above_blank = math.floor((source_rows - natural_rows) / 2)
      for i = 1, source_rows do
        local image_row = i - above_blank
        if image_row < 1 or image_row > natural_rows then
          lines[i] = { { "", hl_group } }
        elseif image_row >= #kitty_codes.diacritics then
          lines[i] = {
            {
              "This image attempted to render taller than "
                .. #kitty_codes.diacritics
                .. " lines. If you legitimately see this in a real document, open an issue.",
              hl_group,
            },
          }
        else
          lines[i] = make_row_list(image_row)
        end
      end
    else
      for i = 1, source_rows do
        if i >= #kitty_codes.diacritics then
          lines[i] = {
            {
              "This image attempted to render taller than "
                .. #kitty_codes.diacritics
                .. " lines. If you legitimately see this in a real document, open an issue.",
              hl_group,
            },
          }
        else
          lines[i] = make_row_list(i)
        end
      end
    end
    update_extmark_text(bufnr, extmark_id, lines)
  end
end

--- Takes in a range and returns the string contained within that range
--- @param range Range4
--- @param bufnr integer
--- @return string
local function range_to_string(range, bufnr)
  local start_row, start_col, end_row, end_col = range[1], range[2], range[3], range[4]
  local content = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
  if start_row == end_row then
    content[1] = string.sub(content[1], start_col + 1, end_col)
  else
    content[1] = string.sub(content[1], start_col + 1)
    content[#content] = string.sub(content[#content], 0, end_col)
  end
  return table.concat(content, "\n")
end

--- Checks if parent_range contains child_range
---@param parent_range Range4
---@param child_range Range4
---@return boolean
local function range_contains(parent_range, child_range)
  local _, _, end_row1, end_col1 = parent_range[1], parent_range[2], parent_range[3], parent_range[4]
  local _, _, end_row2, end_col2 = child_range[1], child_range[2], child_range[3], child_range[4]
  if end_row1 > end_row2 or (end_row1 == end_row2 and end_col1 >= end_col2) then
    return true
  end
  return false
end

--- Tells terminal to read the image and link image id -> image
--- @param path string
--- @param image_id integer
--- @param width integer
--- @param height integer
local function create_image(path, image_id, width, height)
  path = vim.base64.encode(path)
  send_kitty_escape("q=2,f=100,t=t,i=" .. image_id .. ";" .. path)
  send_kitty_escape("q=2,a=p,U=1,i=" .. image_id .. ",c=" .. width .. ",r=" .. height)
end

---@param image_id integer
clear_image = function(image_id)
  send_kitty_escape("q=2,a=d,d=i,i=" .. image_id)
  image_ids_in_use[image_id] = nil
end

--- Generates a filename for a given image id and buffer
--- @param id integer
--- @param bufnr integer
--- @return string
local function typst_file_path(id, bufnr)
  return "/tmp/tty-graphics-protocol-typst-concealer-" .. full_pid .. "-" .. bufnr .. "-" .. id .. ".png"
end

--- @type vim.Diagnostic[]
local diagnostics = {}

--- Builds a { prefix, suffix } pair that wraps formula content in a sizing context block.
--- Using an explicit `#context { let __it = ..content..; ... block(...) }` instead of
--- `#show: __it => context { ... }` avoids the "pagebreaks not allowed inside containers"
--- error that the show-rule approach causes in batch (multi-page) documents.
--- @param source_rows integer
--- @return string prefix, string suffix   both "" when cell size is unknown
make_sizing_wrap = function(source_rows)
  if _cell_px_h and _cell_px_w then
    local baseline_pt = M.config.math_baseline_pt
    local cell_w_pt = baseline_pt * (_cell_px_w / _cell_px_h)
    if source_rows == 1 then
      return string.format("#context { let __it = [", baseline_pt, cell_w_pt),
        string.format(
          "]; let __d = measure(__it); let __mh = %gpt; let __mw = %gpt; let __rows = __d.height / __mh; let __cols = calc.max(1, calc.ceil(__d.width / __mw - 0.001)); let __tw = __cols * __mw; if __rows <= 1.5 { block(width: __tw, height: __mh, clip: true, align(horizon, __it)) } else { let __r = calc.max(1, calc.ceil(__rows - 0.001)); block(width: __tw, height: __r * __mh, align(horizon, __it)) } }\n",
          baseline_pt,
          cell_w_pt
        )
    else
      return string.format("#context { let __it = [", baseline_pt, cell_w_pt),
        string.format(
          "]; let __d = measure(__it); let __mh = %gpt; let __mw = %gpt; let __rows = calc.max(1, calc.ceil(__d.height / __mh - 0.001)); let __cols = calc.max(1, calc.ceil(__d.width / __mw - 0.001)); let __th = __rows * __mh; let __tw = __cols * __mw; block(width: __tw, height: __th, align(horizon, __it)) }\n",
          baseline_pt,
          cell_w_pt
        )
    end
  elseif _cell_px_h then
    local baseline_pt = M.config.math_baseline_pt
    if source_rows == 1 then
      return "#context { let __it = [",
        string.format(
          "]; let __d = measure(__it); let __mh = %gpt; let __rows = __d.height / __mh; if __rows <= 1.5 { block(width: __d.width, height: __mh, clip: true, align(horizon, __it)) } else { let __r = calc.max(1, calc.ceil(__rows - 0.001)); block(width: __d.width, height: __r * __mh, align(horizon, __it)) } }\n",
          baseline_pt
        )
    else
      return "#context { let __it = [",
        string.format(
          "]; let __d = measure(__it); let __mh = %gpt; let __rows = calc.max(1, calc.ceil(__d.height / __mh - 0.001)); let __th = __rows * __mh; block(width: __d.width, height: __th, align(horizon, __it)) }\n",
          baseline_pt
        )
    end
  end
  return "", ""
end

--- Handles one rendered page after a batch compile finishes.
--- @param bufnr integer
--- @param page_path string path to the PNG file
--- @param image_id integer
--- @param extmark_id integer
--- @param original_range Range4
on_page_rendered = function(bufnr, page_path, image_id, extmark_id, original_range)
  local source_rows = range_to_height(original_range)
  local success, data = pcall(pngData, page_path)
  if not success then
    return
  end

  local natural_rows, natural_cols
  if _cell_px_w and _cell_px_h then
    natural_rows = math.max(1, math.floor(data.height / _cell_px_h + 0.5))
    natural_cols = math.max(1, math.floor(data.width / _cell_px_w + 0.5))
  else
    natural_rows = source_rows
    natural_cols = math.ceil((data.width / data.height) * 2) * source_rows
  end

  if source_rows == 1 and natural_rows > 1 then
    if _cell_px_w and _cell_px_h then
      local aspect = data.width / data.height
      natural_cols = math.max(1, math.floor(_cell_px_h * aspect / _cell_px_w + 0.5))
    else
      natural_cols = math.max(1, math.floor((data.width / data.height) * 2))
    end
    natural_rows = 1
  end

  if natural_cols >= #kitty_codes.diacritics then
    natural_cols = #kitty_codes.diacritics - 1
  end

  -- Swap extmark to new range before creating the new image
  local state = buffer_render_state[bufnr]
  if state and state.full_items then
    for _, item in ipairs(state.full_items) do
      if item.image_id == image_id then
        if item.needs_swap then
          swap_extmark_to_range(bufnr, image_id, extmark_id, item.range, item.is_block or false)
          item.needs_swap = false
        end
        break
      end
    end
  end

  create_image(page_path, image_id, natural_cols, natural_rows)
  conceal_for_image_id(bufnr, image_id, natural_cols, natural_rows, source_rows)
end

--- Compile a single formula (watch-session backed for the live preview path).
--- @param bufnr integer
--- @param image_id integer
--- @param original_range Range4
--- @param str string
--- @param extmark_id integer
--- @param prelude_count integer
--- @param is_live_preview boolean
local function compile_image(bufnr, image_id, original_range, str, extmark_id, prelude_count, is_live_preview)
  render_items_via_watch(bufnr, {
    { image_id = image_id, extmark_id = extmark_id, range = original_range, str = str, prelude_count = prelude_count },
  }, is_live_preview and "preview" or "full")
end

-- FIXME: this is bad. terrible even. fix it.
image_ids_in_use = {}
---@param bufnr integer
---@return integer
local function new_image_id(bufnr)
  for i = pid, 2 ^ 16 + pid - 1 do
    if image_ids_in_use[i] == nil then
      image_ids_in_use[i] = bufnr
      return i
    end
  end

  print([[
[typst-concealer] >65536 image ids in use, overflowing. This is probably a bug, you're looking at a very long document or a lot of documents.
Open an issue if you see this, the cap can be increased if someone actually needs it.
]])
  image_ids_in_use = {}
  return new_image_id(bufnr)
end

local function hard_reset_buf(bufnr)
  local state = buffer_render_state[bufnr]
  if state and state.full_items then
    for _, item in ipairs(state.full_items) do
      cleanup_render_item(bufnr, item, true)
    end
  end
  buffer_render_state[bufnr] = nil

  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id2, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id3, 0, -1)
  Live_preview_extmark_id = nil
  Currently_hidden_extmark_ids = {}
  multiline_marks = {}
  block_virt_lines_marks = {}
  diagnostics = {}
  runtime_preludes = {}
  block_formula_ids = {}

  for id, image_bufnr in pairs(image_ids_in_use) do
    if bufnr == image_bufnr then
      clear_image(id)
    end
  end
end

local function clear_diagnostics(bufnr)
  vim.schedule(function()
    vim.diagnostic.reset(ns_id, bufnr)
  end)
end

runtime_preludes = {}

--- @param bufnr? integer Which buffer to render, defaulting to current buffer
local function render_buf(bufnr)
  bufnr = default(bufnr, vim.fn.bufnr())
  clear_diagnostics(bufnr)

  if M._enabled_buffers[bufnr] ~= true then
    hard_reset_buf(bufnr)
    stop_watch_session(bufnr, "full")
    return
  end

  diagnostics = {}
  runtime_preludes = {}

  local parser = vim.treesitter.get_parser(bufnr)
  local tree = parser:parse()[1]:root()

  --- @type { [integer]: { [1]: Range4, [2]: integer, [3]: string } }
  local ranges = {}
  local prev_range = nil

  for _, match, _ in M._typst_query:iter_matches(tree, bufnr, nil, nil, { all = true }) do
    --- @cast match typst_ts_match
    local block_type = match[3][1]:type()
    local start_row, start_col, end_row, end_col = match[3][1]:range()

    if prev_range ~= nil and range_contains(prev_range, { start_row, start_col, end_row, end_col }) then
      goto continue
    end

    if block_type == "math" then
      local image_id = new_image_id(bufnr)
      ranges[image_id] = { { start_row, start_col, end_row, end_col }, #runtime_preludes, "math" }
      prev_range = { start_row, start_col, end_row, end_col }
    elseif block_type == "code" then
      local code_type = match[2][1]:type()
      local call_ident = ""
      if match[1] ~= nil then
        local a, b, c, d = match[1][1]:range()
        call_ident = range_to_string({ a, b, c, d }, bufnr)
      end
      if
        (not vim.list_contains({ "let", "set", "import", "show" }, code_type))
        and (not vim.list_contains({ "pagebreak" }, call_ident))
      then
        local image_id = new_image_id(bufnr)
        ranges[image_id] = { { start_row, start_col, end_row, end_col }, #runtime_preludes, "code" }
        prev_range = { start_row, start_col, end_row, end_col }
      end

      if vim.list_contains({ "let", "set", "import", "show" }, code_type) then
        runtime_preludes[#runtime_preludes + 1] = range_to_string({ start_row, start_col, end_row, end_col }, bufnr)
          .. "\n"
      end
    end
    ::continue::
  end

  local batch_items = {}
  local sorted_entries = {}
  for id, payload in pairs(ranges) do
    sorted_entries[#sorted_entries + 1] = {
      image_id = id,
      range = payload[1],
      prelude_count = payload[2],
      node_type = payload[3],
    }
  end
  table.sort(sorted_entries, function(a, b)
    local ar, br = a.range, b.range
    if ar[1] ~= br[1] then
      return ar[1] < br[1]
    end
    return ar[2] < br[2]
  end)

  local prev_items = (buffer_render_state[bufnr] and buffer_render_state[bufnr].full_items) or {}

  for idx, entry in ipairs(sorted_entries) do
    local range, prelude_count, node_type = entry.range, entry.prelude_count, entry.node_type
    local block = is_block_formula(range, bufnr, node_type)
    local str = range_to_string(range, bufnr)

    local prev_item = prev_items[idx]
    local image_id, extmark_id

    if prev_item ~= nil then
      -- Reuse existing image_id and extmark_id without rebuilding yet
      -- The extmark will be swapped to new range in on_page_rendered()
      image_id = prev_item.image_id
      extmark_id = prev_item.extmark_id
    else
      image_id = new_image_id(bufnr)
      extmark_id = place_image_extmark(image_id, range, nil, nil, block)
    end

    batch_items[#batch_items + 1] = {
      image_id = image_id,
      extmark_id = extmark_id,
      range = range,
      str = str,
      prelude_count = prelude_count,
      is_block = block,
      needs_swap = prev_item ~= nil,
    }
  end

  for i = #batch_items + 1, #prev_items do
    cleanup_render_item(bufnr, prev_items[i], true)
  end

  buffer_render_state[bufnr] = buffer_render_state[bufnr] or {}
  buffer_render_state[bufnr].full_items = batch_items

  vim.schedule(function()
    render_items_via_watch(bufnr, batch_items, "full")
  end)
  hide_extmarks_at_cursor()
end

--- @alias virt_text {[1]: string, [2]: string}[]

--- @type {[integer]: virt_text | { block_virt_lines: true, virt_lines_data: table }}
Currently_hidden_extmark_ids = {}

---@param bufnr integer
---@param id integer
---@param row integer
---@param col integer
---@param opts vim.api.keyset.extmark_details
---@param new_hidden table
---@param namespace_id integer
local function hide_extmark(bufnr, id, row, col, opts, new_hidden, namespace_id) end

hide_extmarks_at_cursor = function()
  local bufnr = vim.fn.bufnr()

  --- @type {[integer]: virt_text}
  local new_hidden = {}

  local mode = vim.api.nvim_get_mode().mode
  if not (M.config.conceal_in_normal and mode:find("n", 1, true) ~= nil) then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    local range_line = vim.fn.getpos("v")[2] - 1

    local extmarks
    if range_line > cursor_line then
      extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, { cursor_line, 0 }, { range_line, -1 }, {
        overlap = true,
        details = true,
      })
    else
      extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, { range_line, 0 }, { cursor_line, -1 }, {
        overlap = true,
        details = true,
      })
    end

    for _, extmark in ipairs(extmarks) do
      local id = extmark[1]
      if multiline_marks[id] ~= nil then
        local mm = multiline_marks[id]
        if mm.virt_lines then
          if new_hidden[id] ~= nil then
          elseif Currently_hidden_extmark_ids[id] ~= nil then
            new_hidden[id] = Currently_hidden_extmark_ids[id]
            Currently_hidden_extmark_ids[id] = nil
          else
            local vl_id = block_virt_lines_marks[id]
            local saved_vl = nil
            if vl_id then
              local vm = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns_id3, vl_id, { details = true })
              if #vm > 0 and vm[3] then
                saved_vl = vm[3].virt_lines
                vim.api.nvim_buf_set_extmark(bufnr, ns_id3, vm[1], vm[2], {
                  id = vl_id,
                  virt_lines = {},
                  virt_lines_above = true,
                })
              end
            end
            local em = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns_id, id, { details = true })
            if #em > 0 then
              local row, col, opts = em[1], em[2], em[3]
              vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, col, {
                id = id,
                invalidate = true,
                end_col = opts.end_col,
                end_row = opts.end_row,
              })
            end
            new_hidden[id] = { block_virt_lines = true, virt_lines_data = saved_vl }
          end
          goto continue
        end
        if new_hidden[id] ~= nil then
        elseif Currently_hidden_extmark_ids[id] ~= nil then
          new_hidden[id] = Currently_hidden_extmark_ids[id]
          Currently_hidden_extmark_ids[id] = nil
        else
          if extmark[4].virt_text_pos == "right_align" then
            goto continue
          end
          local text = {}
          for _, new_id in ipairs(mm) do
            local new_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns_id2, new_id, { details = true })
            local opts = new_mark[3]

            text[#text + 1] = opts.virt_text
            vim.api.nvim_buf_del_extmark(bufnr, ns_id2, new_id)
          end
          new_hidden[id] = text
          Currently_hidden_extmark_ids[id] = nil
        end
      else
        local id2, row, col, opts = extmark[1], extmark[2], extmark[3], extmark[4]
        if Currently_hidden_extmark_ids[id2] ~= nil then
          new_hidden[id2] = Currently_hidden_extmark_ids[id2]
          Currently_hidden_extmark_ids[id2] = nil
        else
          new_hidden[id2] = opts.virt_text
          Currently_hidden_extmark_ids[id2] = nil
          vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, col, {
            id = id2,
            virt_text = { { "" } },
            end_row = opts.end_row,
            end_col = opts.end_col,
            conceal = nil,
            virt_text_pos = opts.virt_text_pos,
            invalidate = opts.invalidate,
          })
        end
      end
      ::continue::
    end
  end

  for id, text in pairs(Currently_hidden_extmark_ids) do
    if type(text) == "table" and text.block_virt_lines then
      local em = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns_id, id, { details = true })
      if #em > 0 then
        local row, col, opts = em[1], em[2], em[3]
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, row, col, {
          id = id,
          invalidate = true,
          --- @diagnostic disable-next-line: assign-type-mismatch
          conceal_lines = "",
          end_col = opts.end_col,
          end_row = opts.end_row,
        })
      end
      local vl_id = block_virt_lines_marks[id]
      if vl_id and text.virt_lines_data then
        local vm = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns_id3, vl_id, { details = true })
        if #vm > 0 then
          vim.api.nvim_buf_set_extmark(bufnr, ns_id3, vm[1], vm[2], {
            id = vl_id,
            virt_lines = text.virt_lines_data,
            virt_lines_above = true,
          })
        end
      end
    else
      update_extmark_text(bufnr, id, text, true)
    end
  end

  Currently_hidden_extmark_ids = new_hidden
end

local function get_typst_block_at_cursor()
  local parser = vim.treesitter.get_parser(0, "typst")
  local tree = parser:parse()[1]:root()
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  cursor_pos = { cursor_pos[1] - 1, cursor_pos[2] }
  local element = tree:named_descendant_for_range(cursor_pos[1], cursor_pos[2], cursor_pos[1], cursor_pos[2])
  local outermost_block = nil
  while true do
    if element == nil then
      break
    end

    local type = element:type()
    if type == "math" or type == "code" then
      outermost_block = element
    elseif type == "ERROR" then
      return nil
    end
    element = element:parent()
  end
  if outermost_block ~= nil then
    return outermost_block:range()
  end

  return nil
end

--- @type {image_id: integer, extmark_id: integer} | nil
preview_image = nil

local live_preview_timer = nil
local last_preview_str = nil

---@param bufnr integer
local function clear_live_typst_preview(bufnr)
  if live_preview_timer then
    if not live_preview_timer:is_closing() then
      live_preview_timer:stop()
      live_preview_timer:close()
    end
    live_preview_timer = nil
  end
  last_preview_str = nil
  stop_watch_session(bufnr, "preview")

  if preview_image ~= nil then
    cleanup_render_item(bufnr, preview_image, true)
    preview_image = nil
  end
end

local function render_live_typst_preview()
  local bufnr = vim.fn.bufnr()
  local start_row, start_col, end_row, end_col = get_typst_block_at_cursor()
  if start_row == nil then
    clear_live_typst_preview(bufnr)
    return
  end

  local range = { start_row, start_col, end_row, end_col }
  local str = range_to_string(range, bufnr)

  if last_preview_str == str then
    return
  end

  if live_preview_timer then
    if not live_preview_timer:is_closing() then
      live_preview_timer:stop()
      live_preview_timer:close()
    end
  end

  live_preview_timer = vim.uv.new_timer()
  live_preview_timer:start(
    M.config.live_preview_debounce,
    0,
    vim.schedule_wrap(function()
      if live_preview_timer then
        if not live_preview_timer:is_closing() then
          live_preview_timer:stop()
          live_preview_timer:close()
        end
        live_preview_timer = nil
      end

      last_preview_str = str

      local image_id, extmark_id
      if preview_image ~= nil then
        image_id = preview_image.image_id
        prepare_extmark_reuse(bufnr, preview_image.extmark_id)
        extmark_id = place_image_extmark(image_id, range, preview_image.extmark_id, false)
      else
        image_id = new_image_id(bufnr)
        extmark_id = place_image_extmark(image_id, range, nil, false)
      end

      compile_image(bufnr, image_id, range, str, extmark_id, 0, true)
      preview_image = { image_id = image_id, extmark_id = extmark_id }
    end)
  )
end

--- @alias concealcursor_modes '' | 'n' | 'v' | 'nv' | 'i' | 'ni' | 'vi' | 'nvi' | 'c' | 'nc' | 'vc' | 'nvc' | 'ic' | 'nic' | 'vic' | 'nvic'

--- @class typstconfig
--- @field typst_location? string Where should typst-concealer look for your typst binary? Defaults to your PATH, likely does not need setting.
--- @field do_diagnostics? boolean Should typst-concealer provide diagnostics on error?
--- @field color? string What color should typst-concealer render text/stroke with? (only applies when styling_type is "colorscheme")
--- @field enabled_by_default? boolean Should typst-concealer conceal newly opened buffers by default?
--- @field styling_type? "none" | "simple" | "colorscheme" What kind of styling should typst-concealer apply to your typst?
--- @field ppi? integer What PPI should typst render at. Used as fallback when terminal pixel size is unavailable (e.g. tmux).
--- @field math_baseline_pt? number Expected typst math line height in points for one terminal row. Used to compute 1:1 render DPI. Default 10 pt (Libertine 11 pt with ascender/descender metrics).
--- @field conceal_in_normal boolean Should typst-concealer still conceal when the normal mode cursor goes over a line.
--- @field compiler_args? string[] List of extra arguments for the typst CLI (e.g., {"--root", "/my/dir"})
--- @field header? string Custom typst code to be added at the beginning of the rendered file.
--- @field live_preview_debounce? number Debounce delay for live preview rendering in milliseconds. Default is 100.

local augroup = vim.api.nvim_create_augroup("typst-concealer", { clear = true })

M.enable_buf = function(bufnr)
  if bufnr == nil then
    bufnr = vim.fn.bufnr()
  end
  M._enabled_buffers[bufnr] = true
  render_buf(bufnr)
end

M.disable_buf = function(bufnr)
  if bufnr == nil then
    bufnr = vim.fn.bufnr()
  end
  M._enabled_buffers[bufnr] = nil
  stop_watch_session(bufnr, "full")
  stop_watch_session(bufnr, "preview")
  clear_live_typst_preview(bufnr)
  hard_reset_buf(bufnr)
end

M.toggle_buf = function(bufnr)
  if bufnr == nil then
    bufnr = vim.fn.bufnr()
  end
  if M._enabled_buffers[bufnr] ~= nil then
    M._enabled_buffers[bufnr] = nil
    stop_watch_session(bufnr, "full")
    stop_watch_session(bufnr, "preview")
    clear_live_typst_preview(bufnr)
    hard_reset_buf(bufnr)
  else
    M._enabled_buffers[bufnr] = true
    render_buf(bufnr)
  end
end

M.rerender_buf = function(bufnr)
  if bufnr == nil then
    bufnr = vim.fn.bufnr()
  end
  render_buf(bufnr)
end

function M.setup(cfg)
  local version = vim.version()
  if version.major == 0 and version.minor < 10 then
    error("Typst concealer requires at least nvim 10.0 to work")
  end

  if M._setup_ran ~= nil then
    error("typst-concealer's setup function may only be run once")
  end
  M._setup_ran = true

  local config = {
    typst_location = default(cfg.typst_location, "typst"),
    do_diagnostics = default(cfg.do_diagnostics, true),
    enabled_by_default = default(cfg.enabled_by_default, true),
    styling_type = default(cfg.styling_type, "colorscheme"),
    ppi = default(cfg.ppi, 300),
    math_baseline_pt = default(cfg.math_baseline_pt, 11),
    color = cfg.color,
    conceal_in_normal = default(cfg.conceal_in_normal, false),
    compiler_args = default(cfg.compiler_args, {}),
    header = default(cfg.header, ""),
    live_preview_debounce = default(cfg.live_preview_debounce, 100),
  }

  if not vim.list_contains({ "none", "simple", "colorscheme" }, config.styling_type) then
    error(
      "typst styling_type"
        .. config.styling_type
        .. "is not a valid option. Please use 'none', 'simple' or 'colorscheme'"
    )
  end

  M.config = config
  setup_prelude()
  refresh_cell_px_size()

  if not config.allow_missing_typst and vim.fn.executable(M.config.typst_location) ~= 1 then
    if M.config.typst_location == "typst" then
      error("Typst executable not found in path, typst-concealer will not work")
    else
      error("Typst executable not found at '" .. M.config.typst_location .. "', typst-concealer will not work")
    end
  end

  local typst_parser_installed = pcall(vim.treesitter.get_parser, 0, "typst")
  if typst_parser_installed == false then
    error("Typst treesitter parser not found, typst-concealer will not work")
  end

  M._typst_query = vim.treesitter.query.parse(
    "typst",
    [[
[
 (code
  [(_) (call item: (ident) @call_ident)] @code
 )
 (math)
] @block
]]
  )

  local function init_buf(bufnr)
    vim.opt_local.conceallevel = 2
    vim.opt_local.concealcursor = "nci"

    if M.config.enabled_by_default then
      M._enabled_buffers[bufnr] = true
    end
  end

  if vim.v.vim_did_enter then
    local bufnr = vim.fn.bufnr()
    local str = vim.api.nvim_buf_get_name(bufnr)
    local match = str:match(".*%.typ$")
    if match ~= nil then
      init_buf(bufnr)
    end
  end

  vim.api.nvim_create_autocmd("BufEnter", {
    pattern = "*.typ",
    group = augroup,
    desc = "render file on enter",
    callback = function()
      render_buf()
    end,
  })

  vim.api.nvim_create_autocmd({ "BufNew", "VimEnter" }, {
    pattern = "*.typ",
    group = augroup,
    desc = "enable file on creation if the option is set",
    callback = function(ev)
      init_buf(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = "*.typ",
    group = augroup,
    desc = "render file on write",
    callback = function()
      vim.schedule(function()
        render_buf()
      end)
    end,
  })

  vim.api.nvim_create_autocmd("TextChanged", {
    pattern = "*.typ",
    group = augroup,
    desc = "re-render on normal-mode text changes (e.g. `o`, `dd`) so block formula anchors stay correct",
    callback = function()
      vim.schedule(function()
        render_buf()
      end)
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    pattern = "*.typ",
    group = augroup,
    desc = "unconceal on line hover",
    callback = function()
      hide_extmarks_at_cursor()
    end,
  })

  vim.api.nvim_create_autocmd({ "ModeChanged" }, {
    group = augroup,
    pattern = "v:*",
    desc = "unconceal when exiting visual mode, as this changes cursor pos without CursorMoved event",
    callback = function(ev)
      local str = vim.api.nvim_buf_get_name(ev.buf)
      local match = str:match(".*%.typ$")
      if match ~= nil then
        hide_extmarks_at_cursor()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "ModeChanged" }, {
    group = augroup,
    pattern = "i:*",
    desc = "remove preview when exiting insert mode",
    callback = function(ev)
      local str = vim.api.nvim_buf_get_name(ev.buf)
      local match = str:match(".*%.typ$")
      if match ~= nil then
        clear_live_typst_preview(ev.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = augroup,
    desc = "render live preview on insert enter",
    pattern = "*:i",
    callback = function(ev)
      local str = vim.api.nvim_buf_get_name(ev.buf)
      local match = str:match(".*%.typ$")
      if match ~= nil then
        render_live_typst_preview()
      end
    end,
  })

  vim.api.nvim_create_autocmd("TextChangedI", {
    pattern = "*.typ",
    group = augroup,
    desc = "render live preview when insert-mode text changes",
    callback = function()
      vim.schedule(function()
        render_live_typst_preview()
      end)
    end,
  })

  if cfg.color == nil then
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = augroup,
      desc = "update colour scheme",
      callback = function()
        setup_prelude()
        render_buf(vim.fn.bufnr())
      end,
    })
  end

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "typst",
    callback = function(ev)
      init_buf(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    desc = "refresh cell pixel size on terminal resize",
    callback = function()
      refresh_cell_px_size()
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = augroup,
    pattern = "*.typ",
    desc = "stop typst watch sessions for dead buffers",
    callback = function(ev)
      stop_watch_sessions_for_buf(ev.buf)
      hard_reset_buf(ev.buf)
    end,
  })
end

return M
