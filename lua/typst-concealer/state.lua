--- Shared mutable state for typst-concealer.
--- All modules read/write these tables directly; Lua module caching guarantees a single instance.
local M = {}

--- Neovim extmark namespaces
M.ns_id = vim.api.nvim_create_namespace("typst-concealer")
-- used for each line of a multiline image
M.ns_id2 = vim.api.nvim_create_namespace("typst-concealer-2")
-- used for virt_lines of block-level multi-line items (separate from conceal_lines extmark)
M.ns_id3 = vim.api.nvim_create_namespace("typst-concealer-3")

--- @type { [integer]: integer[] | { virt_lines: true } | nil }
--- Maps ns_id extmark_id -> list of ns_id2 per-line extmark ids, or {virt_lines=true} for block multiline
M.multiline_marks = {}
--- @type { [integer]: integer }
--- Maps ns_id extmark_id -> ns_id3 virt_lines extmark_id for block multiline items
M.block_virt_lines_marks = {}
--- @type { [integer]: integer }
--- Maps image_id -> ns_id extmark_id
M.image_id_to_extmark = {}
--- @type { [integer]: integer }
--- Maps image_id -> bufnr (tracks which images are currently allocated)
M.image_ids_in_use = {}
--- @type { [integer]: table }
--- Maps extmark_id -> saved virt_text/virt_lines data while cursor is over the extmark
M.Currently_hidden_extmark_ids = {}

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

--- @type { [integer]: { full_items?: table[] } }
M.buffer_render_state = {}

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

--- Release sub-extmarks (ns_id2 / ns_id3) attached to extmark_id before reuse or deletion.
--- @param bufnr integer
--- @param extmark_id integer
function M.prepare_extmark_reuse(bufnr, extmark_id)
  local mm = M.multiline_marks[extmark_id]
  if mm ~= nil then
    if mm.virt_lines then
      local vl_id = M.block_virt_lines_marks[extmark_id]
      if vl_id then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_id3, vl_id)
      end
      M.block_virt_lines_marks[extmark_id] = nil
    else
      for _, id in pairs(mm) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns_id2, id)
      end
    end
    M.multiline_marks[extmark_id] = nil
  end
  M.Currently_hidden_extmark_ids[extmark_id] = nil
end

return M
