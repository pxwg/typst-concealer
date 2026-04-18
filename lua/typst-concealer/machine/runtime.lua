--- Runtime boundary for the full-overlay state machine.
--- Converts reducer effects into Neovim/session/extmark side effects.

local reducer = require("typst-concealer.machine.reducer")
local resources = require("typst-concealer.machine.resources")
local cursor_visibility = require("typst-concealer.cursor-visibility")
local state = require("typst-concealer.state")
local types = require("typst-concealer.machine.types")

local M = {}

local function copy_range(range)
  if range == nil then
    return nil
  end
  return { range[1], range[2], range[3], range[4] }
end

local function ranges_equal(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

local function ensure_machine_state()
  if state.machine_state == nil then
    state.machine_state = types.initial_state()
  end
  state.machine_state.ui = state.machine_state.ui or { buffers = {} }
  state.machine_state.ui.buffers = state.machine_state.ui.buffers or {}
  return state.machine_state
end

local function new_ui_buffer()
  return {
    hover = {
      last_cursor_row = nil,
      last_cursor_col = nil,
      last_mode = nil,
      last_lo = nil,
      last_hi = nil,
      invalidated = false,
    },
    preview = {
      sync_tick = nil,
      sync_needs_full = false,
      render_key = nil,
      last_render_key = nil,
      active_request_id = nil,
      next_request_id = 1,
      status = "idle",
    },
  }
end

function M.get_ui_buffer(bufnr)
  local machine_state = ensure_machine_state()
  local buffers = machine_state.ui.buffers
  if buffers[bufnr] == nil then
    buffers[bufnr] = new_ui_buffer()
  end
  return buffers[bufnr]
end

function M.invalidate_hover(bufnr)
  M.get_ui_buffer(bufnr).hover.invalidated = true
end

function M.set_preview_render_key(bufnr, render_key)
  M.get_ui_buffer(bufnr).preview.render_key = render_key
end

function M.mark_preview_rendered(bufnr)
  local preview = M.get_ui_buffer(bufnr).preview
  preview.last_render_key = preview.render_key
end

function M.reset_preview_state(bufnr)
  local preview = M.get_ui_buffer(bufnr).preview
  preview.sync_tick = nil
  preview.sync_needs_full = false
  preview.render_key = nil
  preview.last_render_key = nil
  preview.active_request_id = nil
  preview.status = "idle"
end

function M.prepare_preview_request(bufnr, item)
  if item == nil then
    return nil
  end
  local preview = M.get_ui_buffer(bufnr).preview
  local n = preview.next_request_id or 1
  preview.next_request_id = n + 1
  preview.active_request_id = "preview:" .. tostring(bufnr) .. ":" .. tostring(n)
  preview.status = "rendering"
  item.preview_request_id = preview.active_request_id
  return item
end

function M.clear_preview_request(bufnr)
  local preview = M.get_ui_buffer(bufnr).preview
  preview.active_request_id = nil
  preview.status = "idle"
end

function M.accept_preview_page_update(update, opts)
  opts = opts or {}
  local preview = M.get_ui_buffer(update.bufnr).preview
  if update.preview_request_id ~= nil and update.preview_request_id ~= preview.active_request_id then
    return false
  end
  if opts.apply ~= false then
    require("typst-concealer.apply").accept_page_update(update)
  end
  preview.status = "ready"
  return true
end

local function get_overlay_and_node(machine_state, overlay_id)
  local overlay = machine_state.overlays[overlay_id]
  if overlay == nil then
    return nil, nil, nil
  end
  local buf = machine_state.buffers[overlay.owner_bufnr]
  if buf == nil then
    return overlay, nil, nil
  end
  return overlay, buf.nodes[overlay.owner_node_id], buf
end

local function cursor_item_from_node(node)
  if node == nil then
    return nil
  end
  return {
    bufnr = node.bufnr,
    range = copy_range(node.source_range),
    display_range = copy_range(node.display_range),
    node_type = node.node_type,
    semantics = node.semantics,
  }
end

local function concealing_for_cursor(node)
  if cursor_visibility.should_preserve_source_at_cursor(node.bufnr, cursor_item_from_node(node)) then
    return false
  end
  return nil
end

local function each_previous_full_item(bufnr, fn)
  local bstate = state.buffer_render_state[bufnr]
  if bstate == nil then
    return
  end
  for _, item in ipairs(bstate.full_items or {}) do
    fn(item)
  end
  for _, item in ipairs(bstate.lingering_items or {}) do
    fn(item)
  end
end

--- @param _machine_state MachineState
--- @param node NodeState
--- @param overlay OverlayState
--- @return table|nil
function M.build_compat_item(_machine_state, node, overlay)
  if node == nil or overlay == nil or overlay.image_id == nil or overlay.extmark_id == nil then
    return nil
  end

  return {
    bufnr = node.bufnr,
    image_id = overlay.image_id,
    extmark_id = overlay.extmark_id,
    item_idx = node.item_idx,
    range = copy_range(node.source_range),
    display_range = copy_range(node.display_range),
    display_prefix = node.display_prefix,
    display_suffix = node.display_suffix,
    str = node.source_text,
    source_text = node.source_text,
    prelude_count = node.prelude_count,
    node_type = node.node_type,
    semantics = node.semantics,
    needs_swap = false,
    page_path = overlay.page_path,
    page_stamp = overlay.page_stamp,
    natural_cols = overlay.natural_cols,
    natural_rows = overlay.natural_rows,
    source_rows = overlay.source_rows,
  }
end

local function index_item(line_to_items, extmark_to_item, item)
  if item == nil or item.extmark_id == nil or item.range == nil then
    return
  end
  extmark_to_item[item.extmark_id] = item
  for row = item.range[1], item.range[3] do
    line_to_items[row] = line_to_items[row] or {}
    line_to_items[row][#line_to_items[row] + 1] = item
  end
end

--- Rebuild the legacy read model consumed by hover/live-preview code.
--- @param machine_state MachineState
--- @param bufnr integer
function M.rebuild_buffer_read_model(machine_state, bufnr)
  machine_state = machine_state or ensure_machine_state()
  local buf = machine_state.buffers[bufnr]

  each_previous_full_item(bufnr, function(item)
    if item.image_id ~= nil then
      state.item_by_image_id[item.image_id] = nil
      if state.image_id_to_extmark[item.image_id] == item.extmark_id then
        state.image_id_to_extmark[item.image_id] = nil
      end
    end
  end)

  local bstate = state.buffer_render_state[bufnr] or {}
  state.buffer_render_state[bufnr] = bstate
  local full_items = {}
  local line_to_items = {}
  local extmark_to_item = {}

  if buf ~= nil then
    for _, node_id in ipairs(buf.node_order or {}) do
      local node = buf.nodes[node_id]
      local overlay = node and node.visible_overlay_id and machine_state.overlays[node.visible_overlay_id] or nil
      if overlay ~= nil and overlay.status == "visible" then
        local item = M.build_compat_item(machine_state, node, overlay)
        if item ~= nil then
          full_items[#full_items + 1] = item
          state.item_by_image_id[item.image_id] = item
          state.image_id_to_extmark[item.image_id] = item.extmark_id
          index_item(line_to_items, extmark_to_item, item)
        end
      end
    end
  end

  bstate.full_items = full_items
  bstate.lingering_items = {}
  bstate.line_to_items = line_to_items
  bstate.extmark_to_item = extmark_to_item
end

function M.reset()
  state.machine_state = types.initial_state()
  return state.machine_state
end

function M.reset_buffer(bufnr)
  local machine_state = ensure_machine_state()
  local to_remove = {}
  for overlay_id, overlay in pairs(machine_state.overlays or {}) do
    if overlay.owner_bufnr == bufnr then
      to_remove[#to_remove + 1] = {
        overlay_id = overlay_id,
        image_id = overlay.image_id,
        extmark_id = overlay.extmark_id,
        page_path = overlay.page_path,
      }
    end
  end
  for _, entry in ipairs(to_remove) do
    resources.release_overlay_resources(bufnr, entry.image_id, entry.extmark_id)
    machine_state.overlays[entry.overlay_id] = nil
    if entry.page_path ~= nil then
      require("typst-concealer.session")._safe_unlink_service_artifact(entry.page_path)
    end
  end
  machine_state.buffers[bufnr] = nil
  if machine_state.ui and machine_state.ui.buffers then
    machine_state.ui.buffers[bufnr] = nil
  end
  if state.active_service_requests then
    state.active_service_requests[bufnr] = nil
  end
  if state.active_preview_service_requests then
    state.active_preview_service_requests[bufnr] = nil
  end
  local session = require("typst-concealer.session")
  if type(session._cleanup_service_workspace_for_buf) == "function" then
    session._cleanup_service_workspace_for_buf(bufnr)
  end
  M.rebuild_buffer_read_model(machine_state, bufnr)
end

function M.get_state()
  return ensure_machine_state()
end

local function dispatch_without_effects(event)
  local new_state = reducer.reduce(ensure_machine_state(), event)
  state.machine_state = new_state
  return new_state
end

local function allocate_image_id(bufnr)
  return resources.allocate_image_id(bufnr)
end

local function ensure_overlay_resources(overlay_id, opts)
  opts = opts or {}
  local machine_state = ensure_machine_state()
  local overlay, node = get_overlay_and_node(machine_state, overlay_id)
  if overlay == nil or node == nil then
    return nil
  end

  local image_id = overlay.image_id or allocate_image_id(overlay.owner_bufnr)
  local extmark_id = overlay.extmark_id
  if opts.place_extmark == true and extmark_id == nil then
    local concealing = opts.concealing
    if concealing == nil then
      concealing = concealing_for_cursor(node)
    end
    extmark_id = resources.place_overlay_extmark(
      overlay.owner_bufnr,
      image_id,
      node.display_range,
      nil,
      concealing,
      node.semantics
    )
  end

  if image_id ~= overlay.image_id or extmark_id ~= overlay.extmark_id then
    local binding_display_range = nil
    local binding_buffer_version = nil
    local binding_layout_version = nil
    if opts.place_extmark == true and extmark_id ~= nil then
      binding_display_range = copy_range(node.display_range)
      binding_buffer_version = overlay.buffer_version
      binding_layout_version = overlay.layout_version
    end
    dispatch_without_effects({
      type = "overlay_resources_allocated",
      overlay_id = overlay.overlay_id,
      image_id = image_id,
      extmark_id = extmark_id,
      binding_buffer_version = binding_buffer_version,
      binding_layout_version = binding_layout_version,
      binding_display_range = binding_display_range,
    })
  end

  return get_overlay_and_node(ensure_machine_state(), overlay_id)
end

--- @param machine_state MachineState
--- @param overlay_id string
--- @return RenderJob|nil
function M.build_render_job(machine_state, overlay_id)
  local overlay, node = get_overlay_and_node(machine_state, overlay_id)
  if overlay == nil or node == nil or overlay.image_id == nil then
    return nil
  end

  return {
    request_id = overlay.request_id,
    request_page_index = overlay.page_index,
    overlay_id = overlay.overlay_id,
    slot_id = overlay.slot_id or node.slot_id,
    node_id = node.node_id,
    bufnr = node.bufnr,
    project_scope_id = node.project_scope_id,
    render_epoch = overlay.render_epoch,
    buffer_version = overlay.buffer_version,
    layout_version = overlay.layout_version,
    item_idx = node.item_idx,
    range = copy_range(node.source_range),
    display_range = copy_range(node.display_range),
    display_prefix = node.display_prefix,
    display_suffix = node.display_suffix,
    source_text = node.source_text,
    str = node.source_text,
    prelude_count = node.prelude_count,
    semantics = node.semantics,
    image_id = overlay.image_id,
    extmark_id = overlay.extmark_id,
    is_stub = false,
    is_tombstone = false,
    slot_status = "dirty",
    slot_dirty = true,
  }
end

local function prepare_render_request(effect)
  local source_request = effect.request or {}
  local jobs = {}
  for _, source_job in ipairs(source_request.jobs or {}) do
    if source_job.is_stub then
      jobs[#jobs + 1] = source_job
    else
      ensure_overlay_resources(source_job.overlay_id)
      local job = M.build_render_job(ensure_machine_state(), source_job.overlay_id)
      if job ~= nil then
        jobs[#jobs + 1] = job
      end
    end
  end

  return {
    request_id = source_request.request_id,
    bufnr = source_request.bufnr,
    project_scope_id = source_request.project_scope_id,
    render_epoch = source_request.render_epoch,
    buffer_version = source_request.buffer_version,
    layout_version = source_request.layout_version,
    shape_epoch = source_request.shape_epoch,
    jobs = jobs,
  }
end

local function run_ensure_overlay_placeholder(effect)
  ensure_overlay_resources(effect.overlay_id, { place_extmark = true })
end

local function run_request_full_render(effect)
  local request = prepare_render_request(effect)
  if #request.jobs == 0 then
    return
  end
  local session = require("typst-concealer.session")
  local config = require("typst-concealer").config
  if config.use_compiler_service and type(session.render_request_via_service) == "function" then
    session.render_request_via_service(request.bufnr, request)
  elseif type(session.render_request_via_watch) == "function" then
    session.render_request_via_watch(request.bufnr, request)
  end
end

local function run_commit_overlay(effect, batch_mode)
  local overlay = ensure_overlay_resources(effect.overlay_id, { place_extmark = true })
  local machine_state = ensure_machine_state()
  overlay = machine_state.overlays[effect.overlay_id]
  local _, node = get_overlay_and_node(machine_state, effect.overlay_id)
  if overlay == nil or node == nil or overlay.image_id == nil or overlay.extmark_id == nil then
    return nil
  end

  local item = M.build_compat_item(machine_state, node, overlay)
  if item == nil then
    return nil
  end

  state.item_by_image_id[item.image_id] = item
  state.image_id_to_extmark[item.image_id] = item.extmark_id

  local extmark = require("typst-concealer.extmark")
  extmark.create_image(effect.page_path, item.image_id, effect.natural_cols, effect.natural_rows)
  extmark.conceal_for_image_id(
    effect.bufnr,
    item.image_id,
    effect.natural_cols,
    effect.natural_rows,
    effect.source_rows
  )

  if batch_mode then
    return { overlay_id = effect.overlay_id, node_id = effect.node_id, bufnr = effect.bufnr }
  end

  M.dispatch({
    type = "overlay_commit_succeeded",
    overlay_id = effect.overlay_id,
    node_id = effect.node_id,
  })
  M.rebuild_buffer_read_model(ensure_machine_state(), effect.bufnr)
  M.invalidate_hover(effect.bufnr)
  if state.hooks.on_page_committed then
    state.hooks.on_page_committed(effect.bufnr)
  end
  return nil
end

local function run_bind_overlay(effect)
  local machine_state = ensure_machine_state()
  local overlay, node, buf = get_overlay_and_node(machine_state, effect.overlay_id)
  if overlay == nil or node == nil or buf == nil then
    return nil
  end
  if
    overlay.status ~= "visible"
    or node.visible_overlay_id ~= overlay.overlay_id
    or overlay.request_id ~= effect.request_id
    or overlay.owner_node_id ~= effect.node_id
    or buf.buffer_version ~= effect.buffer_version
    or buf.layout_version ~= effect.layout_version
    or not ranges_equal(node.display_range, effect.display_range)
  then
    return nil
  end
  if
    overlay.image_id == nil
    or overlay.page_path == nil
    or overlay.natural_cols == nil
    or overlay.natural_rows == nil
  then
    return nil
  end

  local extmark = require("typst-concealer.extmark")
  local extmark_id = overlay.extmark_id
  local concealing = concealing_for_cursor(node)
  if extmark_id ~= nil then
    extmark.swap_extmark_to_range(
      buf.bufnr,
      overlay.image_id,
      extmark_id,
      node.display_range,
      node.semantics,
      concealing
    )
  else
    extmark_id = resources.place_overlay_extmark(
      buf.bufnr,
      overlay.image_id,
      node.display_range,
      nil,
      concealing,
      node.semantics
    )
  end

  local item = M.build_compat_item(machine_state, node, overlay)
  if item == nil then
    item = {
      bufnr = node.bufnr,
      image_id = overlay.image_id,
      extmark_id = extmark_id,
      range = copy_range(node.source_range),
      display_range = copy_range(node.display_range),
      display_prefix = node.display_prefix,
      display_suffix = node.display_suffix,
      str = node.source_text,
      source_text = node.source_text,
      prelude_count = node.prelude_count,
      node_type = node.node_type,
      semantics = node.semantics,
      page_path = overlay.page_path,
      page_stamp = overlay.page_stamp,
      natural_cols = overlay.natural_cols,
      natural_rows = overlay.natural_rows,
      source_rows = overlay.source_rows,
    }
  end
  item.extmark_id = extmark_id
  state.item_by_image_id[overlay.image_id] = item
  state.image_id_to_extmark[overlay.image_id] = extmark_id
  extmark.conceal_for_image_id(
    buf.bufnr,
    overlay.image_id,
    overlay.natural_cols,
    overlay.natural_rows,
    overlay.source_rows or 1
  )

  return {
    overlay_id = overlay.overlay_id,
    request_id = overlay.request_id,
    node_id = node.node_id,
    bufnr = buf.bufnr,
    extmark_id = extmark_id,
    buffer_version = effect.buffer_version,
    layout_version = effect.layout_version,
    display_range = copy_range(node.display_range),
  }
end

local function run_retire_overlay(effect)
  local machine_state = ensure_machine_state()
  local overlay = machine_state.overlays[effect.overlay_id]
  if overlay == nil then
    return
  end

  local bufnr = overlay.owner_bufnr
  local page_path = overlay.page_path
  resources.release_overlay_resources(bufnr, overlay.image_id, overlay.extmark_id)
  machine_state.overlays[effect.overlay_id] = nil

  -- Only delete the backing PNG when no other non-retired overlay shares the
  -- same file path.  Multiple overlays may reference the same PNG (identical
  -- pixel hash), so unconditional deletion would destroy files still needed
  -- by visible or rendering overlays.
  if require("typst-concealer").config.use_compiler_service and page_path then
    require("typst-concealer.session")._safe_unlink_service_artifact(page_path)
  end
  M.rebuild_buffer_read_model(machine_state, bufnr)
end

local function run_rerender_buffer(effect)
  require("typst-concealer.plan").render_buf(effect.bufnr)
end

local function run_abandon_request(effect)
  local config = require("typst-concealer").config
  if config.use_compiler_service then
    local meta = state.active_service_requests and state.active_service_requests[effect.bufnr]
    if meta ~= nil and meta.request_id == effect.old_request_id then
      meta.status = "abandoned"
    end
  else
    local session = require("typst-concealer.session")
    if type(session.abandon_request) == "function" then
      session.abandon_request(effect.bufnr, effect.old_request_id, effect.new_request_id)
    end
  end
end

function M.run_effects(effects)
  local commit_effects = {}
  local bind_effects = {}
  local other_effects = {}
  for _, effect in ipairs(effects or {}) do
    if effect.kind == "commit_overlay" then
      commit_effects[#commit_effects + 1] = effect
    elseif effect.kind == "bind_overlay" then
      bind_effects[#bind_effects + 1] = effect
    else
      other_effects[#other_effects + 1] = effect
    end
  end

  for _, effect in ipairs(other_effects) do
    if effect.kind == "ensure_overlay_placeholder" then
      run_ensure_overlay_placeholder(effect)
    elseif effect.kind == "request_full_render" then
      run_request_full_render(effect)
    elseif effect.kind == "retire_overlay" then
      run_retire_overlay(effect)
    elseif effect.kind == "rerender_buffer" then
      run_rerender_buffer(effect)
    elseif effect.kind == "abandon_request" then
      run_abandon_request(effect)
    end
  end

  if #bind_effects > 0 then
    local batch_entries = {}
    local affected_buffers = {}
    for _, effect in ipairs(bind_effects) do
      local entry = run_bind_overlay(effect)
      if entry ~= nil then
        batch_entries[#batch_entries + 1] = entry
        affected_buffers[entry.bufnr] = true
      end
    end
    if #batch_entries > 0 then
      M.dispatch({
        type = "overlay_bindings_batch_succeeded",
        entries = batch_entries,
      })
      local ms = ensure_machine_state()
      for bufnr in pairs(affected_buffers) do
        M.rebuild_buffer_read_model(ms, bufnr)
        M.invalidate_hover(bufnr)
      end
    end
  end

  if #commit_effects > 0 then
    local batch_entries = {}
    local affected_buffers = {}
    for _, effect in ipairs(commit_effects) do
      local entry = run_commit_overlay(effect, true)
      if entry ~= nil then
        batch_entries[#batch_entries + 1] = entry
        affected_buffers[entry.bufnr] = true
      end
    end
    if #batch_entries > 0 then
      M.dispatch({
        type = "overlay_commits_batch_succeeded",
        entries = batch_entries,
      })
      local ms = ensure_machine_state()
      for bufnr in pairs(affected_buffers) do
        M.rebuild_buffer_read_model(ms, bufnr)
        M.invalidate_hover(bufnr)
        if state.hooks.on_page_committed then
          state.hooks.on_page_committed(bufnr)
        end
      end
    end
  end
end

function M.dispatch(event, opts)
  opts = opts or {}
  local new_state, effects = reducer.reduce(ensure_machine_state(), event)
  state.machine_state = new_state
  if opts.run_effects ~= false then
    M.run_effects(effects)
  end
  return state.machine_state, effects
end

function M.render_buf(bufnr)
  require("typst-concealer.plan").render_buf(bufnr)
end

function M.render_live_preview(bufnr)
  require("typst-concealer.plan").render_live_typst_preview(bufnr)
end

function M.clear_live_preview(bufnr)
  M.clear_preview_request(bufnr)
  require("typst-concealer.plan").clear_live_typst_preview(bufnr)
end

function M.sync_hover(bufnr)
  require("typst-concealer.plan").hide_extmarks_at_cursor(bufnr)
end

function M.sync_cursor_ui(bufnr)
  M.render_live_preview(bufnr)
  local throttle = require("typst-concealer").config.cursor_hover_throttle_ms
  if throttle <= 0 then
    M.sync_hover(bufnr)
    return
  end

  local bs = state.get_buf_state(bufnr)
  if bs.hover.throttle_timer == nil then
    bs.hover.throttle_timer = vim.uv.new_timer()
  end
  bs.hover.throttle_timer:stop()
  bs.hover.throttle_timer:start(
    throttle,
    0,
    vim.schedule_wrap(function()
      M.sync_hover(bufnr)
    end)
  )
end

function M.schedule_live_preview_sync(bufnr, opts)
  require("typst-concealer.plan").schedule_live_preview_sync(bufnr, opts)
end

function M.render_preview_tail(bufnr, item)
  M.prepare_preview_request(bufnr, item)
  local session = require("typst-concealer.session")
  local config = require("typst-concealer").config
  if config.use_compiler_service and type(session.render_preview_tail_via_service) == "function" then
    session.render_preview_tail_via_service(bufnr, item)
  else
    session.render_preview_tail(bufnr, item)
  end
end

return M
