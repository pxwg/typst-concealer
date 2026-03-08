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
--- @field kind 'full' | 'preview'
--- @field bufnr integer
--- @field handle uv_process_t|nil
--- @field stdout uv_pipe_t|nil
--- @field stderr uv_pipe_t|nil
--- @field input_path string
--- @field output_prefix string
--- @field output_template string
--- @field poll_timer uv_timer_t|nil
--- @field items table[]
--- @field page_state table
--- @field last_page_count integer
--- @field stderr_chunks string[]
--- @field dead boolean|nil

--- @type { [integer]: { full?: typst_watch_session, preview?: typst_watch_session } }
M.watch_sessions = {}

--- @type { [integer]: { full_items?: table[], line_to_items?: table } }
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
      live_preview_timer = nil,
      last_preview_str = nil,
      currently_hidden_extmark_ids = {},
      multiline_marks = {},
      hover = {
        last_cursor_row = nil,
        last_mode = nil,
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

--- Terminal cell pixel dimensions (nil until refresh_cell_px_size is called)
M._cell_px_w = nil
M._cell_px_h = nil
--- PPI derived so that 1 typst text line ≈ 1 terminal cell height
M._render_ppi = nil

-- PID-derived base for image IDs (collision-resistant per session)
M.pid = vim.fn.getpid() % 256
M.full_pid = vim.fn.getpid()

--- O(1) lookup: return the item owning image_id, or nil.
--- @param image_id integer
--- @return table|nil
function M.get_item_by_image_id(image_id)
  return M.item_by_image_id[image_id]
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
