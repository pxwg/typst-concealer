--- Shared mutable state for typst-concealer.
--- All modules read/write these tables directly; Lua module caching guarantees a single instance.
local M = {}

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

--- @class typst_watch_session
--- @field kind 'full'
--- @field bufnr integer
--- @field handle uv_process_t|nil
--- @field stdout uv_pipe_t|nil
--- @field stderr uv_pipe_t|nil
--- @field input_path string
--- @field output_prefix string
--- @field output_template string
--- @field poll_timer uv_timer_t|nil
--- @field items table[]
--- @field base_items table[]
--- @field preview_tail_item table|nil
--- @field preview_sidecar_item table|nil
--- @field preview_sidecar_path string
--- @field preview_sidecar_root_relative_path string
--- @field preamble_include_line string
--- @field preview_active boolean
--- @field prelude_chunks string[]
--- @field page_state table
--- @field render_start_index integer
--- @field poll_interval_ms integer|nil
--- @field last_page_count integer
--- @field last_input_text string|nil
--- @field last_preview_sidecar_text string|nil
--- @field stderr_chunks string[]
--- @field dead boolean|nil
--- @field buf_dir string
--- @field source_root string
--- @field effective_root string

--- @type { [integer]: { full?: typst_watch_session } }
M.watch_sessions = {}

--- Aggregated watch diagnostics per buffer/session kind for quickfix injection.
--- @type { [integer]: { full?: table[] } }
M.watch_diagnostics = {}

--- @type { [integer]: { full_items?: table[], line_to_items?: table, extmark_to_item?: table } }
M.buffer_render_state = {}

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
      hover = {
        last_cursor_row = nil,
        last_cursor_col = nil,
        last_mode = nil,
        last_lo = nil,
        last_hi = nil,
        invalidated = false,
        throttle_timer = nil,
      },
    }
  end
  return M.buffers[bufnr]
end

--- O(1) flat index: image_id -> item.  Covers both full-render and live-preview items.
--- Maintained by render.lua (insert on create, delete on cleanup/reset).
--- @type { [integer]: table }
M.item_by_image_id = {}

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

--- Stop and release the per-buffer preview sync timer if it exists.
--- @param bufnr integer
function M.clear_preview_timer(bufnr)
  local bs = M.buffers[bufnr]
  if bs == nil then
    return
  end
  local timer = bs.preview_sync_timer
  if timer == nil then
    return
  end
  if not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  bs.preview_sync_timer = nil
  bs.preview_sync_tick = nil
  bs.preview_sync_needs_full = false
end

--- Release sub-extmarks (ns_id2) attached to extmark_id before reuse or deletion.
--- @param bufnr integer
--- @param extmark_id integer
function M.prepare_extmark_reuse(bufnr, extmark_id)
  local bs = M.get_buf_state(bufnr)
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
