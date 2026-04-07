--- LaTeX AST unit collection and incremental merge for typst-concealer.
--- Exposed via the backend interface in backends/latex/init.lua.

local state = require("typst-concealer.state")
local M = {}

--- Lazily-initialised treesitter query for LaTeX math nodes.
local _latex_query = nil
local function get_latex_query()
  if _latex_query == nil then
    _latex_query =
      vim.treesitter.query.parse("latex", "[(inline_formula) (displayed_equation) (math_environment)] @math")
  end
  return _latex_query
end

local function range_overlaps_rows(range, start_row, end_row)
  return range[3] >= start_row and range[1] <= end_row
end

--- Build a match index of all math nodes keyed by TSNode:id().
--- @param bufnr integer
--- @param tree any  TSNode (root)
--- @param query any  vim.treesitter.Query
--- @param start_row integer|nil
--- @param end_row integer|nil
--- @return table
local function build_latex_match_index(bufnr, tree, query, start_row, end_row)
  local index = {}
  for _, match, _ in query:iter_matches(tree, bufnr, start_row, end_row, { all = true }) do
    local node = match[1] and match[1][1]
    if node ~= nil then
      local node_id = node:id()
      index[node_id] = {
        node = node,
        node_type = node:type(),
        source_kind = "math",
        range = { node:range() },
      }
    end
  end
  return index
end

--- Traverse AST top-down and collect only maximal / top-level matched units.
--- @param root any  TSNode
--- @param match_index table
--- @param start_row integer|nil
--- @param end_row integer|nil
--- @return table[]
local function collect_top_level_latex_units(root, match_index, start_row, end_row)
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

--- Collect all top-level LaTeX math units for bufnr.
--- @param bufnr integer
--- @return table[]
function M.collect_units(bufnr)
  local bs = state.get_buf_state(bufnr)
  local prev_state = state.buffer_render_state[bufnr] or {}
  local pending = bs.pending_change

  local parser = vim.treesitter.get_parser(bufnr, "latex")
  local tree = parser:parse()[1]:root()
  local query = get_latex_query()

  -- Try incremental path (math-only units are always safe to merge)
  if prev_state.full_units ~= nil and pending ~= nil and not pending.requires_full then
    local start_row, end_row = expand_rows_to_cover_units(prev_state.full_units, pending.start_row, pending.new_end_row)
    local match_index = build_latex_match_index(bufnr, tree, query, start_row, end_row + 1)
    local new_units = collect_top_level_latex_units(tree, match_index, start_row, end_row)
    return merge_units_in_rows_impl(prev_state.full_units, new_units, start_row, end_row)
  end

  -- Full collect
  local match_index = build_latex_match_index(bufnr, tree, query)
  return collect_top_level_latex_units(tree, match_index)
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
--- @param bufnr integer
--- @param start_row integer
--- @param end_row integer
--- @param new_units table[]
--- @return table[]
function M.merge_units_in_rows(bufnr, start_row, end_row, new_units)
  local prev_units = (state.buffer_render_state[bufnr] or {}).full_units or {}
  return merge_units_in_rows_impl(prev_units, new_units, start_row, end_row)
end

--- Clear backend-owned state for a buffer.
--- @param bufnr integer
function M.reset_buf_state(bufnr)
  if state.buffer_render_state[bufnr] then
    state.buffer_render_state[bufnr].full_units = nil
  end
  state.runtime_preludes = {}
end

return M
