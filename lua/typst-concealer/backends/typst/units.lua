--- Typst AST unit collection and incremental merge for typst-concealer.
--- Exposed via the backend interface in backends/typst/init.lua.

local state = require("typst-concealer.state")
local M = {}

--- Lazily-initialised treesitter query for Typst math and code nodes.
local _typst_query = nil
local function get_typst_query()
  if _typst_query == nil then
    _typst_query = vim.treesitter.query.parse(
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
  end
  return _typst_query
end

--- Extract the text contained within a buffer range.
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

local function range_overlaps_rows(range, start_row, end_row)
  return range[3] >= start_row and range[1] <= end_row
end

--- Build an index of query-matched block nodes keyed by TSNode:id().
--- @param bufnr integer
--- @param tree TSNode
--- @param query vim.treesitter.Query
--- @param start_row integer|nil
--- @param end_row integer|nil
--- @return table<integer, table>
local function build_typst_match_index(bufnr, tree, query, start_row, end_row)
  local index = {}

  for _, match, _ in query:iter_matches(tree, bufnr, start_row, end_row, { all = true }) do
    local block = match[3] and match[3][1]
    if block ~= nil then
      local node_id = block:id()
      local entry = {
        node = block,
        node_type = block:type(),
        range = { block:range() },
      }

      if entry.node_type == "code" then
        local code_node = match[2] and match[2][1]
        entry.code_type = code_node and code_node:type() or nil

        if match[1] ~= nil then
          local a, b, c, d = match[1][1]:range()
          entry.call_ident = range_to_string({ a, b, c, d }, bufnr)
        else
          entry.call_ident = ""
        end
      end

      index[node_id] = entry
    end
  end

  return index
end

--- Traverse AST top-down and collect only maximal / top-level matched units.
--- @param root TSNode
--- @param match_index table<integer, table>
--- @param start_row integer|nil
--- @param end_row integer|nil
--- @return table[]
local function collect_top_level_typst_units(root, match_index, start_row, end_row)
  local units = {}

  local function visit(node)
    if node == nil then
      return
    end
    local sr, _, er, _ = node:range()
    if start_row ~= nil and end_row ~= nil and (er < start_row or sr > end_row) then
      return
    end

    local entry = match_index[node:id()]
    if entry ~= nil then
      if start_row == nil or range_overlaps_rows(entry.range, start_row, end_row) then
        units[#units + 1] = entry
      end
      return
    end

    for child in node:iter_children() do
      if child:named() then
        visit(child)
      end
    end
  end

  visit(root)
  return units
end

local function units_overlap_rows(unit, start_row, end_row)
  return range_overlaps_rows(unit.range, start_row, end_row)
end

local function expand_rows_to_cover_units(units, start_row, end_row)
  local expanded_start = start_row
  local expanded_end = end_row
  local changed = true
  while changed do
    changed = false
    for _, unit in ipairs(units or {}) do
      if units_overlap_rows(unit, expanded_start, expanded_end) then
        if unit.range[1] < expanded_start then
          expanded_start = unit.range[1]
          changed = true
        end
        if unit.range[3] > expanded_end then
          expanded_end = unit.range[3]
          changed = true
        end
      end
    end
  end
  return expanded_start, expanded_end
end

local function can_incrementally_merge_check(prev_units, new_units, start_row, end_row)
  for _, unit in ipairs(prev_units or {}) do
    if units_overlap_rows(unit, start_row, end_row) and unit.node_type ~= "math" then
      return false
    end
  end
  for _, unit in ipairs(new_units or {}) do
    if unit.node_type ~= "math" then
      return false
    end
  end
  return true
end

local function merge_units_in_rows_impl(prev_units, new_units, start_row, end_row)
  local merged = {}
  local inserted = false
  for _, unit in ipairs(prev_units or {}) do
    if unit.range[3] < start_row then
      merged[#merged + 1] = unit
    elseif unit.range[1] > end_row then
      if not inserted then
        for _, new_unit in ipairs(new_units or {}) do
          merged[#merged + 1] = new_unit
        end
        inserted = true
      end
      merged[#merged + 1] = unit
    end
  end
  if not inserted then
    for _, new_unit in ipairs(new_units or {}) do
      merged[#merged + 1] = new_unit
    end
  end
  return merged
end

--- Collect all top-level Typst render units for bufnr.
--- Use a full tree traversal for correctness.
--- The incremental merge path can retain deleted math units after unsaved edits,
--- which then keeps stale image/extmark state alive until the next full render
--- (for example on save).
--- @param bufnr integer
--- @return table[]
function M.collect_units(bufnr)
  local parser = vim.treesitter.get_parser(bufnr, "typst")
  local tree = parser:parse(true)[1]:root()
  local query = get_typst_query()

  local match_index = build_typst_match_index(bufnr, tree, query)
  return collect_top_level_typst_units(tree, match_index)
end

--- Check whether an incremental merge is feasible for the given pending change.
--- @param bufnr integer
--- @param pending_change table|nil
--- @return boolean
function M.can_incrementally_merge_units(bufnr, pending_change)
  if pending_change == nil or pending_change.requires_full then
    return false
  end
  local prev_units = (state.buffer_render_state[bufnr] or {}).full_units
  return prev_units ~= nil
end

--- Merge new_units into the previously collected units for the given row range.
--- Reads prev_units from state.
--- @param bufnr integer
--- @param start_row integer
--- @param end_row integer
--- @param new_units table[]
--- @return table[]
function M.merge_units_in_rows(bufnr, start_row, end_row, new_units)
  local prev_units = (state.buffer_render_state[bufnr] or {}).full_units or {}
  return merge_units_in_rows_impl(prev_units, new_units, start_row, end_row)
end

--- Clear backend-owned state for a buffer (called from hard_reset_buf).
--- @param bufnr integer
function M.reset_buf_state(bufnr)
  if state.buffer_render_state[bufnr] then
    state.buffer_render_state[bufnr].full_units = nil
  end
  state.runtime_preludes = {}
end

return M
