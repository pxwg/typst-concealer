--- Render dispatch layer for typst-concealer.
--- Handles full-buffer re-rendering (render_buf) and live insert-mode preview
--- (render_live_typst_preview).  Both paths share semantics.classify() and the
--- same extmark/session infrastructure.

local state = require("typst-concealer.state")
local M = {}

--- Per-buffer backend registry.  Falls back to default_backend when no
--- per-buffer entry is found (backwards-compatible with set_backend).
local default_backend = nil
local buf_backends = {} --- @type { [integer]: table }

--- Set the default backend (used by all buffers that haven't been explicitly assigned).
--- @param b table
function M.set_backend(b)
  default_backend = b
end

--- Assign a specific backend to a buffer.
--- @param bufnr integer
--- @param b table
function M.set_buf_backend(bufnr, b)
  buf_backends[bufnr] = b
end

--- Return the backend for the given buffer.
--- @param bufnr integer
--- @return table
local function get_backend(bufnr)
  return buf_backends[bufnr] or default_backend
end

local diagnostics = {}

local PREVIEW_FLOAT_TARGET_RANGE = { 0, 0, 0, 0 }
local PREVIEW_FLOAT_LINE_COUNT = 2

local candidate_bounds_penalty
local candidate_obstacle_penalty
local list_nearby_float_obstacles
local cursor_in_range

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

local function full_line_range(bufnr, row)
  local line = (vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false) or { "" })[1] or ""
  return { row, 0, row, #line }
end

local function line_text(bufnr, row)
  return (vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false) or { "" })[1] or ""
end

local function trim_right(s)
  return (s or ""):gsub("%s+$", "")
end

local function trim_left(s)
  return (s or ""):gsub("^%s+", "")
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

local function new_image_id(bufnr)
  return require("typst-concealer.apply")._new_image_id(bufnr)
end

local function clear_diagnostics(bufnr)
  vim.schedule(function()
    vim.diagnostic.reset(state.ns_id, bufnr)
  end)
end

local function is_insert_like_mode(mode)
  mode = mode or vim.api.nvim_get_mode().mode or ""
  return mode:find("i", 1, true) ~= nil or mode:find("R", 1, true) ~= nil
end

local function item_has_stable_render(item)
  return item ~= nil and item.page_path ~= nil and item.natural_cols ~= nil and item.natural_rows ~= nil
end

local function cleanup_item(bufnr, item)
  return require("typst-concealer.apply").cleanup_item(bufnr, item)
end

local function cleanup_preview_image(bufnr)
  return require("typst-concealer.apply").cleanup_preview_image(bufnr)
end

local function cleanup_preview_item_request(bufnr, item, opts)
  return require("typst-concealer.apply").cleanup_preview_item_request(bufnr, item, opts)
end

local function get_text_slice(bufnr, start_row, start_col, end_row, end_col)
  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {}), "\n")
end

cursor_in_range = function(range, row, col, opts)
  opts = opts or {}
  local sr, sc, er, ec = range[1], range[2], range[3], range[4]
  local include_right_edge = opts.include_right_edge == true

  if row < sr or row > er then
    return false
  end

  if sr == er then
    if include_right_edge then
      return col >= sc and col <= ec
    end
    return col >= sc and col < ec
  end

  if row == sr then
    return col >= sc
  end

  if row == er then
    if include_right_edge then
      return col <= ec
    end
    return col < ec
  end

  return true
end

local function cursor_engages_inline_item(range, row, col, mode)
  return cursor_in_range(range, row, col, {
    include_right_edge = is_insert_like_mode(mode),
  })
end

local function cursor_near_range(range, row, col)
  if range == nil or row < range[1] or row > range[3] then
    return false
  end

  local slack_cols = 8
  if range[1] == range[3] then
    return col >= math.max(0, range[2] - 1) and col <= math.max(range[4], range[2]) + slack_cols
  end
  if row == range[1] then
    return col >= math.max(0, range[2] - 1)
  end
  if row == range[3] then
    return col <= range[4] + slack_cols
  end
  return true
end

local function should_preserve_preview(bufnr, cursor_row, cursor_col)
  local mode = vim.api.nvim_get_mode().mode or ""
  if not is_insert_like_mode(mode) then
    return false
  end

  local bs = state.get_buf_state(bufnr)
  return bs.preview_image ~= nil and cursor_near_range(bs.preview_source_range, cursor_row, cursor_col)
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
  local preferred = (bs.preview_float and bs.preview_float.vertical) or "above"
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
  state.clear_hover_timer(bufnr)
  state.clear_preview_timer(bufnr)
  require("typst-concealer.apply").hard_reset(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns_id, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, state.ns_id2, 0, -1)
  state.buffers[bufnr] = nil
  diagnostics = {}
  local b = get_backend(bufnr)
  if b then
    b.reset_buf_state(bufnr)
  end
  buf_backends[bufnr] = nil
end

--- Re-render all Typst nodes in bufnr.
--- @param bufnr integer|nil  defaults to current buffer
function M.render_buf(bufnr)
  local main = require("typst-concealer")
  bufnr = bufnr or vim.fn.bufnr()
  clear_diagnostics(bufnr)

  if main._enabled_buffers[bufnr] ~= true or not main.is_render_allowed(bufnr) then
    M.hard_reset_buf(bufnr)
    get_backend(bufnr).stop_session(bufnr, "full")
    return
  end

  diagnostics = {}
  state.runtime_preludes = {}

  local bs = state.get_buf_state(bufnr)
  local units = get_backend(bufnr).collect_units(bufnr)
  bs.pending_change = nil
  local sorted_entries = build_render_entries_from_units(bufnr, units)

  local apply = require("typst-concealer.apply")

  -- Build PlannedItems from sorted_entries
  local planned_items = {}
  for idx, entry in ipairs(sorted_entries) do
    local range, prelude_count, node_type = entry.range, entry.prelude_count, entry.node_type
    local sem = get_backend(bufnr).classify(range, bufnr, node_type)
    local str = range_to_string(range, bufnr)
    local display_range = range
    local display_prefix = nil
    local display_suffix = nil

    if node_type == "math" and sem.display_kind == "block" and range[1] == range[3] then
      display_range = full_line_range(bufnr, range[1])

      if sem.render_whole_line then
        local line = line_text(bufnr, range[1])
        display_prefix = trim_right(line:sub(1, range[2]))
        display_suffix = trim_left(line:sub(range[4] + 1))
      end
    end

    planned_items[#planned_items + 1] = {
      bufnr = bufnr,
      item_idx = idx,
      range = range,
      display_range = display_range,
      display_prefix = display_prefix,
      display_suffix = display_suffix,
      str = str,
      prelude_count = prelude_count,
      node_type = node_type,
      semantics = sem,
    }
  end

  state.buffer_render_state[bufnr] = state.buffer_render_state[bufnr] or {}
  state.buffer_render_state[bufnr].full_units = units
  state.buffer_render_state[bufnr].runtime_preludes = state.runtime_preludes

  local visible_batch_items = apply.commit_plan(bufnr, planned_items)

  vim.schedule(function()
    get_backend(bufnr).render_items(bufnr, visible_batch_items)
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
  local effective_range = get_item_effective_range(item)
  if effective_range == nil then
    return
  end
  bs.currently_hidden_extmark_ids[extmark_id] = nil
  require("typst-concealer.extmark").conceal_for_image_id(
    bufnr,
    item.image_id,
    item.natural_cols,
    item.natural_rows,
    item.source_rows or (effective_range[3] - effective_range[1] + 1)
  )
end

local function should_unconceal_item_for_row(item, row, cursor_row, cursor_col)
  local effective_range = get_item_effective_range(item)
  if effective_range == nil then
    return false
  end
  local sem = item.semantics or {}
  local source_kind = sem.source_kind or item.node_type
  local display_kind = sem.display_kind
  local sr, _, er, _ = effective_range[1], effective_range[2], effective_range[3], effective_range[4]

  if sr == er and source_kind == "math" then
    if row ~= cursor_row then
      return false
    end
    local trigger_range = effective_range
    if sem.render_whole_line and item.display_range ~= nil then
      trigger_range = clamp_range_to_buffer(item.bufnr, item.display_range) or effective_range
    end
    return cursor_engages_inline_item(trigger_range, cursor_row, cursor_col)
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
  local preferred_vertical = (bs.preview_float and bs.preview_float.vertical) or "above"

  local candidates = {
    make_candidate_rect(anchor, width, height, anchor.row - height, anchor.col + 1, "above"),
    make_candidate_rect(anchor, width, height, anchor.row - height, anchor.col - width - 1, "above"),
    make_candidate_rect(anchor, width, height, anchor.row - height - 1, anchor.col, "above"),
    make_candidate_rect(anchor, width, height, anchor.row + 1, anchor.col + 1, "below"),
    make_candidate_rect(anchor, width, height, anchor.row + 1, anchor.col - width - 1, "below"),
    make_candidate_rect(anchor, width, height, anchor.row + 2, anchor.col, "below"),
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
    bs.preview_float.vertical = rect.vertical or bs.preview_float.vertical or "above"
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
    vertical = "above",
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

local function find_full_item_at_cursor(bufnr, row, col, mode)
  local bstate = state.buffer_render_state[bufnr]
  if bstate == nil or bstate.full_items == nil then
    return nil
  end

  local candidates = bstate.line_to_items and bstate.line_to_items[row] or bstate.full_items
  local best_item = nil
  for _, item in ipairs(candidates) do
    local effective_range = get_item_effective_range(item)
    if
      effective_range ~= nil
      and item.node_type == "math"
      and cursor_engages_inline_item(effective_range, row, col, mode)
    then
      if best_item == nil then
        best_item = item
      else
        local best_range = get_item_effective_range(best_item)
        local best_span = (best_range[3] - best_range[1]) * 100000 + (best_range[4] - best_range[2])
        local item_span = (effective_range[3] - effective_range[1]) * 100000 + (effective_range[4] - effective_range[2])
        if item_span < best_span then
          best_item = item
        end
      end
    end
  end

  return best_item
end

local function present_preview_item(bufnr, item, cursor_row, cursor_col)
  if item == nil then
    cleanup_preview_image(bufnr)
    return
  end

  local bs = state.get_buf_state(bufnr)
  local effective_range = get_item_effective_range(item)
  if effective_range == nil then
    cleanup_preview_image(bufnr)
    return
  end
  if not item_has_stable_render(item) then
    if bs.preview_source_image_id == item.image_id and bs.preview_image ~= nil then
      return
    end
    if item_has_stable_render(bs.preview_last_rendered_item) then
      M.present_rendered_preview_item(bufnr, bs.preview_last_rendered_item)
      return
    end
    if should_preserve_preview(bufnr, cursor_row, cursor_col) then
      return
    end
    cleanup_preview_image(bufnr)
    return
  end

  local vertical = choose_preview_vertical(bufnr, effective_range, item.natural_cols, item.natural_rows)
  require("typst-concealer.apply").show_preview_item(bufnr, item, {
    vertical = vertical,
    anchor_row = vertical == "above" and effective_range[1] or effective_range[3],
    left_pad_cols = preview_left_pad_cols(bufnr, effective_range),
    effective_range = effective_range,
  })
end

function M.present_rendered_preview_item(bufnr, item)
  if item == nil then
    cleanup_preview_image(bufnr)
    return
  end

  local effective_range = get_item_effective_range(item)
  if effective_range == nil then
    cleanup_preview_image(bufnr)
    return
  end
  if not item_has_stable_render(item) then
    return
  end

  local vertical = choose_preview_vertical(bufnr, effective_range, item.natural_cols, item.natural_rows)
  require("typst-concealer.apply").show_rendered_preview_item(bufnr, item, {
    vertical = vertical,
    anchor_row = vertical == "above" and effective_range[1] or effective_range[3],
    left_pad_cols = preview_left_pad_cols(bufnr, effective_range),
    effective_range = effective_range,
  })
end

--- Stop the live preview tail page and remove its extmark/image.
--- @param bufnr integer
function M.clear_live_typst_preview(bufnr)
  get_backend(bufnr).clear_preview_tail(bufnr)
  cleanup_preview_image(bufnr)
end

--- Coalesce insert-mode text/cursor churn into a single preview sync pipeline.
--- @param bufnr integer
--- @param opts table|nil { refresh_full?: boolean, immediate?: boolean }
function M.schedule_live_preview_sync(bufnr, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  opts = opts or {}
  local main = require("typst-concealer")
  local bs = state.get_buf_state(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  bs.preview_sync_tick = tick
  bs.preview_sync_needs_full = bs.preview_sync_needs_full or opts.refresh_full == true

  if bs.preview_sync_timer == nil or bs.preview_sync_timer:is_closing() then
    bs.preview_sync_timer = vim.uv.new_timer()
  end

  local delay = opts.immediate == true and 0 or (main.config.live_preview_debounce or 100)
  bs.preview_sync_timer:stop()
  bs.preview_sync_timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      local current_bs = state.get_buf_state(bufnr)
      local scheduled_tick = current_bs.preview_sync_tick
      local needs_full = current_bs.preview_sync_needs_full
      current_bs.preview_sync_tick = nil
      current_bs.preview_sync_needs_full = false

      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      if needs_full or scheduled_tick ~= vim.api.nvim_buf_get_changedtick(bufnr) then
        M.render_buf(bufnr)
      end
      M.render_live_typst_preview(bufnr)
      M.hide_extmarks_at_cursor(bufnr)
    end)
  )
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

  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    M.clear_live_typst_preview(bufnr)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local cursor_row = cursor[1] - 1
  local cursor_col = cursor[2]
  local mode = vim.api.nvim_get_mode().mode or ""

  -- Live preview must target the same maximal math units as full rendering.
  -- Reusing the full-item index avoids previewing nested descendants that are
  -- not independently rendered, which could otherwise duplicate the formula
  -- under the cursor while anchoring the float to the wrong range.
  local item = find_full_item_at_cursor(bufnr, cursor_row, cursor_col, mode)
  if item ~= nil then
    local b = get_backend(bufnr)
    if b.make_highlighted_preview then
      local preview_str, render_key, source_str = b.make_highlighted_preview(item, cursor_row, cursor_col, mode)
      if type(preview_str) ~= "string" or type(render_key) ~= "string" or type(source_str) ~= "string" then
        M.clear_live_typst_preview(bufnr)
        return
      end
      local bs = state.get_buf_state(bufnr)
      if bs.preview_item ~= nil and bs.preview_render_key == render_key and item_has_stable_render(bs.preview_item) then
        M.present_rendered_preview_item(bufnr, bs.preview_item)
        return
      end
      if bs.preview_render_key == render_key then
        present_preview_item(bufnr, item, cursor_row, cursor_col)
        return
      end

      if item_has_stable_render(bs.preview_item) then
        bs.preview_last_rendered_item = bs.preview_item
        bs.preview_last_render_key = bs.preview_render_key
      end
      present_preview_item(bufnr, item, cursor_row, cursor_col)

      local shared_extmark_id = bs.preview_image and bs.preview_image.extmark_id or nil
      if
        bs.preview_item ~= nil and (bs.preview_image == nil or bs.preview_item.image_id ~= bs.preview_image.image_id)
      then
        cleanup_preview_item_request(bufnr, bs.preview_item, { keep_extmark = shared_extmark_id ~= nil })
      end

      local preview_item = require("typst-concealer.apply").allocate_preview_item(
        bufnr,
        item,
        preview_str,
        source_str,
        render_key,
        shared_extmark_id
      )
      b.render_preview_tail(bufnr, preview_item)
      return
    end
  end

  if should_preserve_preview(bufnr, cursor_row, cursor_col) then
    return
  end
  M.clear_live_typst_preview(bufnr)
end

-- Register post-render UI reaction hooks so apply.lua can trigger them
-- without a direct reverse require("typst-concealer.plan") dependency.
state.hooks.on_page_committed = function(bufnr)
  M.hide_extmarks_at_cursor(bufnr)
  M.render_live_typst_preview(bufnr)
end
state.hooks.present_rendered_preview_item = function(bufnr, item)
  M.present_rendered_preview_item(bufnr, item)
end

return M
