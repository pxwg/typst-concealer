--- Live math preview helpers for the LaTeX backend.
--- Exposed via the backend interface in backends/latex/init.lua.
---
--- For LaTeX, make_highlighted_preview returns the raw math source without
--- cursor-symbol highlighting (symbol-span detection is a future TODO).

local M = {}

--- Extract text for a buffer range.
--- @param range table
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

--- Build the highlighted preview source for a LaTeX math item.
--- Returns the raw source (no symbol highlighting for now).
--- @param item table
--- @param cursor_row integer
--- @param cursor_col integer
--- @return string|nil preview_str
--- @return string|nil render_key
--- @return string|nil source_str
function M.make_highlighted_preview(item, cursor_row, cursor_col, _mode)
  if item == nil or item.node_type ~= "math" then
    return nil, nil, nil
  end

  local source_text = range_to_string(item.range, item.bufnr)
  if source_text == nil or source_text == "" then
    return nil, nil, nil
  end

  local key = table.concat(item.range, ":")
    .. ":plain:"
    .. tostring(cursor_row)
    .. ":"
    .. tostring(cursor_col)
    .. ":"
    .. source_text
  return source_text, key, source_text
end

return M
