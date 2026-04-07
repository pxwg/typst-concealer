--- Live math preview helpers for the Typst backend.
--- Exposed via the backend interface in backends/typst/init.lua.

local M = {}

--- Extract the text contained within a buffer range.
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

local function get_text_slice(bufnr, start_row, start_col, end_row, end_col)
  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {}), "\n")
end

local function is_insert_like_mode(mode)
  mode = mode or vim.api.nvim_get_mode().mode or ""
  return mode:find("i", 1, true) ~= nil or mode:find("R", 1, true) ~= nil
end

local function cursor_in_range(range, row, col, opts)
  opts = opts or {}
  local sr, sc, er, ec = range[1], range[2], range[3], range[4]
  local include_right_edge = opts.include_right_edge == true

  if row < sr or row > er then
    return false
  end

  if sr == er then
    if include_right_edge then
      return col >= sc and col <= ec
    end
    return col >= sc and col < ec
  end

  if row == sr then
    return col >= sc
  end

  if row == er then
    if include_right_edge then
      return col <= ec
    end
    return col < ec
  end

  return true
end

local function get_math_symbol_span_at_pos(item, row, col)
  local line = vim.fn.getbufline(item.bufnr, row + 1)[1] or ""
  if line == "" then
    return nil
  end

  local parser = vim.treesitter.get_parser(item.bufnr, "typst")
  local root = parser:parse()[1]:root()
  local end_col = math.min(#line, col + 1)
  local node = root:named_descendant_for_range(row, col, row, end_col)
  if node == nil then
    return nil
  end

  local formula_node = nil
  local target = node
  while target ~= nil do
    local t = target:type()
    if t == "formula" then
      formula_node = target
      break
    end
    target = target:parent()
  end
  if formula_node == nil then
    return nil
  end

  target = node
  while target ~= nil do
    local parent = target:parent()
    if parent == nil then
      return nil
    end
    if parent:id() == formula_node:id() then
      break
    end
    target = parent
  end

  local sr, sc, er, ec = target:range()
  if not cursor_in_range(item.range, sr, sc, { include_right_edge = false }) then
    return nil
  end
  if er < sr or (er == sr and ec < sc) then
    return nil
  end
  local text = get_text_slice(item.bufnr, sr, sc, er, ec)
  if text == nil or text == "" or text:match("^%s+$") then
    return nil
  end

  return {
    start_row = sr,
    start_col = sc,
    end_row = er,
    end_col = ec,
    text = text,
  }
end

local function get_math_symbol_span_at_cursor(item, row, col, mode)
  if item == nil or item.node_type ~= "math" or type(item.str) ~= "string" then
    return nil
  end

  local line = vim.fn.getbufline(item.bufnr, row + 1)[1] or ""
  if line == "" then
    return nil
  end

  local candidates = {}
  if col >= 0 and col < #line then
    candidates[#candidates + 1] = col
  end

  if is_insert_like_mode(mode) and col > 0 then
    local left_col = col - 1
    if left_col >= 0 and left_col < #line then
      candidates[#candidates + 1] = left_col
    end
  end

  for _, candidate_col in ipairs(candidates) do
    local span = get_math_symbol_span_at_pos(item, row, candidate_col)
    if span ~= nil then
      return span
    end
  end

  return nil
end

--- Get the span of the math symbol at bufnr/pos for external callers.
--- @param bufnr integer
--- @param pos table  { row, col } (0-based)
--- @return table|nil
function M.get_math_symbol_span_at_pos(bufnr, pos)
  local dummy_item = { bufnr = bufnr, range = { 0, 0, math.huge, math.huge } }
  return get_math_symbol_span_at_pos(dummy_item, pos[1], pos[2])
end

--- Build the highlighted preview source for a math item at the given cursor position.
--- @param item table
--- @param cursor_row integer
--- @param cursor_col integer
--- @param mode string
--- @return string|nil, string|nil, string|nil  preview_str, render_key, source_str
function M.make_highlighted_preview(item, cursor_row, cursor_col, mode)
  if item == nil or item.node_type ~= "math" then
    return nil, nil, nil
  end

  local source_text = range_to_string(item.range, item.bufnr)
  if source_text == nil or source_text == "" then
    return nil, nil, nil
  end

  local span = get_math_symbol_span_at_cursor(item, cursor_row, cursor_col, mode)
  if span == nil then
    local key = table.concat(item.range, ":")
      .. ":plain:"
      .. tostring(cursor_row)
      .. ":"
      .. tostring(cursor_col)
      .. ":"
      .. source_text
    return source_text, key, source_text
  end

  if not cursor_in_range(item.range, span.start_row, span.start_col, { include_right_edge = false }) then
    local key = table.concat(item.range, ":")
      .. ":plain:"
      .. tostring(cursor_row)
      .. ":"
      .. tostring(cursor_col)
      .. ":"
      .. source_text
    return source_text, key, source_text
  end

  local prefix = get_text_slice(item.bufnr, item.range[1], item.range[2], span.start_row, span.start_col)
  local suffix = get_text_slice(item.bufnr, span.end_row, span.end_col, item.range[3], item.range[4])
  local replacement = "#text(red)[$" .. span.text .. "$]"
  local rendered = prefix .. replacement .. suffix
  local key = table.concat(item.range, ":")
    .. ":"
    .. tostring(span.start_row)
    .. ":"
    .. tostring(span.start_col)
    .. ":"
    .. tostring(span.end_row)
    .. ":"
    .. tostring(span.end_col)
    .. ":"
    .. source_text
  return rendered, key, source_text
end

return M
