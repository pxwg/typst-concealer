--- Resource allocation/release helpers for machine-owned overlays.

local state = require("typst-concealer.state")

local M = {}

--- Allocate a new terminal image id for a buffer.
--- @param bufnr integer
--- @return integer
function M.allocate_image_id(bufnr)
  local pid = state.pid
  for i = pid, 2 ^ 16 + pid - 1 do
    if state.image_ids_in_use[i] == nil then
      state.image_ids_in_use[i] = bufnr
      return i
    end
  end
  print(
    "[typst-concealer] >65536 image ids in use, overflowing. "
      .. "This is probably a bug, you're looking at a very long document or a lot of documents.\n"
      .. "Open an issue if you see this, the cap can be increased if someone actually needs it.\n"
  )
  state.image_ids_in_use = {}
  return M.allocate_image_id(bufnr)
end

--- @param bufnr integer
--- @param image_id integer
--- @param range Range4
--- @param extmark_id integer|nil
--- @param concealing boolean|nil
--- @param semantics NodeSemantics
--- @return integer
function M.place_overlay_extmark(bufnr, image_id, range, extmark_id, concealing, semantics)
  return require("typst-concealer.extmark").place_render_extmark(
    bufnr,
    image_id,
    range,
    extmark_id,
    concealing,
    semantics
  )
end

--- Release a machine-owned image/extmark pair.
--- @param bufnr integer
--- @param image_id integer|nil
--- @param extmark_id integer|nil
function M.release_overlay_resources(bufnr, image_id, extmark_id)
  if extmark_id ~= nil then
    state.prepare_extmark_reuse(bufnr, extmark_id)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id, extmark_id)
  end
  if image_id ~= nil then
    require("typst-concealer.extmark").clear_image(image_id)
    state.image_id_to_extmark[image_id] = nil
    state.item_by_image_id[image_id] = nil
    state.image_ids_in_use[image_id] = nil
  end
end

return M
