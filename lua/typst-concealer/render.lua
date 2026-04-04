--- Render dispatch layer for typst-concealer.
--- Handles full-buffer re-rendering (render_buf) and live insert-mode preview
--- (render_live_typst_preview).  Both paths share semantics.classify() and the
--- same extmark/session infrastructure.

local semantics_mod = require("typst-concealer.semantics")
local state = require("typst-concealer.state")
local M = {}

local diagnostics = {}

local PREVIEW_FLOAT_TARGET_RANGE = { 0, 0, 0, 0 }
local PREVIEW_FLOAT_LINE_COUNT = 2

local candidate_bounds_penalty
local candidate_obstacle_penalty
local list_nearby_float_obstacles

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

local function cleanup_preview_image(bufnr)
  local bs = state.get_buf_state(bufnr)
  local preview = bs.preview_image
  if preview == nil then
    bs.preview_source_image_id = nil
    bs.preview_source_page_stamp = nil
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
  bs.preview_image = nil
  bs.preview_source_image_id = nil
  bs.preview_source_page_stamp = nil
end

local function preview_left_pad_cols(bufnr, range)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    local line = (vim.api.nvim_buf_get_lines(bufnr, range[1], range[1] + 1, false) or { "" })[1] or ""
    local prefix = string.sub(line, 1, range[2])
    return vim.fn.strdisplaywidth(prefix)
  end

  local sp = vim.fn.screenpos(winid, range[1] + 1, range[2] + 1)
  local winpos = vim.api.nvim_win_get_position(winid)
  local textoff = vim.fn.getwininfo(winid)[1].textoff or 0
  local screen_col = math.max(1, (sp.col or 1) - winpos[2] - textoff)
  return screen_col - 1
end

local function get_range_screen_rect(bufnr, range)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return nil
  end

  local start_sp = vim.fn.screenpos(winid, range[1] + 1, range[2] + 1)
  local end_col = math.max(range[2] + 1, range[4])
  local end_sp = vim.fn.screenpos(winid, range[3] + 1, end_col)
  if start_sp == nil or end_sp == nil then
    return nil
  end

  return {
    winid = winid,
    top = math.max(0, (start_sp.row or 1) - 1),
    bottom = math.max(0, (end_sp.row or 1) - 1),
    left = math.max(0, (start_sp.col or 1) - 1),
  }
end

local function make_preview_screen_rect(anchor_rect, natural_cols, natural_rows, vertical)
  local top
  if vertical == "above" then
    top = anchor_rect.top - natural_rows
  else
    top = anchor_rect.bottom + 1
  end
  return {
    top = top,
    bottom = top + natural_rows - 1,
    left = anchor_rect.left,
    right = anchor_rect.left + natural_cols - 1,
    width = natural_cols,
    height = natural_rows,
    vertical = vertical,
  }
end

local function choose_preview_vertical(bufnr, range, natural_cols, natural_rows)
  local bs = state.get_buf_state(bufnr)
  local preferred = (bs.preview_float and bs.preview_float.vertical) or "below"
  local anchor_rect = get_range_screen_rect(bufnr, range)
  if anchor_rect == nil then
    return preferred
  end

  local obstacles = list_nearby_float_obstacles(nil, {
    row = anchor_rect.top,
    col = anchor_rect.left,
  })
  local editor_h = vim.o.lines - vim.o.cmdheight
  local editor_w = vim.o.columns

  local preferred_rect = make_preview_screen_rect(anchor_rect, natural_cols, natural_rows, preferred)
  preferred_rect.bounds_penalty = candidate_bounds_penalty(preferred_rect, editor_h, editor_w)
  preferred_rect.obstacle_penalty = candidate_obstacle_penalty(preferred_rect, obstacles)
  if preferred_rect.bounds_penalty == 0 and preferred_rect.obstacle_penalty == 0 then
    return preferred
  end

  local alternate = preferred == "above" and "below" or "above"
  local alternate_rect = make_preview_screen_rect(anchor_rect, natural_cols, natural_rows, alternate)
  alternate_rect.bounds_penalty = candidate_bounds_penalty(alternate_rect, editor_h, editor_w)
  alternate_rect.obstacle_penalty = candidate_obstacle_penalty(alternate_rect, obstacles)
  local preferred_penalty = preferred_rect.bounds_penalty + preferred_rect.obstacle_penalty
  local alternate_penalty = alternate_rect.bounds_penalty + alternate_rect.obstacle_penalty
  if alternate_penalty < preferred_penalty then
    bs.preview_float.vertical = alternate
    return alternate
  end

  return preferred
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

  if main._enabled_buffers[bufnr] ~= true or not main.is_render_allowed(bufnr) then
    M.hard_reset_buf(bufnr)
    local session = require("typst-concealer.session")
    session.stop_watch_session(bufnr, "full")
    return
  end

  diagnostics = {}
  state.runtime_preludes = {}

  local extmark = require("typst-concealer.extmark")
  local session = require("typst-concealer.session")

  local parser = vim.treesitter.get_parser(bufnr, "typst")
  local tree = parser:parse()[1]:root()

  local match_index = build_typst_match_index(bufnr, tree, main._typst_query)
  local sorted_entries = build_render_entries_from_units(bufnr, collect_top_level_typst_units(tree, match_index))

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

    -- Preserve the last stable rendered page metadata while a fresh watch update
    -- is in flight. This prevents preview consumers from dropping to an empty
    -- state between edits and the next rendered page becoming ready.
    if prev_item ~= nil then
      item.page_path = prev_item.page_path
      item.page_stamp = prev_item.page_stamp
      item.natural_cols = prev_item.natural_cols
      item.natural_rows = prev_item.natural_rows
      item.source_rows = prev_item.source_rows
    end

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
  local extmark_to_item = {}
  for _, item in ipairs(batch_items) do
    extmark_to_item[item.extmark_id] = item
    for row = item.range[1], item.range[3] do
      if not line_to_items[row] then
        line_to_items[row] = {}
      end
      line_to_items[row][#line_to_items[row] + 1] = item
    end
  end
  state.buffer_render_state[bufnr].line_to_items = line_to_items
  state.buffer_render_state[bufnr].extmark_to_item = extmark_to_item

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
--- Returns true when the extmark was hidden and should be tracked.
--- @param bufnr integer
--- @param bs table  per-buffer state
--- @param extmark_id integer
local function hide_one_extmark(bufnr, bs, extmark_id)
  local mm = bs.multiline_marks[extmark_id]
  if mm ~= nil then
    if mm.is_block_carrier then
      if mm.carrier_id then
        vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, mm.carrier_id)
        mm.carrier_id = nil
      end
      for _, sid in ipairs(mm.tail_ids or {}) do
        vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, sid)
      end
      mm.tail_ids = {}
      return true
    end
    -- Non-block multiline (ns_id2 overlay path)
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
    if #mark > 0 and mark[3] and mark[3].virt_text_pos == "right_align" then
      return nil
    end
    for _, sub_id in ipairs(mm) do
      vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, sub_id)
    end
    return true
  else
    -- Single-line extmark
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
    if #mark == 0 then
      return nil
    end
    local row, col, opts = mark[1], mark[2], mark[3]
    vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, row, col, {
      id = extmark_id,
      virt_text = { { "" } },
      end_row = opts.end_row,
      end_col = opts.end_col,
      conceal = nil,
      virt_text_pos = opts.virt_text_pos,
      invalidate = opts.invalidate,
    })
    return true
  end
end

--- Restore a previously hidden extmark from the current rendered item state.
--- @param bufnr integer
--- @param extmark_id integer
local function restore_one_extmark(bufnr, extmark_id)
  local bs = state.get_buf_state(bufnr)
  local brs = state.buffer_render_state[bufnr]
  if brs == nil or brs.extmark_to_item == nil then
    return
  end
  local item = brs.extmark_to_item[extmark_id]
  if item == nil or item.natural_cols == nil or item.natural_rows == nil then
    return
  end
  bs.currently_hidden_extmark_ids[extmark_id] = nil
  require("typst-concealer.extmark").conceal_for_image_id(
    bufnr,
    item.image_id,
    item.natural_cols,
    item.natural_rows,
    item.source_rows or (item.range[3] - item.range[1] + 1)
  )
end

local function cursor_in_range(range, row, col)
  local sr, sc, er, ec = range[1], range[2], range[3], range[4]

  if row < sr or row > er then
    return false
  end

  if sr == er then
    return col >= sc and col < ec
  end

  if row == sr then
    return col >= sc
  end

  if row == er then
    return col < ec
  end

  return true
end

local function should_unconceal_item_for_row(item, row, cursor_row, cursor_col)
  local sem = item.semantics or {}
  local source_kind = sem.source_kind or item.node_type
  local display_kind = sem.display_kind
  local sr, _, er, _ = item.range[1], item.range[2], item.range[3], item.range[4]

  if sr == er and display_kind == "inline" then
    if row ~= cursor_row then
      return false
    end
    return cursor_in_range(item.range, cursor_row, cursor_col)
  end

  if source_kind == "math" or source_kind == "code" then
    return row >= sr and row <= er
  end

  return false
end

--- Hide / restore extmarks that overlap the cursor position.
--- Called on CursorMoved and ModeChanged.
--- @param bufnr integer
function M.hide_extmarks_at_cursor(bufnr)
  local main = require("typst-concealer")
  local bs = state.get_buf_state(bufnr)

  if main._enabled_buffers[bufnr] ~= true or not main.is_render_allowed(bufnr) then
    for id in pairs(bs.currently_hidden_extmark_ids) do
      restore_one_extmark(bufnr, id)
    end
    bs.currently_hidden_extmark_ids = {}
    bs.hover.last_cursor_row = nil
    bs.hover.last_cursor_col = nil
    bs.hover.last_mode = nil
    bs.hover.last_lo = nil
    bs.hover.last_hi = nil
    bs.hover.invalidated = false
    return
  end

  local mode = vim.api.nvim_get_mode().mode

  -- conceal_in_normal mode: don't hide anything, restore all hidden extmarks
  if main.config.conceal_in_normal and mode:find("n", 1, true) ~= nil then
    for id in pairs(bs.currently_hidden_extmark_ids) do
      restore_one_extmark(bufnr, id)
    end
    bs.currently_hidden_extmark_ids = {}
    bs.hover.last_cursor_row = nil -- force re-process on next call
    bs.hover.last_cursor_col = nil
    bs.hover.last_mode = mode
    bs.hover.last_lo = nil
    bs.hover.last_hi = nil
    bs.hover.invalidated = false
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_row = cursor[1] - 1
  local cursor_col = cursor[2]

  -- Determine row range to unconceal
  local is_visual = mode == "v" or mode == "V" or mode == "\22"
  local lo, hi = cursor_row, cursor_row
  if is_visual then
    local vrow = vim.fn.getpos("v")[2] - 1
    lo, hi = math.min(cursor_row, vrow), math.max(cursor_row, vrow)
  end

  -- Skip only when the cursor span is unchanged and no render pass has
  -- invalidated the current hide/restore decision.
  if
    bs.hover.last_mode == mode
    and bs.hover.last_lo == lo
    and bs.hover.last_hi == hi
    and bs.hover.last_cursor_col == cursor_col
    and not bs.hover.invalidated
  then
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
        if should_unconceal_item_for_row(item, row, cursor_row, cursor_col) then
          should_hide[item.extmark_id] = item
        end
      end
    end
  end

  -- Differential update
  local new_hidden = {}

  -- Restore extmarks no longer under cursor
  for extmark_id in pairs(bs.currently_hidden_extmark_ids) do
    if should_hide[extmark_id] then
      new_hidden[extmark_id] = true -- still under cursor, keep hidden
    else
      restore_one_extmark(bufnr, extmark_id)
    end
  end

  -- Hide newly entered extmarks
  for extmark_id, _ in pairs(should_hide) do
    if not bs.currently_hidden_extmark_ids[extmark_id] then
      local hidden = hide_one_extmark(bufnr, bs, extmark_id)
      if hidden ~= nil then
        new_hidden[extmark_id] = true
      end
    end
  end

  bs.currently_hidden_extmark_ids = new_hidden
  bs.hover.last_cursor_row = cursor_row
  bs.hover.last_cursor_col = cursor_col
  bs.hover.last_mode = mode
  bs.hover.last_lo = lo
  bs.hover.last_hi = hi
  bs.hover.invalidated = false
end

local function clamp(x, lo, hi)
  return math.max(lo, math.min(hi, x))
end

local function rect_intersection_area(a, b)
  local left = math.max(a.left, b.left)
  local right = math.min(a.right, b.right)
  local top = math.max(a.top, b.top)
  local bottom = math.min(a.bottom, b.bottom)
  if left > right or top > bottom then
    return 0
  end
  return (right - left + 1) * (bottom - top + 1)
end

local function get_cursor_anchor_screenpos(bufnr)
  local src_winid = vim.fn.bufwinid(bufnr)
  if src_winid == -1 then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(src_winid)
  local sp = vim.fn.screenpos(src_winid, cursor[1], cursor[2] + 1)

  -- screenpos() returns 1-based screen coordinates; float config uses editor-relative row/col.
  local row = math.max(0, (sp.row or 1) - 1)
  local col = math.max(0, (sp.col or 1) - 1)

  return {
    src_winid = src_winid,
    row = row,
    col = col,
  }
end

local function get_float_rect(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  local cfg = vim.api.nvim_win_get_config(winid)
  if cfg.relative == nil or cfg.relative == "" then
    return nil
  end

  local pos = vim.api.nvim_win_get_position(winid)
  local height = vim.api.nvim_win_get_height(winid)
  local width = vim.api.nvim_win_get_width(winid)

  local top = pos[1]
  local left = pos[2]

  return {
    winid = winid,
    top = top,
    left = left,
    bottom = top + height - 1,
    right = left + width - 1,
    width = width,
    height = height,
    zindex = cfg.zindex or 50,
    focusable = cfg.focusable ~= false,
  }
end

local function is_near_anchor(rect, anchor)
  -- only cares about floats that are roughly in the same area as the cursor, to reduce the number of obstacles and speed up scoring
  local margin_row = 12
  local margin_col = 50
  return not (
    rect.bottom < anchor.row - margin_row
    or rect.top > anchor.row + margin_row
    or rect.right < anchor.col - margin_col
    or rect.left > anchor.col + margin_col
  )
end

list_nearby_float_obstacles = function(exclude_winid, anchor)
  local ret = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if winid ~= exclude_winid then
      local rect = get_float_rect(winid)
      if rect ~= nil and is_near_anchor(rect, anchor) then
        ret[#ret + 1] = rect
      end
    end
  end
  return ret
end

local function make_candidate_rect(anchor, width, height, row, col, vertical)
  return {
    top = row,
    left = col,
    bottom = row + height - 1,
    right = col + width - 1,
    width = width,
    height = height,
    dist = math.abs(row - anchor.row) + math.abs(col - anchor.col),
    vertical = vertical,
  }
end

candidate_bounds_penalty = function(rect, editor_h, editor_w)
  local penalty = 0

  if rect.top < 0 then
    penalty = penalty + 1000 + -rect.top * 20
  end
  if rect.left < 0 then
    penalty = penalty + 1000 + -rect.left * 20
  end
  if rect.bottom >= editor_h then
    penalty = penalty + 1000 + (rect.bottom - editor_h + 1) * 20
  end
  if rect.right >= editor_w then
    penalty = penalty + 1000 + (rect.right - editor_w + 1) * 20
  end

  return penalty
end

candidate_obstacle_penalty = function(rect, obstacles)
  local penalty = 0

  for _, obs in ipairs(obstacles) do
    local area = rect_intersection_area(rect, obs)
    if area > 0 then
      local weight = (obs.zindex >= 100) and 8 or 4
      penalty = penalty + area * weight
    end
  end

  return penalty
end

local function candidate_penalty(rect, obstacles, editor_h, editor_w)
  local bounds_penalty = candidate_bounds_penalty(rect, editor_h, editor_w)
  local obstacle_penalty = candidate_obstacle_penalty(rect, obstacles)
  rect.bounds_penalty = bounds_penalty
  rect.obstacle_penalty = obstacle_penalty
  return bounds_penalty + obstacle_penalty + rect.dist
end

local function choose_preview_rect(bufnr, width, height, exclude_winid)
  local anchor = get_cursor_anchor_screenpos(bufnr)
  if anchor == nil then
    return nil
  end
  local bs = state.get_buf_state(bufnr)
  local obstacles = list_nearby_float_obstacles(exclude_winid, anchor)

  local editor_h = vim.o.lines - vim.o.cmdheight
  local editor_w = vim.o.columns
  local preferred_vertical = (bs.preview_float and bs.preview_float.vertical) or "below"

  local candidates = {
    make_candidate_rect(anchor, width, height, anchor.row + 1, anchor.col + 1, "below"),
    make_candidate_rect(anchor, width, height, anchor.row + 1, anchor.col - width - 1, "below"),
    make_candidate_rect(anchor, width, height, anchor.row - height, anchor.col + 1, "above"),
    make_candidate_rect(anchor, width, height, anchor.row - height, anchor.col - width - 1, "above"),
    make_candidate_rect(anchor, width, height, anchor.row + 2, anchor.col, "below"),
    make_candidate_rect(anchor, width, height, anchor.row - height - 1, anchor.col, "above"),
    make_candidate_rect(anchor, width, height, anchor.row, anchor.col + 2, preferred_vertical),
    make_candidate_rect(anchor, width, height, anchor.row, anchor.col - width - 2, preferred_vertical),
  }

  local best = nil
  local best_penalty = math.huge
  local preferred_best = nil
  local preferred_best_penalty = math.huge

  for _, rect in ipairs(candidates) do
    local p = candidate_penalty(rect, obstacles, editor_h, editor_w)
    if
      rect.vertical == preferred_vertical
      and rect.bounds_penalty == 0
      and rect.obstacle_penalty == 0
      and p < preferred_best_penalty
    then
      preferred_best = rect
      preferred_best_penalty = p
    end
    if p < best_penalty then
      best = rect
      best_penalty = p
    end
  end

  best = preferred_best or best
  best.top = clamp(best.top, 0, math.max(0, editor_h - height))
  best.left = clamp(best.left, 0, math.max(0, editor_w - width))

  return best
end

local function preview_win_config(bufnr, width, height, for_create)
  local bs = state.get_buf_state(bufnr)
  local preview_winid = bs.preview_float and bs.preview_float.winid or nil
  local rect = choose_preview_rect(bufnr, math.max(1, width or 1), math.max(1, height or 1), preview_winid)
  if rect == nil then
    return nil
  end
  if bs.preview_float ~= nil and rect.bounds_penalty == 0 and rect.obstacle_penalty == 0 then
    bs.preview_float.vertical = rect.vertical or bs.preview_float.vertical or "below"
  end

  local config = {
    relative = "editor",
    row = rect.top,
    col = rect.left,
    width = rect.width,
    height = rect.height,
    style = "minimal",
    focusable = false,
    zindex = 250,
  }
  if for_create then
    config.noautocmd = true
  end
  return config
end

local function ensure_live_preview_float(bufnr)
  local bs = state.get_buf_state(bufnr)
  local pf = bs.preview_float

  if pf.bufnr == nil or not vim.api.nvim_buf_is_valid(pf.bufnr) then
    pf.bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[pf.bufnr].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(pf.bufnr, 0, -1, false, { "", "" })
  end

  if vim.api.nvim_buf_line_count(pf.bufnr) < PREVIEW_FLOAT_LINE_COUNT then
    vim.api.nvim_buf_set_lines(pf.bufnr, 0, -1, false, { "", "" })
  end

  if pf.winid == nil or not vim.api.nvim_win_is_valid(pf.winid) then
    local cfg = preview_win_config(bufnr, pf.width, pf.height, true)
    if cfg == nil then
      close_live_preview_float(bufnr)
      return nil
    end
    pf.winid = vim.api.nvim_open_win(pf.bufnr, false, cfg)
  else
    local cfg = preview_win_config(bufnr, pf.width, pf.height, false)
    if cfg == nil then
      close_live_preview_float(bufnr)
      return nil
    end
    vim.api.nvim_win_set_config(pf.winid, cfg)
  end

  return pf
end

local function ensure_preview_float_lines(bufnr, line_count)
  local bs = state.get_buf_state(bufnr)
  local pf = bs.preview_float
  if pf.bufnr == nil or not vim.api.nvim_buf_is_valid(pf.bufnr) then
    return
  end

  local count = math.max(PREVIEW_FLOAT_LINE_COUNT, line_count or 1)
  local lines = {}
  for _ = 1, count do
    lines[#lines + 1] = ""
  end
  vim.api.nvim_buf_set_lines(pf.bufnr, 0, -1, false, lines)
end

local function close_live_preview_float(bufnr)
  local bs = state.get_buf_state(bufnr)
  local pf = bs.preview_float

  if pf.winid ~= nil and vim.api.nvim_win_is_valid(pf.winid) then
    pcall(vim.api.nvim_win_close, pf.winid, true)
  end
  if pf.bufnr ~= nil and vim.api.nvim_buf_is_valid(pf.bufnr) then
    pcall(vim.api.nvim_buf_delete, pf.bufnr, { force = true })
  end

  bs.preview_float = {
    bufnr = nil,
    winid = nil,
    width = 1,
    height = 1,
    vertical = "below",
  }
end

function M.sync_live_preview_float(bufnr, width, height)
  local pf = ensure_live_preview_float(bufnr)
  if pf == nil then
    return
  end
  if width ~= nil then
    pf.width = math.max(1, width)
  end
  if height ~= nil then
    pf.height = math.max(1, height)
  end
  if pf.winid ~= nil and vim.api.nvim_win_is_valid(pf.winid) then
    vim.api.nvim_win_set_config(pf.winid, preview_win_config(bufnr, pf.width, pf.height, false))
  end
end

--- Find the outermost math/code block under the cursor in bufnr.
--- @param bufnr integer
--- @return string|nil node_type, integer|nil start_row, integer start_col, integer end_row, integer end_col
local function get_typst_block_at_cursor(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return nil
  end
  local parser = vim.treesitter.get_parser(bufnr, "typst")
  local tree = parser:parse()[1]:root()
  local cursor = vim.api.nvim_win_get_cursor(winid)
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
    local node_type = outermost:type()
    return node_type, outermost:range()
  end
  return nil
end

local function same_range(a, b)
  if a == nil or b == nil then
    return false
  end
  return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

local function find_full_item_for_range(bufnr, range)
  local bstate = state.buffer_render_state[bufnr]
  if bstate == nil or bstate.full_items == nil then
    return nil
  end

  for _, item in ipairs(bstate.full_items) do
    if item.node_type == "math" and same_range(item.range, range) then
      return item
    end
  end

  return nil
end

local function present_preview_item(bufnr, item)
  if item == nil then
    cleanup_preview_image(bufnr)
    return
  end

  local bs = state.get_buf_state(bufnr)
  if item.page_path == nil or item.natural_cols == nil or item.natural_rows == nil then
    if bs.preview_source_image_id == item.image_id and bs.preview_image ~= nil then
      return
    end
    cleanup_preview_image(bufnr)
    return
  end

  local extmark = require("typst-concealer.extmark")
  local vertical = choose_preview_vertical(bufnr, item.range, item.natural_cols, item.natural_rows)
  local anchor_row = vertical == "above" and item.range[1] or item.range[3]
  local extmark_id = bs.preview_image and bs.preview_image.extmark_id or nil
  extmark_id =
    extmark.show_virtual_image(bufnr, extmark_id, anchor_row, item.image_id, item.natural_cols, item.natural_rows, {
      above = vertical == "above",
      left_pad_cols = preview_left_pad_cols(bufnr, item.range),
    })

  bs.preview_image = {
    extmark_id = extmark_id,
    target_bufnr = bufnr,
    natural_cols = item.natural_cols,
    natural_rows = item.natural_rows,
  }
  bs.preview_source_image_id = item.image_id
  bs.preview_source_page_stamp = item.page_stamp
end

local function present_cached_preview(bufnr, range)
  local bs = state.get_buf_state(bufnr)
  local preview = bs.preview_image
  if preview == nil or bs.preview_source_image_id == nil then
    return false
  end
  if preview.natural_cols == nil or preview.natural_rows == nil then
    return false
  end

  local extmark = require("typst-concealer.extmark")
  local vertical = choose_preview_vertical(bufnr, range, preview.natural_cols, preview.natural_rows)
  local anchor_row = vertical == "above" and range[1] or range[3]
  local extmark_id = extmark.show_virtual_image(
    bufnr,
    preview.extmark_id,
    anchor_row,
    bs.preview_source_image_id,
    preview.natural_cols,
    preview.natural_rows,
    {
      above = vertical == "above",
      left_pad_cols = preview_left_pad_cols(bufnr, range),
    }
  )
  preview.extmark_id = extmark_id
  preview.target_bufnr = bufnr
  return true
end

--- Stop the live preview session and remove its extmark/image.
--- @param bufnr integer
function M.clear_live_typst_preview(bufnr)
  cleanup_preview_image(bufnr)
end

--- Render a live preview image in virtual lines around the math node under the cursor.
--- @param bufnr integer
function M.render_live_typst_preview(bufnr)
  local main = require("typst-concealer")
  if
    main._enabled_buffers[bufnr] ~= true
    or not main.is_render_allowed(bufnr)
    or (main.config and main.config.live_preview_enabled == false)
  then
    M.clear_live_typst_preview(bufnr)
    return
  end
  local node_type, start_row, start_col, end_row, end_col = get_typst_block_at_cursor(bufnr)
  if start_row == nil or node_type ~= "math" then
    M.clear_live_typst_preview(bufnr)
    return
  end

  local range = { start_row, start_col, end_row, end_col }
  local item = find_full_item_for_range(bufnr, range)
  if item ~= nil then
    present_preview_item(bufnr, item)
    return
  end

  if present_cached_preview(bufnr, range) then
    return
  end

  M.clear_live_typst_preview(bufnr)
end

return M
