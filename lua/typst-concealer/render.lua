--- Render dispatch layer for typst-concealer.
--- Handles full-buffer re-rendering (render_buf) and live insert-mode preview
--- (render_live_typst_preview).  Both paths share semantics.classify() and the
--- same extmark/session infrastructure.

local semantics_mod = require("typst-concealer.semantics")
local state = require("typst-concealer.state")
local M = {}

local diagnostics = {}

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

--- Build an index of query-matched block nodes keyed by TSNode:id().
--- This index is used only for semantic annotation; actual top-level selection
--- is performed by AST traversal with subtree pruning.
--- @param bufnr integer
--- @param tree TSNode
--- @param query vim.treesitter.Query
--- @return table<integer, table>
local function build_typst_match_index(bufnr, tree, query)
  local index = {}

  for _, match, _ in query:iter_matches(tree, bufnr, nil, nil, { all = true }) do
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
--- If a node is already a matched block, its subtree is pruned.
--- @param root TSNode
--- @param match_index table<integer, table>
--- @return table[]
local function collect_top_level_typst_units(root, match_index)
  local units = {}

  local function visit(node)
    if node == nil then
      return
    end

    local entry = match_index[node:id()]
    if entry ~= nil then
      units[#units + 1] = entry
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

--- Convert top-level units into ordered render entries while accumulating preludes.
--- @param bufnr integer
--- @param units table[]
--- @return table[]
local function build_render_entries_from_units(bufnr, units)
  local render_entries = {}

  for _, unit in ipairs(units) do
    if unit.node_type == "math" then
      render_entries[#render_entries + 1] = {
        range = unit.range,
        prelude_count = #state.runtime_preludes,
        node_type = "math",
      }
    elseif unit.node_type == "code" then
      if vim.list_contains({ "let", "set", "import", "show" }, unit.code_type) then
        state.runtime_preludes[#state.runtime_preludes + 1] = range_to_string(unit.range, bufnr) .. "\n"
      elseif not vim.list_contains({ "pagebreak" }, unit.call_ident or "") then
        render_entries[#render_entries + 1] = {
          range = unit.range,
          prelude_count = #state.runtime_preludes,
          node_type = "code",
        }
      end
    end
  end

  return render_entries
end

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

local function clear_diagnostics(bufnr)
  vim.schedule(function()
    vim.diagnostic.reset(state.ns_id, bufnr)
  end)
end

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

--- Full reset of all concealer state for a buffer (called on disable or wipeout).
--- @param bufnr integer
function M.hard_reset_buf(bufnr)
  local extmark = require("typst-concealer.extmark")
  state.clear_hover_timer(bufnr)
  local bstate = state.buffer_render_state[bufnr]
  if bstate and bstate.full_items then
    for _, item in ipairs(bstate.full_items) do
      cleanup_item(bufnr, item)
    end
  end
  state.buffer_render_state[bufnr] = nil

  vim.api.nvim_buf_clear_namespace(bufnr, state.ns_id, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns_id2, 0, -1)

  state.buffers[bufnr] = nil
  diagnostics = {}
  -- Remove only entries belonging to this buffer from the shared O(1) index
  local to_remove = {}
  for image_id, item in pairs(state.item_by_image_id) do
    if item.bufnr == bufnr then
      to_remove[#to_remove + 1] = image_id
    end
  end
  for _, image_id in ipairs(to_remove) do
    state.item_by_image_id[image_id] = nil
  end
  state.runtime_preludes = {}

  for id, image_bufnr in pairs(state.image_ids_in_use) do
    if bufnr == image_bufnr then
      extmark.clear_image(id)
    end
  end
end

--- Re-render all Typst nodes in bufnr.
--- @param bufnr integer|nil  defaults to current buffer
function M.render_buf(bufnr)
  local main = require("typst-concealer")
  bufnr = bufnr or vim.fn.bufnr()
  clear_diagnostics(bufnr)

  if main._enabled_buffers[bufnr] ~= true then
    M.hard_reset_buf(bufnr)
    local session = require("typst-concealer.session")
    session.stop_watch_session(bufnr, "full")
    return
  end

  diagnostics = {}
  state.runtime_preludes = {}

  local extmark = require("typst-concealer.extmark")
  local session = require("typst-concealer.session")

  local parser = vim.treesitter.get_parser(bufnr)
  local tree = parser:parse()[1]:root()

  local match_index = build_typst_match_index(bufnr, tree, main._typst_query)
  local sorted_entries = build_render_entries_from_units(
    bufnr,
    collect_top_level_typst_units(tree, match_index)
  )

  local prev_items = (state.buffer_render_state[bufnr] and state.buffer_render_state[bufnr].full_items) or {}
  local batch_items = {}

  for idx, entry in ipairs(sorted_entries) do
    local range, prelude_count, node_type = entry.range, entry.prelude_count, entry.node_type
    -- Unified semantic classification: replaces is_block_formula + classify_layout_kind
    local sem = semantics_mod.classify(range, bufnr, node_type)
    local str = range_to_string(range, bufnr)

    local prev_item = prev_items[idx]
    local image_id, ext_id

    if prev_item ~= nil then
      image_id = prev_item.image_id
      ext_id = prev_item.extmark_id
    else
      image_id = new_image_id(bufnr)
      ext_id = extmark.place_render_extmark(bufnr, image_id, range, nil, nil, sem)
    end

    local item = {
      bufnr = bufnr,
      image_id = image_id,
      extmark_id = ext_id,
      range = range,
      str = str,
      prelude_count = prelude_count,
      node_type = node_type,
      semantics = sem, -- unified: replaces layout_kind/is_block/display_as_block
      needs_swap = prev_item ~= nil,
    }
    batch_items[#batch_items + 1] = item
    state.item_by_image_id[image_id] = item
  end

  -- Release extmarks/images for items that no longer exist
  for i = #batch_items + 1, #prev_items do
    cleanup_item(bufnr, prev_items[i])
  end

  state.buffer_render_state[bufnr] = state.buffer_render_state[bufnr] or {}
  state.buffer_render_state[bufnr].full_items = batch_items

  -- Rebuild per-line item index for O(1) hover lookup
  local line_to_items = {}
  for _, item in ipairs(batch_items) do
    for row = item.range[1], item.range[3] do
      if not line_to_items[row] then
        line_to_items[row] = {}
      end
      line_to_items[row][#line_to_items[row] + 1] = item
    end
  end
  state.buffer_render_state[bufnr].line_to_items = line_to_items

  vim.schedule(function()
    session.render_items_via_watch(bufnr, batch_items, "full")
  end)
  -- Reset hover guard so hide_extmarks_at_cursor re-evaluates after render
  state.get_buf_state(bufnr).hover.last_cursor_row = nil
  state.get_buf_state(bufnr).hover.last_mode = nil
  state.get_buf_state(bufnr).hover.last_lo = nil
  state.get_buf_state(bufnr).hover.last_hi = nil
  state.get_buf_state(bufnr).hover.invalidated = true
  M.hide_extmarks_at_cursor(bufnr)
end

--- Hide a single extmark (removes virt_text/virt_lines from display).
--- Returns saved state for later restoration, or nil if the extmark should be skipped.
--- @param bufnr integer
--- @param bs table  per-buffer state
--- @param extmark_id integer
--- @return table|nil saved
local function hide_one_extmark(bufnr, bs, extmark_id)
  local mm = bs.multiline_marks[extmark_id]
  if mm ~= nil then
    if mm.is_block_carrier then
      -- Top-carrier model: read carrier virt_text + virt_lines for save, then delete all ns_id2
      local saved = nil
      if mm.carrier_id then
        local sm = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, mm.carrier_id, { details = true })
        if sm and #sm > 0 then
          saved = { sm[3].virt_text }
          for _, vl in ipairs(sm[3].virt_lines or {}) do
            saved[#saved + 1] = vl
          end
        end
        vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, mm.carrier_id)
        mm.carrier_id = nil
      end
      for _, sid in ipairs(mm.tail_ids or {}) do
        vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, sid)
      end
      mm.tail_ids = {}
      return saved
    end
    -- Non-block multiline (ns_id2 overlay path)
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
    if #mark > 0 and mark[3] and mark[3].virt_text_pos == "right_align" then
      return nil
    end
    local text = {}
    for _, sub_id in ipairs(mm) do
      local sub_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, sub_id, { details = true })
      if sub_mark and sub_mark[3] then
        text[#text + 1] = sub_mark[3].virt_text
      end
      vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, sub_id)
    end
    return text
  else
    -- Single-line extmark
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
    if #mark == 0 then
      return nil
    end
    local row, col, opts = mark[1], mark[2], mark[3]
    local saved = opts.virt_text
    vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, row, col, {
      id = extmark_id,
      virt_text = { { "" } },
      end_row = opts.end_row,
      end_col = opts.end_col,
      conceal = nil,
      virt_text_pos = opts.virt_text_pos,
      invalidate = opts.invalidate,
    })
    return saved
  end
end

--- Restore a previously hidden extmark.
--- @param bufnr integer
--- @param bs table  per-buffer state
--- @param extmark_id integer
--- @param saved table  the saved data returned by hide_one_extmark
--- @param extmark_mod table  require("typst-concealer.extmark")
local function restore_one_extmark(bufnr, bs, extmark_id, saved, extmark_mod)
  extmark_mod.update_extmark_text(bufnr, extmark_id, saved, true)
end

--- Hide / restore extmarks that overlap the cursor position.
--- Called on CursorMoved and ModeChanged.
--- @param bufnr integer
function M.hide_extmarks_at_cursor(bufnr)
  local main = require("typst-concealer")
  local bs = state.get_buf_state(bufnr)
  local extmark_mod = require("typst-concealer.extmark")

  local mode = vim.api.nvim_get_mode().mode

  -- conceal_in_normal mode: don't hide anything, restore all hidden extmarks
  if main.config.conceal_in_normal and mode:find("n", 1, true) ~= nil then
    for id, saved in pairs(bs.currently_hidden_extmark_ids) do
      restore_one_extmark(bufnr, bs, id, saved, extmark_mod)
    end
    bs.currently_hidden_extmark_ids = {}
    bs.hover.last_cursor_row = nil -- force re-process on next call
    bs.hover.last_mode = mode
    bs.hover.last_lo = nil
    bs.hover.last_hi = nil
    bs.hover.invalidated = false
    return
  end

  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1

  -- Determine row range to unconceal
  local is_visual = mode == "v" or mode == "V" or mode == "\22"
  local lo, hi = cursor_row, cursor_row
  if is_visual then
    local vrow = vim.fn.getpos("v")[2] - 1
    lo, hi = math.min(cursor_row, vrow), math.max(cursor_row, vrow)
  end

  if bs.hover.last_mode == mode and bs.hover.last_lo == lo and bs.hover.last_hi == hi and bs.hover.invalidated then
    return
  end

  -- Collect items to hide from line index (no nvim_buf_get_extmarks call)
  local brs = state.buffer_render_state[bufnr]
  local line_to_items = (brs and brs.line_to_items) or {}
  local should_hide = {} -- extmark_id -> item
  for row = lo, hi do
    local row_items = line_to_items[row]
    if row_items then
      for _, item in ipairs(row_items) do
        should_hide[item.extmark_id] = item
      end
    end
  end

  -- Differential update
  local new_hidden = {}

  -- Restore extmarks no longer under cursor
  for extmark_id, saved in pairs(bs.currently_hidden_extmark_ids) do
    if should_hide[extmark_id] then
      new_hidden[extmark_id] = saved -- still under cursor, keep hidden
    else
      restore_one_extmark(bufnr, bs, extmark_id, saved, extmark_mod)
    end
  end

  -- Hide newly entered extmarks
  for extmark_id, _ in pairs(should_hide) do
    if not bs.currently_hidden_extmark_ids[extmark_id] then
      local saved = hide_one_extmark(bufnr, bs, extmark_id)
      if saved ~= nil then
        new_hidden[extmark_id] = saved
      end
    end
  end

  bs.currently_hidden_extmark_ids = new_hidden
  bs.hover.last_cursor_row = cursor_row
  bs.hover.last_mode = mode
  bs.hover.last_lo = lo
  bs.hover.last_hi = hi
  bs.hover.invalidated = false
end

--- Find the outermost math/code block under the cursor.
--- @return integer|nil start_row, integer start_col, integer end_row, integer end_col
local function get_typst_block_at_cursor()
  local parser = vim.treesitter.get_parser(0, "typst")
  local tree = parser:parse()[1]:root()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local crow, ccol = cursor[1] - 1, cursor[2]
  local element = tree:named_descendant_for_range(crow, ccol, crow, ccol)
  local outermost = nil
  while true do
    if element == nil then
      break
    end
    local t = element:type()
    if t == "math" or t == "code" then
      outermost = element
    elseif t == "ERROR" then
      return nil
    end
    element = element:parent()
  end
  if outermost ~= nil then
    return outermost:range()
  end
  return nil
end

--- Stop the live preview session and remove its extmark/image.
--- @param bufnr integer
function M.clear_live_typst_preview(bufnr)
  local bs = state.get_buf_state(bufnr)
  if bs.live_preview_timer then
    if not bs.live_preview_timer:is_closing() then
      bs.live_preview_timer:stop()
      bs.live_preview_timer:close()
    end
    bs.live_preview_timer = nil
  end
  bs.last_preview_str = nil

  local session = require("typst-concealer.session")
  session.stop_watch_session(bufnr, "preview")

  if bs.preview_image ~= nil then
    local extmark = require("typst-concealer.extmark")
    state.prepare_extmark_reuse(bufnr, bs.preview_image.extmark_id)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id, bs.preview_image.extmark_id)
    extmark.clear_image(bs.preview_image.image_id)
    state.image_id_to_extmark[bs.preview_image.image_id] = nil
    state.item_by_image_id[bs.preview_image.image_id] = nil
    bs.preview_image = nil
  end
end

--- Render a live preview of the Typst node under the cursor (insert mode).
--- Uses semantics.classify so that multiline code blocks get the flow wrapper.
--- @param bufnr integer
function M.render_live_typst_preview(bufnr)
  local bs = state.get_buf_state(bufnr)
  local start_row, start_col, end_row, end_col = get_typst_block_at_cursor()
  if start_row == nil then
    M.clear_live_typst_preview(bufnr)
    return
  end

  local range = { start_row, start_col, end_row, end_col }
  local str = range_to_string(range, bufnr)

  if bs.last_preview_str == str then
    return
  end

  -- Debounce: cancel previous timer before starting a new one
  if bs.live_preview_timer then
    if not bs.live_preview_timer:is_closing() then
      bs.live_preview_timer:stop()
      bs.live_preview_timer:close()
    end
  end

  bs.live_preview_timer = vim.uv.new_timer()
  bs.live_preview_timer:start(
    require("typst-concealer").config.live_preview_debounce,
    0,
    vim.schedule_wrap(function()
      if bs.live_preview_timer then
        if not bs.live_preview_timer:is_closing() then
          bs.live_preview_timer:stop()
          bs.live_preview_timer:close()
        end
        bs.live_preview_timer = nil
      end

      bs.last_preview_str = str

      -- Classify as "code" for live preview (same path the batch render uses for code blocks)
      local sem = semantics_mod.classify(range, bufnr, "code")
      local extmark = require("typst-concealer.extmark")
      local session = require("typst-concealer.session")

      local image_id, ext_id
      if bs.preview_image ~= nil then
        image_id = bs.preview_image.image_id
        state.prepare_extmark_reuse(bufnr, bs.preview_image.extmark_id)
        ext_id = extmark.place_render_extmark(bufnr, image_id, range, bs.preview_image.extmark_id, false, sem)
      else
        image_id = new_image_id(bufnr)
        ext_id = extmark.place_render_extmark(bufnr, image_id, range, nil, false, sem)
      end

      -- Remove old preview item from the O(1) lookup index
      if bs.preview_image then
        state.item_by_image_id[bs.preview_image.image_id] = nil
      end

      local item = {
        bufnr = bufnr,
        image_id = image_id,
        extmark_id = ext_id,
        range = range,
        str = str,
        prelude_count = 0,
        node_type = "code",
        semantics = sem,
      }
      -- Register in the O(1) index so conceal_for_image_id can find the semantics
      state.item_by_image_id[image_id] = item
      session.render_items_via_watch(bufnr, { item }, "preview")
      bs.preview_image = { image_id = image_id, extmark_id = ext_id }
    end)
  )
end

return M
