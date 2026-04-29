--- Neovim extmark management and kitty graphics protocol for typst-concealer.
--- This is the Neovim display layer: extmark placement, image upload, concealing.
--- All display decisions come from semantics.display_kind.
--- block_padding_cols = 终端显示留白（Neovim display 层，与 Typst page width 正交）

local state = require("typst-concealer.state")
local cursor_visibility = require("typst-concealer.cursor-visibility")
local kitty_codes = require("typst-concealer.kitty-codes")
local M = {}

local is_tmux = vim.env.TMUX ~= nil
local vim_stdout = assert(vim.loop.new_tty(1, false))

local function tmux_escape(message)
  return "\x1bPtmux;" .. message:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
end

local function send_terminal_data(data)
  if vim.api.nvim_ui_send ~= nil then
    local ok = pcall(vim.api.nvim_ui_send, data)
    if ok then
      return
    end
  end
  vim_stdout:write(data)
end

local function encode_kitty_escape(message)
  local payload = "\x1b_G" .. message .. "\x1b\\"
  if is_tmux then
    return tmux_escape(payload)
  end
  return payload
end

local function send_kitty_escape(message)
  send_terminal_data(encode_kitty_escape(message))
end

--- Upload an image to the terminal via kitty graphics protocol.
--- @param path    string  path to the PNG file
--- @param image_id integer
--- @param width   integer  in terminal cells
--- @param height  integer  in terminal cells
function M.create_image(path, image_id, width, height)
  path = vim.base64.encode(path)
  send_terminal_data(
    encode_kitty_escape("q=2,f=100,t=t,i=" .. image_id .. ";" .. path)
      .. encode_kitty_escape("q=2,a=p,U=1,i=" .. image_id .. ",c=" .. width .. ",r=" .. height)
  )
end

--- Delete an image from the terminal.
--- @param image_id integer
function M.clear_image(image_id)
  send_kitty_escape("q=2,a=d,d=i,i=" .. image_id)
  state.image_ids_in_use[image_id] = nil
end

--- Delete an image from the terminal without touching index tables.
--- Used by resources.lua which manages index tables centrally.
--- @param image_id integer
function M.clear_image_only(image_id)
  send_kitty_escape("q=2,a=d,d=i,i=" .. image_id)
end

--- Returns the column width of the window displaying bufnr (falls back to current window).
--- @param bufnr integer
--- @return integer
local function get_win_cols(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  return vim.api.nvim_win_get_width(winid ~= -1 and winid or 0)
end

--- Returns leading spaces needed to centre an image of natural_cols width.
--- @param natural_cols integer
--- @param bufnr        integer
--- @return integer
local function center_padding(natural_cols, bufnr)
  local win_width = get_win_cols(bufnr)
  if natural_cols >= win_width then
    return 0
  end
  return math.floor((win_width - natural_cols) / 2)
end

--- Clamp a range to the current buffer contents so extmark updates survive edits.
--- @param bufnr integer
--- @param range Range4
--- @return Range4|nil
local function normalize_range(bufnr, range)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count <= 0 then
    return nil
  end

  local start_row = math.max(0, math.min(range[1], line_count - 1))
  local end_row = math.max(start_row, math.min(range[3], line_count - 1))
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)

  local start_len = #(lines[1] or "")
  local end_len = #(lines[#lines] or "")
  local start_col = math.max(0, math.min(range[2], start_len))
  local end_col = math.max(0, math.min(range[4], end_len))

  if start_row == end_row and end_col < start_col then
    end_col = start_col
  end

  return { start_row, start_col, end_row, end_col }
end

--- Normalize virt text payload into one extmark line: { {text, hl?}, ... }.
--- Accepts chunk, line, or single-item virt_lines forms.
--- @param value any
--- @return table
local function normalize_virt_text_line(value)
  if type(value) ~= "table" then
    return { { tostring(value or ""), "" } }
  end

  if type(value[1]) == "string" then
    return { value }
  end

  if type(value[1]) == "table" and type(value[1][1]) == "string" then
    return value
  end

  if type(value[1]) == "table" and type(value[1][1]) == "table" then
    return normalize_virt_text_line(value[1])
  end

  return { { "", "" } }
end

local function normalize_virt_text_lines(value)
  if type(value) ~= "table" then
    return { normalize_virt_text_line(value) }
  end

  if type(value[1]) == "table" and type(value[1][1]) == "table" then
    local lines = {}
    for i = 1, #value do
      lines[i] = normalize_virt_text_line(value[i])
    end
    return lines
  end

  return { normalize_virt_text_line(value) }
end

--- Low-level extmark placement. Use place_render_extmark for external callers.
--- @param bufnr      integer
--- @param image_id  integer
--- @param range     Range4
--- @param extmark_id integer|nil
--- @param concealing boolean|nil
--- @param is_block  boolean|nil
--- @return integer  new extmark_id
local function place_image_extmark(bufnr, image_id, range, extmark_id, concealing, is_block)
  local normalized = normalize_range(bufnr, range)
  if normalized == nil then
    return extmark_id
  end

  local start_row, start_col, end_row, end_col = normalized[1], normalized[2], normalized[3], normalized[4]
  local height = end_row - start_row + 1
  local new_extmark_id
  local bs = state.get_buf_state(bufnr)

  if height == 1 then
    if concealing == false then
      local opts = {
        id = extmark_id,
        invalidate = true,
        end_col = end_col,
        end_row = end_row,
      }
      if is_block then
        opts.virt_text = { { "" } }
        opts.virt_text_pos = "overlay"
      else
        opts.virt_text = { { "" } }
        opts.virt_text_pos = "inline"
      end
      new_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, start_row, start_col, opts)
      if is_block then
        bs.multiline_marks[new_extmark_id] = { is_block_carrier = true, carrier_id = nil, tail_ids = {} }
      end
    elseif is_block then
      -- Single-line block formulas also use the block-carrier model so they can
      -- expand to multiple display rows and fully conceal the source line.
      new_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, start_row, start_col, {
        id = extmark_id,
        virt_text = { { "" } },
        virt_text_pos = "overlay",
        invalidate = true,
        end_col = end_col,
        end_row = end_row,
      })
      bs.multiline_marks[new_extmark_id] = { is_block_carrier = true, carrier_id = nil, tail_ids = {} }
    else
      new_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, start_row, start_col, {
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
      new_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, start_row, start_col, {
        id = extmark_id,
        invalidate = true,
        virt_text = { { "" } },
        -- used for determining the virt_text_pos of child ns_id2 extmarks
        virt_text_pos = is_block and "overlay" or "right_align",
        end_col = end_col,
        end_row = end_row,
      })
      if is_block then
        bs.multiline_marks[new_extmark_id] = { is_block_carrier = true, carrier_id = nil, tail_ids = {} }
      else
        bs.multiline_marks[new_extmark_id] = {}
      end
    elseif is_block then
      -- Block multi-line: top-carrier atomic model.
      -- One ns_id2 carrier at start_row carries all image rows via virt_text+virt_lines.
      -- Tail ns_id2 extmarks conceal source rows start_row+1..end_row.
      new_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, start_row, start_col, {
        id = extmark_id,
        invalidate = true,
        virt_text = { { "" } },
        virt_text_pos = "overlay",
        end_col = end_col,
        end_row = end_row,
      })
      bs.multiline_marks[new_extmark_id] = { is_block_carrier = true, carrier_id = nil, tail_ids = {} }
    else
      new_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, start_row, start_col, {
        id = extmark_id,
        invalidate = true,
        virt_text = { { "" } },
        virt_text_pos = "overlay",
        end_col = end_col,
        end_row = end_row,
      })
      bs.multiline_marks[new_extmark_id] = {}
    end
  end

  state.image_id_to_extmark[image_id] = new_extmark_id
  return new_extmark_id
end

--- Public entry: place an extmark driven by render semantics.
--- Display decision comes only from semantics.display_kind.
--- @param bufnr      integer
--- @param image_id   integer
--- @param range      Range4
--- @param extmark_id integer|nil
--- @param concealing boolean|nil
--- @param semantics  table  RenderSemantics
--- @return integer
function M.place_render_extmark(bufnr, image_id, range, extmark_id, concealing, semantics)
  local is_block = (semantics.display_kind == "block")
  return place_image_extmark(bufnr, image_id, range, extmark_id, concealing, is_block)
end

--- Rebuild an existing extmark in-place for a new range.
--- Keeps the old rendered image visible until swap time.
--- @param bufnr      integer
--- @param image_id   integer
--- @param extmark_id integer
--- @param range      Range4
--- @param semantics  table  RenderSemantics
--- @param concealing boolean|nil
function M.swap_extmark_to_range(bufnr, image_id, extmark_id, range, semantics, concealing)
  state.prepare_extmark_reuse(bufnr, extmark_id)
  local new_id = place_image_extmark(bufnr, image_id, range, extmark_id, concealing, semantics.display_kind == "block")
  state.image_id_to_extmark[image_id] = new_id
end

--- Remove rendered placeholder text/conceal from an extmark so the source stays editable.
--- @param bufnr integer
--- @param extmark_id integer
--- @return boolean|nil
function M.unconceal_extmark(bufnr, extmark_id)
  local bs = state.get_buf_state(bufnr)
  local mm = bs.multiline_marks[extmark_id]
  if mm ~= nil then
    if mm.is_block_carrier then
      if mm.carrier_id then
        vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, mm.carrier_id)
        mm.carrier_id = nil
      end
      for _, sid in ipairs(mm.tail_ids or {}) do
        vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, sid)
      end
      mm.tail_ids = {}
      return true
    end

    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
    if #mark > 0 and mark[3] and mark[3].virt_text_pos == "right_align" then
      return nil
    end
    for _, sub_id in ipairs(mm) do
      vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, sub_id)
    end
    return true
  end

  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
  if #mark == 0 then
    return nil
  end
  local row, col, opts = mark[1], mark[2], mark[3]
  vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, row, col, {
    id = extmark_id,
    virt_text = { { "" } },
    end_row = opts.end_row,
    end_col = opts.end_col,
    conceal = nil,
    virt_text_pos = opts.virt_text_pos,
    invalidate = opts.invalidate,
  })
  return true
end

--- Update the virt_text/virt_lines on an existing extmark.
--- @param bufnr           integer
--- @param extmark_id      integer
--- @param virt_text_data  table
--- @param skip_hide_check boolean|nil
function M.update_extmark_text(bufnr, extmark_id, virt_text_data, skip_hide_check)
  if type(extmark_id) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local bs = state.get_buf_state(bufnr)
  if (skip_hide_check ~= true) and bs.currently_hidden_extmark_ids[extmark_id] ~= nil then
    return
  end
  local ok, m = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, state.ns_id, extmark_id, { details = true })
  if not ok then
    return
  end
  if #m == 0 then
    return
  end
  local row, col, opts = m[1], m[2], m[3]
  local single_line = normalize_virt_text_line(virt_text_data)

  local mm = bs.multiline_marks[extmark_id]
  if mm and mm.is_block_carrier then
    -- Top-carrier atomic model: one ns_id2 carrier owns the visible display.
    if mm.carrier_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id2, mm.carrier_id)
      mm.carrier_id = nil
    end
    for _, id in ipairs(mm.tail_ids or {}) do
      pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id2, id)
    end
    mm.tail_ids = {}

    local lines_buf = vim.api.nvim_buf_get_lines(bufnr, row, opts.end_row + 1, false)
    local display_lines = normalize_virt_text_lines(virt_text_data)
    local carrier_vl = {}
    for i = 2, #display_lines do
      carrier_vl[#carrier_vl + 1] = display_lines[i]
    end

    mm.carrier_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id2, row, 0, {
      virt_text = display_lines[1] or { { "", "" } },
      virt_text_pos = "overlay",
      conceal = "",
      end_col = #(lines_buf[1] or ""),
      end_row = row,
      virt_lines = carrier_vl,
    })

    -- Tail conceal: fully hide source rows start_row+1 .. end_row (0 screen lines each)
    local source_rows = opts.end_row - row + 1
    for i = 2, source_rows do
      local tid = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id2, row + i - 1, 0, {
        conceal_lines = "",
        end_row = row + i - 1,
      })
      table.insert(mm.tail_ids, tid)
    end
  else
    local height = opts.end_row - row + 1
    if height ~= 1 then
      -- Non-block multiline: existing per-source-line overlay model
      if mm then
        for _, id in pairs(mm) do
          vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, id)
        end
      end
      bs.multiline_marks[extmark_id] = {}
      local lines = vim.api.nvim_buf_get_lines(bufnr, row, opts.end_row + 1, false)
      for i = 1, height do
        local conceal = nil
        if opts.virt_text_pos ~= "right_align" then
          conceal = ""
        end
        local virt_text_line = virt_text_data[i]
        if
          type(virt_text_line) == "string"
          or (type(virt_text_line) == "table" and type(virt_text_line[1]) == "string")
        then
          virt_text_line = { virt_text_line }
        end
        local new_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id2, row + i - 1, 0, {
          virt_text = virt_text_line,
          conceal = conceal,
          virt_text_pos = opts.virt_text_pos,
          end_col = #(lines[i] or ""),
          end_row = row + i - 1,
        })
        table.insert(bs.multiline_marks[extmark_id], new_id)
      end
    elseif opts.virt_text_pos == "inline" or (opts.virt_text_pos == "overlay" and opts.conceal == "") then
      vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, row, col, {
        id = extmark_id,
        virt_text = single_line,
        virt_text_pos = opts.virt_text_pos,
        invalidate = opts.invalidate,
        end_col = opts.end_col,
        end_row = opts.end_row,
        --- @diagnostic disable-next-line nvim type is wrong
        conceal = "",
      })
    else
      vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, row, col, {
        id = extmark_id,
        virt_lines = { single_line },
        virt_text_pos = opts.virt_text_pos,
        invalidate = opts.invalidate,
        end_col = opts.end_col,
        end_row = opts.end_row,
        --- @diagnostic disable-next-line nvim type is wrong
        conceal = opts.conceal,
      })
    end
  end
end

--- Shared placeholder writer used by both main-buffer items and preview-float clones.
--- @param bufnr integer
--- @param extmark_id integer
--- @param render_image_id integer
--- @param natural_cols integer
--- @param natural_rows integer
--- @param source_rows integer
--- @param item table|nil
local function conceal_extmark_with_image(
  bufnr,
  extmark_id,
  render_image_id,
  natural_cols,
  natural_rows,
  source_rows,
  item
)
  local bs = state.get_buf_state(bufnr)
  if type(extmark_id) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local multiline_extmark_ids = bs.multiline_marks[extmark_id]

  local hl_group = "typst-concealer-image-id-" .. tostring(render_image_id)
  vim.api.nvim_set_hl(0, hl_group, { fg = string.format("#%06X", render_image_id) })

  local config = require("typst-concealer").config
  local pad = 0
  if item and item.render_target == "float" then
    pad = 0
  elseif item and item.semantics then
    if item.semantics.constraint_kind == "flow" then
      -- Multiline code: left padding = terminal display padding
      -- block_padding_cols = 终端显示留白（Neovim display 层）
      pad = config.block_padding_cols or 0
    elseif item.semantics.display_kind == "block" then
      -- Math display (single- or multi-line): centre in the buffer's own window
      pad = center_padding(natural_cols, bufnr)
    end
  end

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

  local too_tall_msg = "This image attempted to render taller than "
    .. #kitty_codes.diacritics
    .. " lines. If you legitimately see this in a real document, open an issue."

  local function build_block_display_lines()
    local lines = {}
    local prefix = item and item.display_prefix or nil
    local suffix = item and item.display_suffix or nil

    if type(prefix) == "string" and prefix ~= "" then
      lines[#lines + 1] = { { prefix, "" } }
    end
    for i = 1, natural_rows do
      if i >= #kitty_codes.diacritics then
        lines[#lines + 1] = { { too_tall_msg, hl_group } }
      else
        lines[#lines + 1] = make_row_list(i)
      end
    end
    if type(suffix) == "string" and suffix ~= "" then
      lines[#lines + 1] = { { suffix, "" } }
    end

    return lines
  end

  if multiline_extmark_ids == nil then
    M.update_extmark_text(bufnr, extmark_id, make_row_list(1))
  elseif multiline_extmark_ids.is_block_carrier then
    M.update_extmark_text(bufnr, extmark_id, build_block_display_lines())
  else
    -- Non-block multiline: existing centering logic
    local lines = {}
    if natural_rows < source_rows then
      local above_blank = math.floor((source_rows - natural_rows) / 2)
      for i = 1, source_rows do
        local image_row = i - above_blank
        if image_row < 1 or image_row > natural_rows then
          lines[i] = { { "", hl_group } }
        elseif image_row >= #kitty_codes.diacritics then
          lines[i] = { { too_tall_msg, hl_group } }
        else
          lines[i] = make_row_list(image_row)
        end
      end
    else
      for i = 1, source_rows do
        if i >= #kitty_codes.diacritics then
          lines[i] = { { too_tall_msg, hl_group } }
        else
          lines[i] = make_row_list(i)
        end
      end
    end
    M.update_extmark_text(bufnr, extmark_id, lines)
  end
end

--- Add concealing unicode characters for a rendered image.
--- Padding decision comes from the item's semantics (looked up from state).
---   flow + block  → block_padding_cols left padding (terminal display layer)
---   intrinsic + block → centred
---   inline        → no padding
--- @param bufnr        integer
--- @param image_id     integer
--- @param natural_cols integer
--- @param natural_rows integer
--- @param source_rows  integer
function M.conceal_for_image_id(bufnr, image_id, natural_cols, natural_rows, source_rows)
  local extmark_id = state.image_id_to_extmark[image_id]
  local bs = state.get_buf_state(bufnr)
  local item = state.get_item_by_image_id(image_id)
  if extmark_id ~= nil and cursor_visibility.should_preserve_source_at_cursor(bufnr, item) then
    if M.unconceal_extmark(bufnr, extmark_id) ~= nil then
      bs.currently_hidden_extmark_ids[extmark_id] = true
    end
    return
  end
  if extmark_id ~= nil and bs.currently_hidden_extmark_ids[extmark_id] then
    return
  end
  conceal_extmark_with_image(bufnr, extmark_id, image_id, natural_cols, natural_rows, source_rows, item)
end

--- Render an existing kitty image into an arbitrary extmark.
--- Used by preview float so it can reuse the exact full-render image payload.
--- @param bufnr integer
--- @param extmark_id integer
--- @param render_image_id integer
--- @param natural_cols integer
--- @param natural_rows integer
--- @param source_rows integer
--- @param item table|nil
function M.conceal_existing_image(bufnr, extmark_id, render_image_id, natural_cols, natural_rows, source_rows, item)
  conceal_extmark_with_image(bufnr, extmark_id, render_image_id, natural_cols, natural_rows, source_rows, item)
end

--- Render an existing kitty image into virtual lines above or below a buffer row.
--- Unlike conceal_existing_image, this never conceals source text.
--- @param bufnr integer
--- @param extmark_id integer|nil
--- @param anchor_row integer
--- @param render_image_id integer
--- @param natural_cols integer
--- @param natural_rows integer
--- @param opts table|nil
--- @return integer
function M.show_virtual_image(bufnr, extmark_id, anchor_row, render_image_id, natural_cols, natural_rows, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return extmark_id
  end

  opts = opts or {}
  local left_pad_cols = math.max(0, opts.left_pad_cols or 0)
  local pad_str = left_pad_cols > 0 and string.rep(" ", left_pad_cols) or nil
  local hl_group = "typst-concealer-image-id-" .. tostring(render_image_id)
  vim.api.nvim_set_hl(0, hl_group, { fg = string.format("#%06X", render_image_id) })

  local lines = {}
  local too_tall_msg = "This image attempted to render taller than "
    .. #kitty_codes.diacritics
    .. " lines. If you legitimately see this in a real document, open an issue."

  for i = 1, natural_rows do
    local line = ""
    if i >= #kitty_codes.diacritics then
      line = too_tall_msg
    else
      for j = 0, natural_cols - 1 do
        line = line .. kitty_codes.placeholder .. kitty_codes.diacritics[i] .. kitty_codes.diacritics[j + 1]
      end
    end
    if pad_str then
      lines[#lines + 1] = { { pad_str, "" }, { line, hl_group } }
    else
      lines[#lines + 1] = { { line, hl_group } }
    end
  end

  return vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, anchor_row, 0, {
    id = extmark_id,
    invalidate = true,
    virt_lines = lines,
    virt_lines_above = opts.above == true,
  })
end

return M
