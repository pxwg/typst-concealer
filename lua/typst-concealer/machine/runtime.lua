--- Runtime boundary for the full-overlay state machine.
--- Converts reducer effects into Neovim/session/extmark side effects.

local reducer = require("typst-concealer.machine.reducer")
local state = require("typst-concealer.state")
local types = require("typst-concealer.machine.types")

local M = {}

local function copy_range(range)
  if range == nil then
    return nil
  end
  return { range[1], range[2], range[3], range[4] }
end

local function ensure_machine_state()
  if state.machine_state == nil then
    state.machine_state = types.initial_state()
  end
  return state.machine_state
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
  machine_state.buffers[bufnr] = nil

  local to_remove = {}
  for overlay_id, overlay in pairs(machine_state.overlays or {}) do
    if overlay.owner_bufnr == bufnr then
      to_remove[#to_remove + 1] = overlay_id
    end
  end
  for _, overlay_id in ipairs(to_remove) do
    machine_state.overlays[overlay_id] = nil
  end
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
  return require("typst-concealer.apply")._new_image_id(bufnr)
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
    extmark_id = require("typst-concealer.extmark").place_render_extmark(
      overlay.owner_bufnr,
      image_id,
      node.display_range,
      nil,
      opts.concealing,
      node.semantics
    )
  end

  if image_id ~= overlay.image_id or extmark_id ~= overlay.extmark_id then
    dispatch_without_effects({
      type = "overlay_resources_allocated",
      overlay_id = overlay.overlay_id,
      image_id = image_id,
      extmark_id = extmark_id,
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
  }
end

local function build_watch_request(effect)
  local jobs = {}
  for _, overlay_id in ipairs(effect.overlay_ids or {}) do
    ensure_overlay_resources(overlay_id)
    local job = M.build_render_job(ensure_machine_state(), overlay_id)
    if job ~= nil then
      jobs[#jobs + 1] = job
    end
  end

  return {
    request_id = effect.request_id,
    bufnr = effect.bufnr,
    project_scope_id = effect.project_scope_id,
    render_epoch = effect.render_epoch,
    buffer_version = effect.buffer_version,
    layout_version = effect.layout_version,
    jobs = jobs,
  }
end

local function run_ensure_overlay_placeholder(effect)
  ensure_overlay_resources(effect.overlay_id, { place_extmark = true })
end

local function run_request_full_render(effect)
  local request = build_watch_request(effect)
  if #request.jobs == 0 then
    return
  end
  local session = require("typst-concealer.session")
  if type(session.render_request_via_watch) == "function" then
    session.render_request_via_watch(effect.bufnr, request)
  end
end

local function run_commit_overlay(effect)
  local overlay = ensure_overlay_resources(effect.overlay_id, { place_extmark = true })
  local machine_state = ensure_machine_state()
  overlay = machine_state.overlays[effect.overlay_id]
  local _, node = get_overlay_and_node(machine_state, effect.overlay_id)
  if overlay == nil or node == nil or overlay.image_id == nil or overlay.extmark_id == nil then
    return
  end

  local item = M.build_compat_item(machine_state, node, overlay)
  if item == nil then
    return
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

  M.dispatch({
    type = "overlay_commit_succeeded",
    overlay_id = effect.overlay_id,
    node_id = effect.node_id,
  })
  M.rebuild_buffer_read_model(ensure_machine_state(), effect.bufnr)
  state.get_buf_state(effect.bufnr).hover.invalidated = true
  if state.hooks.on_page_committed then
    state.hooks.on_page_committed(effect.bufnr)
  end
end

local function run_retire_overlay(effect)
  local machine_state = ensure_machine_state()
  local overlay = machine_state.overlays[effect.overlay_id]
  if overlay == nil then
    return
  end

  local bufnr = overlay.owner_bufnr
  if overlay.extmark_id ~= nil then
    state.prepare_extmark_reuse(bufnr, overlay.extmark_id)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, state.ns_id, overlay.extmark_id)
  end
  if overlay.image_id ~= nil then
    require("typst-concealer.extmark").clear_image(overlay.image_id)
    state.image_id_to_extmark[overlay.image_id] = nil
    state.item_by_image_id[overlay.image_id] = nil
    state.image_ids_in_use[overlay.image_id] = nil
  end

  overlay.status = "retired"
  M.rebuild_buffer_read_model(machine_state, bufnr)
end

local function run_rerender_buffer(effect)
  require("typst-concealer.plan").render_buf(effect.bufnr)
end

local function run_abandon_request(effect)
  local session = require("typst-concealer.session")
  if type(session.abandon_request) == "function" then
    session.abandon_request(effect.bufnr, effect.old_request_id, effect.new_request_id)
  end
end

function M.run_effects(effects)
  for _, effect in ipairs(effects or {}) do
    if effect.kind == "ensure_overlay_placeholder" then
      run_ensure_overlay_placeholder(effect)
    elseif effect.kind == "request_full_render" then
      run_request_full_render(effect)
    elseif effect.kind == "commit_overlay" then
      run_commit_overlay(effect)
    elseif effect.kind == "retire_overlay" then
      run_retire_overlay(effect)
    elseif effect.kind == "rerender_buffer" then
      run_rerender_buffer(effect)
    elseif effect.kind == "abandon_request" then
      run_abandon_request(effect)
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

return M
