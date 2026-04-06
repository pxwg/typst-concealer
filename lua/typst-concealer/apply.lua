--- Resource lifecycle layer for typst-concealer.
--- Owns image_id / extmark_id allocation, reuse, release, and index maintenance.
--- Receives PlannedItem[] from render.lua (the planner) and produces AppliedItem[].

local state = require("typst-concealer.state")
local M = {}

--- @class PlannedItem
--- @field bufnr integer
--- @field item_idx integer
--- @field range table
--- @field display_range table
--- @field display_prefix string|nil
--- @field display_suffix string|nil
--- @field str string
--- @field prelude_count integer
--- @field node_type string
--- @field semantics table

--- @class AppliedItem : PlannedItem
--- @field image_id integer
--- @field extmark_id integer
--- @field needs_swap boolean
--- @field linger_misses integer|nil
--- @field page_path string|nil
--- @field page_stamp string|nil
--- @field natural_cols integer|nil
--- @field natural_rows integer|nil
--- @field source_rows integer|nil

--- @class PageUpdate
--- @field bufnr integer
--- @field image_id integer
--- @field extmark_id integer
--- @field original_range table
--- @field page_path string
--- @field page_stamp string
--- @field kind string

--- Allocate a new image_id for bufnr, scanning for a free slot.
--- @param bufnr integer
--- @return integer
local function new_image_id(bufnr)
  local pid = state.pid
  for i = pid, 2 ^ 16 + pid - 1 do
    if state.image_ids_in_use[i] == nil then
      state.image_ids_in_use[i] = bufnr
      return i
    end
  end
  -- Overflow: reset and retry
  print(
    "[typst-concealer] >65536 image ids in use, overflowing. "
      .. "This is probably a bug, you're looking at a very long document or a lot of documents.\n"
      .. "Open an issue if you see this, the cap can be increased if someone actually needs it.\n"
  )
  state.image_ids_in_use = {}
  return new_image_id(bufnr)
end

M._new_image_id = new_image_id

--- Release all resources for a single render item.
--- @param bufnr   integer
--- @param item    table|nil
local function cleanup_item(bufnr, item)
  if item == nil then
    return
  end
  local extmark = require("typst-concealer.extmark")
  state.prepare_extmark_reuse(bufnr, item.extmark_id)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id, item.extmark_id)
  extmark.clear_image(item.image_id)
  state.image_id_to_extmark[item.image_id] = nil
  state.item_by_image_id[item.image_id] = nil
end

M.cleanup_item = cleanup_item

local function row_overlap_len(a, b)
  local top = math.max(a[1], b[1])
  local bottom = math.min(a[3], b[3])
  if bottom < top then
    return 0
  end
  return bottom - top + 1
end

local function row_gap_len(a, b)
  if a[3] < b[1] then
    return b[1] - a[3]
  end
  if b[3] < a[1] then
    return a[1] - b[3]
  end
  return 0
end

local function col_delta_len(a, b)
  return math.abs(a[2] - b[2]) + math.abs(a[4] - b[4])
end

--- Match a fresh render entry to the most plausible previous item.
--- @param prev_items table[]
--- @param entry table
--- @param used_prev table<integer, boolean>
--- @return table|nil
local function find_matching_prev_item(prev_items, entry, used_prev)
  local best_idx = nil
  local best_item = nil
  local best_overlap = -1
  local best_gap = math.huge
  local best_col_delta = math.huge

  for idx, prev_item in ipairs(prev_items) do
    if not used_prev[idx] and prev_item.node_type == entry.node_type then
      local overlap = row_overlap_len(prev_item.range, entry.range)
      local gap = row_gap_len(prev_item.range, entry.range)
      local col_delta = col_delta_len(prev_item.range, entry.range)
      if
        overlap > best_overlap
        or (overlap == best_overlap and gap < best_gap)
        or (overlap == best_overlap and gap == best_gap and col_delta < best_col_delta)
      then
        best_idx = idx
        best_item = prev_item
        best_overlap = overlap
        best_gap = gap
        best_col_delta = col_delta
      end
    end
  end

  if best_idx ~= nil then
    used_prev[best_idx] = true
  end
  return best_item
end

M.find_matching_prev_item = find_matching_prev_item

local function cleanup_preview_image(bufnr)
  local bs = state.get_buf_state(bufnr)
  local preview = bs.preview_image
  local last_rendered = bs.preview_last_rendered_item
  if preview == nil then
    if bs.preview_item ~= nil then
      if bs.preview_item.extmark_id ~= nil then
        state.prepare_extmark_reuse(bufnr, bs.preview_item.extmark_id)
        pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id, bs.preview_item.extmark_id)
      end
    end
    if bs.preview_item ~= nil and bs.preview_item.image_id ~= nil then
      local extmark = require("typst-concealer.extmark")
      extmark.clear_image(bs.preview_item.image_id)
      state.image_id_to_extmark[bs.preview_item.image_id] = nil
      state.item_by_image_id[bs.preview_item.image_id] = nil
      state.image_ids_in_use[bs.preview_item.image_id] = nil
    end
    bs.preview_item = nil
    if last_rendered ~= nil and last_rendered.image_id ~= nil then
      local extmark = require("typst-concealer.extmark")
      extmark.clear_image(last_rendered.image_id)
      state.image_id_to_extmark[last_rendered.image_id] = nil
      state.item_by_image_id[last_rendered.image_id] = nil
      state.image_ids_in_use[last_rendered.image_id] = nil
    end
    bs.preview_last_rendered_item = nil
    bs.preview_last_render_key = nil
    bs.preview_render_key = nil
    bs.preview_source_image_id = nil
    bs.preview_source_page_stamp = nil
    bs.preview_source_range = nil
    return
  end

  local extmark = require("typst-concealer.extmark")
  local target_bufnr = preview.target_bufnr or bufnr
  state.prepare_extmark_reuse(target_bufnr, preview.extmark_id)
  pcall(vim.api.nvim_buf_del_extmark, target_bufnr, state.ns_id, preview.extmark_id)
  if preview.image_id ~= nil then
    extmark.clear_image(preview.image_id)
    state.image_id_to_extmark[preview.image_id] = nil
    state.item_by_image_id[preview.image_id] = nil
    state.image_ids_in_use[preview.image_id] = nil
  end
  if bs.preview_item ~= nil and bs.preview_item.image_id ~= nil and bs.preview_item.image_id ~= preview.image_id then
    extmark.clear_image(bs.preview_item.image_id)
    state.image_id_to_extmark[bs.preview_item.image_id] = nil
    state.item_by_image_id[bs.preview_item.image_id] = nil
    state.image_ids_in_use[bs.preview_item.image_id] = nil
  end
  if
    last_rendered ~= nil
    and last_rendered.image_id ~= nil
    and last_rendered.image_id ~= preview.image_id
    and (bs.preview_item == nil or last_rendered.image_id ~= bs.preview_item.image_id)
  then
    extmark.clear_image(last_rendered.image_id)
    state.image_id_to_extmark[last_rendered.image_id] = nil
    state.item_by_image_id[last_rendered.image_id] = nil
    state.image_ids_in_use[last_rendered.image_id] = nil
  end
  bs.preview_image = nil
  bs.preview_item = nil
  bs.preview_last_rendered_item = nil
  bs.preview_last_render_key = nil
  bs.preview_render_key = nil
  bs.preview_source_image_id = nil
  bs.preview_source_page_stamp = nil
  bs.preview_source_range = nil
end

M.cleanup_preview_image = cleanup_preview_image

local function cleanup_preview_item_request(bufnr, item, opts)
  if item == nil then
    return
  end

  opts = opts or {}
  if item.image_id ~= nil then
    local extmark = require("typst-concealer.extmark")
    extmark.clear_image(item.image_id)
    state.image_id_to_extmark[item.image_id] = nil
    state.item_by_image_id[item.image_id] = nil
    state.image_ids_in_use[item.image_id] = nil
  end

  if opts.keep_extmark ~= true and item.extmark_id ~= nil then
    state.prepare_extmark_reuse(bufnr, item.extmark_id)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id, item.extmark_id)
  end
end

M.cleanup_preview_item_request = cleanup_preview_item_request

-- Private copies to avoid circular require with render.lua
local function clamp_range_to_buffer(bufnr, range)
  if range == nil or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count <= 0 then
    return nil
  end

  local start_row = math.max(0, math.min(range[1], line_count - 1))
  local end_row = math.max(start_row, math.min(range[3], line_count - 1))
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
  if #lines == 0 then
    return nil
  end

  local start_col = math.max(0, math.min(range[2], #(lines[1] or "")))
  local end_col
  if start_row == end_row then
    end_col = math.max(start_col, math.min(range[4], #(lines[#lines] or "")))
  else
    end_col = math.max(0, math.min(range[4], #(lines[#lines] or "")))
  end

  return { start_row, start_col, end_row, end_col }
end

local function get_item_effective_range(item)
  if item == nil then
    return nil
  end
  return clamp_range_to_buffer(item.bufnr, item.range)
end

local function normalize_buf_path(path)
  if path == nil or path == "" then
    return ""
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function item_has_stable_render(item)
  return item ~= nil and item.page_path ~= nil and item.natural_cols ~= nil and item.natural_rows ~= nil
end

local function carry_stable_render_metadata(dst, src)
  if dst == nil or not item_has_stable_render(src) then
    return
  end

  dst.page_path = src.page_path
  dst.page_stamp = src.page_stamp
  dst.natural_cols = src.natural_cols
  dst.natural_rows = src.natural_rows
  dst.source_rows = src.source_rows
end

local function item_blocked_by_error_diagnostics(bufnr, item)
  if item == nil then
    return false
  end
  local bucket = state.watch_diagnostics[bufnr]
  local diagnostics_items = bucket and bucket.full or nil
  if diagnostics_items == nil or #diagnostics_items == 0 then
    return false
  end

  local item_file = normalize_buf_path(vim.api.nvim_buf_get_name(item.bufnr))
  local effective_range = get_item_effective_range(item)
  if effective_range == nil then
    return false
  end
  local start_row = effective_range[1] + 1
  local end_row = effective_range[3] + 1
  local item_idx = item.item_idx
  for _, diag in ipairs(diagnostics_items) do
    if diag.type == "E" and diag.item_idx ~= nil and item_idx ~= nil and diag.item_idx == item_idx then
      return true
    end
    if diag.type == "E" and normalize_buf_path(diag.filename) == item_file then
      local lnum = tonumber(diag.lnum)
      if lnum ~= nil and lnum >= start_row and lnum <= end_row then
        return true
      end
    end
  end
  return false
end

local MAX_LINGER_MISSES = 2

--- Allocate image_ids and extmarks for a batch of PlannedItems,
--- reusing resources from previous render pass where possible.
--- @param bufnr integer
--- @param planned_items PlannedItem[]
--- @return table[]
function M.commit_plan(bufnr, planned_items)
  local extmark_mod = require("typst-concealer.extmark")

  local prev_state = state.buffer_render_state[bufnr] or {}
  local prev_items = {}
  for _, item in ipairs(prev_state.full_items or {}) do
    prev_items[#prev_items + 1] = item
  end
  for _, item in ipairs(prev_state.lingering_items or {}) do
    prev_items[#prev_items + 1] = item
  end

  local batch_items = {}
  local visible_batch_items = {}
  local lingering_items = {}
  local used_prev = {}

  for _, planned in ipairs(planned_items) do
    local prev_item = find_matching_prev_item(prev_items, planned, used_prev)
    local image_id, ext_id

    if prev_item ~= nil then
      image_id = prev_item.image_id
      ext_id = prev_item.extmark_id
    else
      image_id = new_image_id(bufnr)
      ext_id = extmark_mod.place_render_extmark(bufnr, image_id, planned.display_range, nil, nil, planned.semantics)
    end

    local item = {
      bufnr = planned.bufnr,
      image_id = image_id,
      extmark_id = ext_id,
      item_idx = planned.item_idx,
      range = planned.range,
      display_range = planned.display_range,
      display_prefix = planned.display_prefix,
      display_suffix = planned.display_suffix,
      str = planned.str,
      prelude_count = planned.prelude_count,
      node_type = planned.node_type,
      semantics = planned.semantics,
      needs_swap = prev_item ~= nil,
      linger_misses = nil,
    }

    carry_stable_render_metadata(item, prev_item)

    batch_items[#batch_items + 1] = item
    state.item_by_image_id[image_id] = item
  end

  for _, item in ipairs(batch_items) do
    if item_blocked_by_error_diagnostics(bufnr, item) then
      cleanup_item(bufnr, item)
    else
      visible_batch_items[#visible_batch_items + 1] = item
    end
  end

  -- Release extmarks/images for items that no longer exist
  for idx, prev_item in ipairs(prev_items) do
    if not used_prev[idx] then
      if
        not item_blocked_by_error_diagnostics(bufnr, prev_item)
        and item_has_stable_render(prev_item)
        and (prev_item.linger_misses or 0) < MAX_LINGER_MISSES
      then
        prev_item.linger_misses = (prev_item.linger_misses or 0) + 1
        lingering_items[#lingering_items + 1] = prev_item
      else
        cleanup_item(bufnr, prev_item)
      end
    end
  end

  state.buffer_render_state[bufnr] = state.buffer_render_state[bufnr] or {}
  state.buffer_render_state[bufnr].full_items = visible_batch_items
  state.buffer_render_state[bufnr].lingering_items = lingering_items

  -- Rebuild per-line item index for O(1) hover lookup
  local line_to_items = {}
  local extmark_to_item = {}
  local visible_items = {}
  for _, item in ipairs(visible_batch_items) do
    visible_items[#visible_items + 1] = item
  end
  for _, item in ipairs(lingering_items) do
    visible_items[#visible_items + 1] = item
  end
  for _, item in ipairs(visible_items) do
    local effective_range = get_item_effective_range(item)
    if effective_range ~= nil then
      extmark_to_item[item.extmark_id] = item
      for row = effective_range[1], effective_range[3] do
        if not line_to_items[row] then
          line_to_items[row] = {}
        end
        line_to_items[row][#line_to_items[row] + 1] = item
      end
    end
  end
  state.buffer_render_state[bufnr].line_to_items = line_to_items
  state.buffer_render_state[bufnr].extmark_to_item = extmark_to_item

  return visible_batch_items
end

--- Apply a rendered page update to the display layer.
--- @param update PageUpdate
function M.accept_page_update(update)
  -- Phase 2: receives PageUpdate from session, replaces direct extmark calls
  -- stub: Phase 2.1
  error("accept_page_update not yet implemented — see Phase 2")
end

--- Release all resources for a buffer and reset render state.
--- @param bufnr integer
function M.hard_reset(bufnr)
  -- stub: Phase 1.7
  error("hard_reset not yet implemented")
end

return M
