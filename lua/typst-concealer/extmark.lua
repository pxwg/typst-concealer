--- Neovim extmark management and kitty graphics protocol for typst-concealer.
--- This is the Neovim display layer: extmark placement, image upload, concealing.
--- All display decisions come from semantics.display_kind.
--- block_padding_cols = 终端显示留白（Neovim display 层，与 Typst page width 正交）

local state = require("typst-concealer.state")
local cursor_visibility = require("typst-concealer.cursor-visibility")
local kitty_codes = require("typst-concealer.kitty-codes")
local M = {}

local is_tmux = vim.env.TMUX ~= nil
local vim_stdout
local display_size_for_image

--- Pending terminal data buffer.  All kitty escape sequences are accumulated
--- here and flushed as a single atomic write via `M.flush_terminal_data()`.
--- This prevents interleaving with Neovim's own TUI output when many images
--- are cleared+re-created in the same event-loop tick (bind_overlay batches).
local pending_terminal_buf = {}

local function tmux_escape(message)
  return "\x1bPtmux;" .. message:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
end

local function send_terminal_data(data)
  pending_terminal_buf[#pending_terminal_buf + 1] = data
end

local function write_terminal_data(data)
  if vim.api.nvim_ui_send ~= nil then
    local ok = pcall(vim.api.nvim_ui_send, data)
    if ok then
      return
    end
  end

  vim_stdout = vim_stdout or assert(vim.loop.new_tty(1, false))
  vim_stdout:write(data)
end

--- Flush all pending kitty escape data to the terminal in one write.
function M.flush_terminal_data()
  if #pending_terminal_buf == 0 then
    return
  end
  local data = table.concat(pending_terminal_buf)
  pending_terminal_buf = {}
  write_terminal_data(data)
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
  local item = state.get_item_by_image_id(image_id)
  width, height = display_size_for_image(item, width, height)
  if item ~= nil then
    item.display_cols = width
    item.display_rows = height
  end

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

local function item_display_bufnr(item)
  if item == nil then
    return nil
  end
  if item.render_target == "float" then
    return item.target_bufnr or item.bufnr
  end
  return item.bufnr
end

display_size_for_image = function(item, natural_cols, natural_rows)
  local display_cols = math.max(1, tonumber(natural_cols) or 1)
  local display_rows = math.max(1, tonumber(natural_rows) or 1)
  local semantics = item and item.semantics or nil
  if item == nil or item.render_target == "float" or semantics == nil or semantics.display_kind ~= "block" then
    return display_cols, display_rows
  end

  local bufnr = item_display_bufnr(item)
  if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return display_cols, display_rows
  end

  local win_cols = get_win_cols(bufnr)
  if win_cols <= 0 or display_cols <= win_cols then
    return display_cols, display_rows
  end

  local scaled_rows = math.max(1, math.ceil(display_rows * win_cols / display_cols))
  return win_cols, scaled_rows
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

local refresh_inline_line

local function get_win_text_cols(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  local width = get_win_cols(bufnr)
  if winid == -1 then
    return width
  end

  local info = vim.fn.getwininfo(winid)[1]
  local textoff = info and tonumber(info.textoff) or 0
  return math.max(1, width - textoff)
end

local function cursor_row_for_buf(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return nil
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
  if not ok or cursor == nil then
    return nil
  end
  return cursor[1] - 1
end

local function clear_inline_line_mark(bufnr, row)
  local bs = state.get_buf_state(bufnr)
  local marks = bs.inline_line_marks or {}
  local mark = marks[row]
  if mark == nil then
    return false
  end

  if mark.carrier_id ~= nil then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id2, mark.carrier_id)
  end
  if mark.conceal_id ~= nil then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id2, mark.conceal_id)
  end
  marks[row] = nil
  bs.inline_line_marks = marks
  return true
end

local function image_placeholder_text(row, cols, start_col)
  start_col = start_col or 0
  local line = ""
  for col = start_col, start_col + cols - 1 do
    line = line .. kitty_codes.placeholder .. kitty_codes.diacritics[row] .. kitty_codes.diacritics[col + 1]
  end
  return line
end

local function image_hl_group(image_id)
  local hl_group = "typst-concealer-image-id-" .. tostring(image_id)
  vim.api.nvim_set_hl(0, hl_group, { fg = string.format("#%06X", image_id), nocombine = true })
  return hl_group
end

local function inline_line_item_ready(item, bufnr, row)
  if item == nil or item.render_target == "float" or item.render_target == "preview_float" then
    return false
  end
  if item_display_bufnr(item) ~= bufnr then
    return false
  end
  if item.range == nil or item.range[1] ~= row or item.range[3] ~= row then
    return false
  end
  if item.semantics == nil or item.semantics.display_kind ~= "inline" then
    return false
  end
  return item.image_id ~= nil and item.natural_cols ~= nil and item.natural_rows ~= nil
end

local function collect_inline_line_items(bufnr, row)
  local items = {}
  for _, item in pairs(state.item_by_image_id) do
    if inline_line_item_ready(item, bufnr, row) then
      items[#items + 1] = item
    end
  end
  table.sort(items, function(a, b)
    if a.range[2] == b.range[2] then
      return a.range[4] < b.range[4]
    end
    return a.range[2] < b.range[2]
  end)

  local last_end = 0
  for _, item in ipairs(items) do
    if item.range[2] < last_end then
      return {}
    end
    last_end = item.range[4]
  end
  return items
end

local function append_wrapped_text(lines, line_idx, col, text, hl_group, max_cols)
  local char_count = vim.fn.strchars(text)
  for idx = 0, char_count - 1 do
    local ch = vim.fn.strcharpart(text, idx, 1)
    local width = vim.fn.strdisplaywidth(ch)
    if width > 0 and col > 0 and col + width > max_cols then
      line_idx = line_idx + 1
      lines[line_idx] = {}
      col = 0
    end
    lines[line_idx][#lines[line_idx] + 1] = { ch, hl_group or "" }
    col = col + width
  end
  return line_idx, col
end

local function append_wrapped_image(lines, line_idx, col, chunk, max_cols)
  local offset = 0
  local remaining = chunk.width or 0
  local hl_group = chunk.hl_group or chunk[2] or chunk[1] or ""

  while remaining > 0 do
    if col >= max_cols then
      line_idx = line_idx + 1
      lines[line_idx] = {}
      col = 0
    end

    local available = max_cols - col
    if available <= 0 then
      available = max_cols
    end
    local take = math.min(remaining, available)
    lines[line_idx][#lines[line_idx] + 1] = {
      image_placeholder_text(chunk.image_row or 1, take, offset),
      hl_group,
    }
    offset = offset + take
    remaining = remaining - take
    col = col + take
  end

  return line_idx, col
end

local function append_wrapped_chunk(lines, line_idx, col, chunk, max_cols)
  local text = chunk[1] or ""
  if chunk.image then
    return append_wrapped_image(lines, line_idx, col, chunk, max_cols)
  end
  if text == "" then
    return line_idx, col
  end

  local hl_group = chunk[2] or ""
  local width = chunk.width or vim.fn.strdisplaywidth(text)
  if chunk.atomic then
    if col > 0 and col + width > max_cols then
      line_idx = line_idx + 1
      lines[line_idx] = {}
      col = 0
    end
    lines[line_idx][#lines[line_idx] + 1] = { text, hl_group }
    return line_idx, col + width
  end

  return append_wrapped_text(lines, line_idx, col, text, hl_group, max_cols)
end

local function wrap_inline_chunks(chunks, max_cols)
  local lines = { {} }
  local line_idx = 1
  local col = 0
  for _, chunk in ipairs(chunks) do
    line_idx, col = append_wrapped_chunk(lines, line_idx, col, chunk, max_cols)
  end
  if #lines[#lines] == 0 then
    lines[#lines][1] = { "", "" }
  end
  return lines
end

local function row_has_conceal_lines(bufnr, row)
  local ok, marks = pcall(
    vim.api.nvim_buf_get_extmarks,
    bufnr,
    state.ns_id2,
    { row, 0 },
    { row, -1 },
    { details = true }
  )
  if not ok then
    return false
  end
  for _, mark in ipairs(marks) do
    local details = mark[4] or {}
    if details.conceal_lines ~= nil then
      return true
    end
  end
  return false
end

local function choose_inline_line_anchor(bufnr, row)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for anchor = row - 1, 0, -1 do
    if not row_has_conceal_lines(bufnr, anchor) then
      return anchor, false
    end
  end
  for anchor = row + 1, line_count - 1 do
    if not row_has_conceal_lines(bufnr, anchor) then
      return anchor, true
    end
  end
  return nil, nil
end

local function build_inline_line_chunks(bufnr, row, items)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if line == nil then
    return nil
  end

  local chunks = {}
  local last_col = 0
  for _, item in ipairs(items) do
    local start_col = item.range[2]
    local end_col = item.range[4]
    if start_col > last_col then
      chunks[#chunks + 1] = { line:sub(last_col + 1, start_col), "" }
    end

    local display_cols, display_rows = display_size_for_image(item, item.natural_cols, item.natural_rows)
    if display_rows ~= 1 then
      return nil
    end
    item.display_cols = display_cols
    item.display_rows = display_rows
    chunks[#chunks + 1] = {
      image = true,
      image_row = 1,
      hl_group = image_hl_group(item.image_id),
      width = display_cols,
    }
    last_col = end_col
  end

  if last_col < #line then
    chunks[#chunks + 1] = { line:sub(last_col + 1), "" }
  end
  return chunks
end

refresh_inline_line = function(bufnr, row, opts)
  opts = opts or {}
  if row == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  clear_inline_line_mark(bufnr, row)
  if opts.ignore_cursor ~= true and cursor_row_for_buf(bufnr) == row then
    return false
  end

  local items = collect_inline_line_items(bufnr, row)
  if #items == 0 then
    return false
  end

  local chunks = build_inline_line_chunks(bufnr, row, items)
  if chunks == nil then
    return false
  end

  local anchor_row, virt_lines_above = choose_inline_line_anchor(bufnr, row)
  if anchor_row == nil then
    return false
  end

  local lines = wrap_inline_chunks(chunks, get_win_text_cols(bufnr))
  local carrier_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id2, anchor_row, 0, {
    virt_lines = lines,
    virt_lines_above = virt_lines_above,
    virt_lines_overflow = "trunc",
  })
  local conceal_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id2, row, 0, {
    conceal_lines = "",
    end_row = row,
  })

  local bs = state.get_buf_state(bufnr)
  bs.inline_line_marks = bs.inline_line_marks or {}
  bs.inline_line_marks[row] = {
    anchor_row = anchor_row,
    carrier_id = carrier_id,
    conceal_id = conceal_id,
  }
  return true
end

local place_image_extmark

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
place_image_extmark = function(bufnr, image_id, range, extmark_id, concealing, is_block)
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
  local ok_mark, current_mark = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, state.ns_id, extmark_id, {})
  if ok_mark and current_mark ~= nil and #current_mark > 0 then
    clear_inline_line_mark(bufnr, current_mark[1])
  end

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

--- Hide compact inline line carriers for the cursor span and restore the
--- previous span when the cursor leaves it.
--- @param bufnr integer
--- @param lo integer
--- @param hi integer|nil
function M.sync_inline_line_carriers(bufnr, lo, hi)
  if type(lo) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  hi = type(hi) == "number" and hi or lo
  local bs = state.get_buf_state(bufnr)
  local previous = bs.inline_line_suppressed_rows or {}
  local next_rows = {}

  for row = lo, hi do
    next_rows[row] = true
    clear_inline_line_mark(bufnr, row)
  end

  for row in pairs(previous) do
    if not next_rows[row] then
      refresh_inline_line(bufnr, row, { ignore_cursor = true })
    end
  end

  bs.inline_line_suppressed_rows = next_rows
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
    local source_rows = opts.end_row - row + 1

    if source_rows == 1 then
      -- A single long source line can still occupy multiple wrapped screen
      -- rows after character conceal. Collapse the source line completely and
      -- render the whole block as consecutive virtual lines, matching the
      -- original Typst block strategy that avoids breaking the kitty grid.
      mm.carrier_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id2, row, 0, {
        virt_lines = display_lines,
        virt_lines_above = true,
        virt_lines_overflow = "trunc",
      })
      local tid = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id2, row, 0, {
        conceal_lines = "",
        end_row = row,
      })
      table.insert(mm.tail_ids, tid)
      return
    end

    local carrier_vl = {}
    for i = 2, #display_lines do
      carrier_vl[#carrier_vl + 1] = display_lines[i]
    end

    -- Tail conceal: fully hide source rows start_row+1 .. end_row (0 screen lines each)
    mm.carrier_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id2, row, 0, {
      virt_text = display_lines[1] or { { "", "" } },
      virt_text_pos = "overlay",
      conceal = "",
      end_col = #(lines_buf[1] or ""),
      end_row = row,
      virt_lines = carrier_vl,
    })

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
  local display_cols, display_rows = display_size_for_image(item, natural_cols, natural_rows)
  if item ~= nil then
    item.display_cols = display_cols
    item.display_rows = display_rows
  end

  local hl_group = "typst-concealer-image-id-" .. tostring(render_image_id)
  vim.api.nvim_set_hl(0, hl_group, { fg = string.format("#%06X", render_image_id), nocombine = true })

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
      pad = center_padding(display_cols, bufnr)
    end
  end

  local pad_str = pad > 0 and string.rep(" ", pad) or nil

  local function make_row_list(i)
    local line = ""
    for j = 0, display_cols - 1 do
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
    for i = 1, display_rows do
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
    if display_rows < source_rows then
      local above_blank = math.floor((source_rows - display_rows) / 2)
      for i = 1, source_rows do
        local image_row = i - above_blank
        if image_row < 1 or image_row > display_rows then
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

  if
    item ~= nil
    and item.semantics ~= nil
    and item.semantics.display_kind == "inline"
    and item.range ~= nil
    and item.range[1] == item.range[3]
  then
    refresh_inline_line(bufnr, item.range[1])
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
  vim.api.nvim_set_hl(0, hl_group, { fg = string.format("#%06X", render_image_id), nocombine = true })

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
