--- Shared mutable state for typst-concealer.
--- Lua module caching guarantees a single instance.
--- Write access is intentionally concentrated: apply.lua owns resource indices,
--- plan.lua owns per-buffer render state; session.lua owns render backends.
local M = {}
local machine_types = require("typst-concealer.machine.types")

--- Neovim extmark namespaces
M.ns_id = vim.api.nvim_create_namespace("typst-concealer")
-- used for each line of a multiline image
M.ns_id2 = vim.api.nvim_create_namespace("typst-concealer-2")

--- @type { [integer]: integer }
--- Maps image_id -> ns_id extmark_id
M.image_id_to_extmark = {}
--- @type { [integer]: integer }
--- Maps image_id -> bufnr (tracks which images are currently allocated)
M.image_ids_in_use = {}

--- @class typst_compiler_service
--- @field handle uv_process_t|nil
--- @field stdin uv_pipe_t|nil
--- @field stdout uv_pipe_t|nil
--- @field stderr uv_pipe_t|nil
--- @field bufnr integer
--- @field kind "full"|"preview"|nil
--- @field dead boolean|nil
--- @field line_buffer string
--- @field stderr_line_buffer string
--- @field cache_dir string|nil
--- @field inflight { kind: string, request_id: string, is_prewarm: boolean|nil, preview_context_hash: string|nil }|nil
--- @field pending_full_request table|nil
--- @field pending_formula_requests table[]|nil
--- @field pending_preview_request table|nil
--- @field pending_prewarm_requests table[]|nil
--- @field preview_warmed_signatures table<string, boolean>|nil

--- @type { [integer]: { full?: typst_compiler_service, preview?: typst_compiler_service } }
M.compiler_services = {}

--- @type { [integer]: RenderRequestMeta|nil }
M.active_service_requests = {}

--- Formula render batches are transport bookkeeping only.  Per-node ownership
--- lives on machine nodes/overlays; a batch may contain many independent nodes.
--- @type { [integer]: table<string, RenderRequestMeta> }
M.active_formula_batches = {}

--- Persistent per-buffer formula managers.  These are the UI/presentation
--- boundary for formula nodes; the reducer remains the logical machine.
--- @type table<integer, table>
M.formula_managers = {}

--- @type { [integer]: { request_id: string, item: table }|nil }
M.active_preview_service_requests = {}

--- @type { [integer]: string|nil }
M.service_cache_dirs = {}

--- @type { [integer]: string|nil }
M.service_workspace_dirs = {}

--- Aggregated render diagnostics per buffer for quickfix injection.
--- @type { [integer]: { full?: table[] } }
M.render_diagnostics = {}

--- @type { [integer]: { full_items?: table[], lingering_items?: table[], full_units?: table[], line_to_items?: table, extmark_to_item?: table, runtime_preludes?: string[] } }
M.buffer_render_state = {}

--- Single machine snapshot for the full-overlay reducer.
--- Runtime owns effect execution; reducer owns logical transitions.
--- @type MachineState
M.machine_state = machine_types.initial_state()

--- Per-buffer mutable render state (extmark, live-preview, conceal transients).
--- @type table<integer, table>
M.buffers = {}

--- Lazily create and return per-buffer state for bufnr.
--- @param bufnr integer
--- @return table
function M.get_buf_state(bufnr)
  if not M.buffers[bufnr] then
    M.buffers[bufnr] = {
      preview_image = nil,
      preview_item = nil,
      preview_last_rendered_item = nil,
      preview_last_render_key = nil,
      preview_render_key = nil,
      preview_sync_timer = nil,
      preview_sync_tick = nil,
      preview_sync_needs_full = false,
      preview_source_image_id = nil,
      preview_source_page_stamp = nil,
      preview_source_range = nil,
      preview_float = {
        bufnr = nil,
        winid = nil,
        width = 1,
        height = 1,
        vertical = "above",
      },
      currently_hidden_extmark_ids = {},
      multiline_marks = {},
      inline_line_marks = {},
      inline_line_suppressed_rows = {},
      hover = {
        last_cursor_row = nil,
        last_cursor_col = nil,
        last_mode = nil,
        last_lo = nil,
        last_hi = nil,
        invalidated = false,
        throttle_timer = nil,
      },
      visible_refresh_timer = nil,
      pending_change = nil,
      change_tracker_attached = false,
    }
  end
  return M.buffers[bufnr]
end

--- O(1) flat index: image_id -> item.  Covers both full-render and live-preview items.
--- Maintained by apply.lua (insert on create, delete on cleanup/reset).
--- @type { [integer]: table }
M.item_by_image_id = {}

--- UI reaction hooks registered by plan.lua at module load time.
--- Allows apply.lua to trigger post-page-commit UI reactions without a
--- direct reverse require("typst-concealer.plan") dependency.
--- @type { on_page_committed: (fun(bufnr: integer)|nil), present_rendered_preview_item: (fun(bufnr: integer, item: table)|nil) }
M.hooks = {
  on_page_committed = nil,
  present_rendered_preview_item = nil,
}

--- Prelude strings accumulated during the current render_buf pass
--- @type string[]
M.runtime_preludes = {}

--- Cached path rewrite results, partitioned by buffer and root signature.
--- @type table<integer, table<string, table<string, string>>>
M.path_rewrite_cache = {}

--- Terminal cell pixel dimensions (nil until refresh_cell_px_size is called)
M._cell_px_w = nil
M._cell_px_h = nil
--- PPI derived so that 1 typst text line ≈ 1 terminal cell height
M._render_ppi = nil
M.typst_package_roots = nil
--- Monotonic generation for terminal-side image backing.  Incrementing this
--- makes visible overlays re-upload their existing PNGs without re-rendering.
M.terminal_upload_epoch = 1

-- PID-derived base for image IDs (collision-resistant per session)
M.pid = vim.fn.getpid() % 256
M.full_pid = vim.fn.getpid()

--- O(1) lookup: return the item owning image_id, or nil.
--- @param image_id integer
--- @return table|nil
function M.get_item_by_image_id(image_id)
  return M.item_by_image_id[image_id]
end

--- Stop and release the per-buffer hover throttle timer if it exists.
--- Safe to call repeatedly.
--- @param bufnr integer
function M.clear_hover_timer(bufnr)
  local bs = M.buffers[bufnr]
  if bs == nil or bs.hover == nil then
    return
  end
  local timer = bs.hover.throttle_timer
  if timer == nil then
    return
  end
  if not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  bs.hover.throttle_timer = nil
end

--- Stop and release the per-buffer visible-overlay refresh timer if it exists.
--- @param bufnr integer
function M.clear_visible_refresh_timer(bufnr)
  local bs = M.buffers[bufnr]
  if bs == nil then
    return
  end
  local timer = bs.visible_refresh_timer
  if timer ~= nil then
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    bs.visible_refresh_timer = nil
  end
end

--- Stop and release the per-buffer preview sync timer if it exists.
--- @param bufnr integer
function M.clear_preview_timer(bufnr)
  local bs = M.buffers[bufnr]
  if bs == nil then
    return
  end
  local timer = bs.preview_sync_timer
  if timer ~= nil then
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    bs.preview_sync_timer = nil
  end
  bs.preview_sync_tick = nil
  bs.preview_sync_needs_full = false

  local ft = bs._full_render_timer
  if ft ~= nil then
    if not ft:is_closing() then
      ft:stop()
      ft:close()
    end
    bs._full_render_timer = nil
  end

  M.clear_visible_refresh_timer(bufnr)
end

--- Release sub-extmarks (ns_id2) attached to extmark_id before reuse or deletion.
--- @param bufnr integer
--- @param extmark_id integer
function M.prepare_extmark_reuse(bufnr, extmark_id)
  local bs = M.get_buf_state(bufnr)
  local ok_mark, mark = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, M.ns_id, extmark_id, {})
  if ok_mark and mark ~= nil and #mark > 0 then
    local inline = bs.inline_line_marks and bs.inline_line_marks[mark[1]]
    if inline ~= nil then
      if inline.carrier_id ~= nil then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_id2, inline.carrier_id)
      end
      if inline.conceal_id ~= nil then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_id2, inline.conceal_id)
      end
      bs.inline_line_marks[mark[1]] = nil
    end
  end

  local mm = bs.multiline_marks[extmark_id]
  if mm ~= nil then
    if mm.is_block_carrier then
      if mm.carrier_id then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_id2, mm.carrier_id)
      end
      for _, id in ipairs(mm.tail_ids or {}) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_id2, id)
      end
    else
      for _, id in pairs(mm) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_id2, id)
      end
    end
    bs.multiline_marks[extmark_id] = nil
  end
  bs.currently_hidden_extmark_ids[extmark_id] = nil
end

return M
