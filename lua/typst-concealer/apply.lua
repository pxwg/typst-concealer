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

--- Allocate image_ids and extmarks for a batch of PlannedItems,
--- reusing resources from previous render pass where possible.
--- @param bufnr integer
--- @param planned_items PlannedItem[]
--- @return table[]
function M.commit_plan(bufnr, planned_items)
  -- stub: Phase 1.6
  error("commit_plan not yet implemented")
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
