--- Pure reducer for the full-overlay state machine.

local types = require("typst-concealer.machine.types")

local M = {}

local function deepcopy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do
    out[deepcopy(k, seen)] = deepcopy(v, seen)
  end
  return out
end

local function clone_state(state)
  return deepcopy(state or types.initial_state())
end

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

local function row_overlap_len(a, b)
  local top = math.max(a[1], b[1])
  local bottom = math.min(a[3], b[3])
  if bottom < top then
    return 0
  end
  return bottom - top + 1
end

local function row_gap_len(a, b)
  if a[3] < b[1] then
    return b[1] - a[3]
  end
  if b[3] < a[1] then
    return a[1] - b[3]
  end
  return 0
end

local function row_ranges_overlap(a, b)
  return row_overlap_len(a, b) > 0
end

local function col_delta_len(a, b)
  return math.abs(a[2] - b[2]) + math.abs(a[4] - b[4])
end

local function next_id(counters, field, prefix)
  local n = counters[field] or 1
  counters[field] = n + 1
  return prefix .. tostring(n)
end

local function ensure_buffer(state, bufnr, project_scope_id)
  local buf = state.buffers[bufnr]
  if buf == nil then
    buf = {
      bufnr = bufnr,
      project_scope_id = project_scope_id,
      buffer_version = 0,
      layout_version = 0,
      render_epoch = 0,
      active_request_id = nil,
      nodes = {},
      node_order = {},
    }
    state.buffers[bufnr] = buf
  end
  return buf
end

local function node_matches_scan(node, scanned, project_scope_id, bufnr)
  if node == nil or scanned == nil then
    return false
  end
  if node.status == "deleted_confirmed" then
    return false
  end
  if node.bufnr ~= bufnr or node.project_scope_id ~= project_scope_id then
    return false
  end
  if node.node_type ~= scanned.node_type then
    return false
  end
  return node.source_text_hash == scanned.source_text_hash and node.context_hash == scanned.context_hash
end

local function node_identity_can_range_match(node, scanned, project_scope_id, bufnr)
  if node == nil or scanned == nil then
    return false
  end
  if node.status == "deleted_confirmed" then
    return false
  end
  if node.bufnr ~= bufnr or node.project_scope_id ~= project_scope_id then
    return false
  end
  if node.node_type ~= scanned.node_type then
    return false
  end

  local overlap = row_overlap_len(node.source_range, scanned.source_range)
  local gap = row_gap_len(node.source_range, scanned.source_range)
  return overlap > 0 or gap <= 1
end

local function node_identity_rank(node)
  if node.status == "orphaned" then
    return 1
  end
  return 2
end

local function best_by_range(old_nodes, scanned, used_old, project_scope_id, bufnr, predicate)
  local best = nil
  local best_rank = -1
  local best_overlap = -1
  local best_gap = math.huge
  local best_col_delta = math.huge

  for _, old in pairs(old_nodes or {}) do
    if not used_old[old.node_id] and predicate(old, scanned, project_scope_id, bufnr) then
      local rank = node_identity_rank(old)
      local overlap = row_overlap_len(old.source_range, scanned.source_range)
      local gap = row_gap_len(old.source_range, scanned.source_range)
      local col_delta = col_delta_len(old.source_range, scanned.source_range)
      if
        rank > best_rank
        or (rank == best_rank and overlap > best_overlap)
        or (rank == best_rank and overlap == best_overlap and gap < best_gap)
        or (rank == best_rank and overlap == best_overlap and gap == best_gap and col_delta < best_col_delta)
      then
        best = old
        best_rank = rank
        best_overlap = overlap
        best_gap = gap
        best_col_delta = col_delta
      end
    end
  end

  return best
end

local function find_stable_key_node(old_nodes, scanned, used_old, project_scope_id, bufnr)
  if scanned.stable_key == nil then
    return nil
  end
  for _, old in pairs(old_nodes or {}) do
    if
      not used_old[old.node_id]
      and old.status ~= "deleted_confirmed"
      and old.stable_key == scanned.stable_key
      and old.bufnr == bufnr
      and old.project_scope_id == project_scope_id
    then
      return old
    end
  end
end

local function find_best_old_node(old_nodes, scanned, used_old, project_scope_id, bufnr)
  local stable = find_stable_key_node(old_nodes, scanned, used_old, project_scope_id, bufnr)
  if stable ~= nil then
    return stable
  end

  local exact = best_by_range(old_nodes, scanned, used_old, project_scope_id, bufnr, node_matches_scan)
  if exact ~= nil then
    return exact
  end

  return best_by_range(old_nodes, scanned, used_old, project_scope_id, bufnr, node_identity_can_range_match)
end

local function retire_overlapping_orphans(state, buf, committed_node, effects)
  for _, other_id in ipairs(buf.node_order or {}) do
    if other_id ~= committed_node.node_id then
      local other = buf.nodes[other_id]
      if
        other ~= nil
        and other.status == "orphaned"
        and other.visible_overlay_id ~= nil
        and row_ranges_overlap(other.display_range, committed_node.display_range)
      then
        local overlay = state.overlays[other.visible_overlay_id]
        if overlay ~= nil then
          overlay.status = "retiring"
          effects[#effects + 1] = {
            kind = "retire_overlay",
            overlay_id = overlay.overlay_id,
          }
        end
        other.visible_overlay_id = nil
        other.candidate_overlay_id = nil
        other.status = "deleted_confirmed"
      end
    end
  end
end

local function node_render_inputs_equal(node, scanned)
  return node.source_text_hash == scanned.source_text_hash
    and node.context_hash == scanned.context_hash
    and node.prelude_count == (scanned.prelude_count or 0)
    and ranges_equal(node.source_range, scanned.source_range)
    and ranges_equal(node.display_range, scanned.display_range)
end

local function patch_node(prev, scanned, buffer_version, layout_version)
  local node = deepcopy(prev)
  node.stable_key = scanned.stable_key
  node.item_idx = scanned.item_idx
  node.node_type = scanned.node_type
  node.source_range = copy_range(scanned.source_range)
  node.display_range = copy_range(scanned.display_range)
  node.display_prefix = scanned.display_prefix
  node.display_suffix = scanned.display_suffix
  node.source_text = scanned.source_text
  node.source_text_hash = scanned.source_text_hash
  node.context_hash = scanned.context_hash
  node.prelude_count = scanned.prelude_count or 0
  node.semantics = deepcopy(scanned.semantics)
  node.last_buffer_version = buffer_version
  node.last_layout_version = layout_version
  return node
end

local function new_node(state, bufnr, project_scope_id, scanned, buffer_version, layout_version)
  return {
    node_id = next_id(state.counters, "next_node_id", "node:"),
    stable_key = scanned.stable_key,
    bufnr = bufnr,
    project_scope_id = project_scope_id,
    item_idx = scanned.item_idx,
    node_type = scanned.node_type,
    source_range = copy_range(scanned.source_range),
    display_range = copy_range(scanned.display_range),
    display_prefix = scanned.display_prefix,
    display_suffix = scanned.display_suffix,
    source_text = scanned.source_text,
    source_text_hash = scanned.source_text_hash,
    context_hash = scanned.context_hash,
    prelude_count = scanned.prelude_count or 0,
    semantics = deepcopy(scanned.semantics),
    status = "pending",
    visible_overlay_id = nil,
    candidate_overlay_id = nil,
    last_rendered_epoch = nil,
    last_buffer_version = buffer_version,
    last_layout_version = layout_version,
  }
end

local function new_overlay(state, buf, node, request_id, page_index)
  local has_visible = node.visible_overlay_id ~= nil
  local overlay = {
    overlay_id = next_id(state.counters, "next_overlay_id", "overlay:"),
    owner_node_id = node.node_id,
    owner_bufnr = buf.bufnr,
    owner_project_scope_id = buf.project_scope_id,
    request_id = request_id,
    page_index = page_index,
    session_id = "full:" .. tostring(buf.bufnr),
    render_epoch = buf.render_epoch,
    buffer_version = buf.buffer_version,
    layout_version = buf.layout_version,
    extmark_id = nil,
    image_id = nil,
    page_path = nil,
    page_stamp = nil,
    natural_cols = nil,
    natural_rows = nil,
    source_rows = nil,
    status = has_visible and "rendering" or "placeholder",
  }
  state.overlays[overlay.overlay_id] = overlay
  return overlay
end

local function render_job_from_node(node, overlay)
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
    semantics = deepcopy(node.semantics),
    image_id = overlay.image_id,
    extmark_id = overlay.extmark_id,
  }
end

local function should_rerender_node(node)
  return node.status == "stale" or node.status == "pending"
end

local function retire_old_request_candidates(state, buf, old_request_id, effects, new_request_id)
  if old_request_id == nil then
    return
  end

  effects[#effects + 1] = {
    kind = "abandon_request",
    bufnr = buf.bufnr,
    old_request_id = old_request_id,
    new_request_id = new_request_id,
  }

  for _, overlay in pairs(state.overlays) do
    if overlay.owner_bufnr == buf.bufnr and overlay.request_id == old_request_id and overlay.status ~= "visible" then
      overlay.status = "retiring"
      effects[#effects + 1] = {
        kind = "retire_overlay",
        overlay_id = overlay.overlay_id,
      }
    end
  end
end

local function reduce_nodes_scanned(state, ev)
  local new_state = clone_state(state)
  local effects = {}

  local buf = ensure_buffer(new_state, ev.bufnr, ev.project_scope_id)
  buf.project_scope_id = ev.project_scope_id
  buf.buffer_version = ev.buffer_version
  buf.layout_version = ev.layout_version

  local old_nodes = buf.nodes or {}
  local next_nodes = {}
  local next_order = {}
  local used_old = {}

  for idx, scanned in ipairs(ev.scanned_nodes or {}) do
    scanned.item_idx = scanned.item_idx or idx
    local prev = find_best_old_node(old_nodes, scanned, used_old, ev.project_scope_id, ev.bufnr)
    local node

    if prev ~= nil then
      used_old[prev.node_id] = true
      local unchanged = node_render_inputs_equal(prev, scanned)
      node = patch_node(prev, scanned, ev.buffer_version, ev.layout_version)
      if unchanged and prev.status ~= "deleted_confirmed" then
        if node.candidate_overlay_id ~= nil then
          node.status = prev.status
        elseif node.visible_overlay_id ~= nil then
          node.status = "stable"
        else
          node.status = "pending"
        end
      else
        node.candidate_overlay_id = nil
        node.status = node.visible_overlay_id ~= nil and "stale" or "pending"
      end
    else
      node = new_node(new_state, ev.bufnr, ev.project_scope_id, scanned, ev.buffer_version, ev.layout_version)
    end

    next_nodes[node.node_id] = node
    next_order[#next_order + 1] = node.node_id
  end

  for node_id, old in pairs(old_nodes) do
    if not used_old[node_id] then
      local node = deepcopy(old)
      node.status = node.visible_overlay_id ~= nil and "orphaned" or "deleted_confirmed"
      node.candidate_overlay_id = nil
      next_nodes[node_id] = node
      next_order[#next_order + 1] = node_id
    end
  end

  buf.nodes = next_nodes
  buf.node_order = next_order

  return new_state, effects
end

local function reduce_full_render_requested(state, ev)
  local new_state = clone_state(state)
  local effects = {}

  local buf = new_state.buffers[ev.bufnr]
  if buf == nil then
    return new_state, effects
  end

  local render_node_ids = {}
  for _, node_id in ipairs(buf.node_order or {}) do
    local node = buf.nodes[node_id]
    if node ~= nil and should_rerender_node(node) then
      render_node_ids[#render_node_ids + 1] = node_id
    end
  end
  if #render_node_ids == 0 then
    return new_state, effects
  end

  buf.render_epoch = (buf.render_epoch or 0) + 1
  local request_id = next_id(new_state.counters, "next_request_id", "request:")
  retire_old_request_candidates(new_state, buf, buf.active_request_id, effects, request_id)
  buf.active_request_id = request_id

  local jobs = {}
  local page_index = 0
  for _, node_id in ipairs(render_node_ids) do
    local node = buf.nodes[node_id]
    page_index = page_index + 1
    local overlay = new_overlay(new_state, buf, node, request_id, page_index)
    node.candidate_overlay_id = overlay.overlay_id
    node.status = "pending"
    jobs[#jobs + 1] = render_job_from_node(node, overlay)

    if node.visible_overlay_id == nil then
      effects[#effects + 1] = {
        kind = "ensure_overlay_placeholder",
        overlay_id = overlay.overlay_id,
        bufnr = buf.bufnr,
        node_id = node.node_id,
        display_range = copy_range(node.display_range),
        semantics = deepcopy(node.semantics),
      }
    end
  end

  effects[#effects + 1] = {
    kind = "request_full_render",
    request = {
      request_id = request_id,
      bufnr = buf.bufnr,
      project_scope_id = buf.project_scope_id,
      render_epoch = buf.render_epoch,
      buffer_version = buf.buffer_version,
      layout_version = buf.layout_version,
      jobs = jobs,
    },
  }

  return new_state, effects
end

local function reduce_overlay_page_ready(state, ev)
  local new_state = clone_state(state)
  local effects = {}

  local overlay = new_state.overlays[ev.overlay_id]
  if overlay == nil then
    return new_state, effects
  end

  local buf = new_state.buffers[overlay.owner_bufnr]
  if buf == nil then
    return new_state, effects
  end

  local node = buf.nodes[overlay.owner_node_id]
  if node == nil then
    return new_state, effects
  end

  if overlay.request_id ~= ev.request_id then
    return new_state, effects
  end
  if overlay.page_index ~= nil and overlay.page_index ~= ev.request_page_index then
    return new_state, effects
  end

  if overlay.owner_node_id ~= ev.owner_node_id then
    return new_state, effects
  end
  if overlay.owner_bufnr ~= ev.owner_bufnr then
    return new_state, effects
  end
  if overlay.owner_project_scope_id ~= ev.owner_project_scope_id then
    return new_state, effects
  end

  if overlay.render_epoch ~= ev.render_epoch then
    return new_state, effects
  end
  if overlay.buffer_version ~= ev.buffer_version then
    return new_state, effects
  end
  if overlay.layout_version ~= ev.layout_version then
    return new_state, effects
  end

  if node.candidate_overlay_id ~= overlay.overlay_id then
    return new_state, effects
  end

  overlay.page_path = ev.page_path
  overlay.page_stamp = ev.page_stamp
  overlay.natural_cols = ev.natural_cols
  overlay.natural_rows = ev.natural_rows
  overlay.source_rows = ev.source_rows
  overlay.status = "ready"
  node.status = "ready"

  effects[#effects + 1] = {
    kind = "commit_overlay",
    overlay_id = overlay.overlay_id,
    node_id = node.node_id,
    bufnr = buf.bufnr,
    page_path = ev.page_path,
    natural_cols = ev.natural_cols,
    natural_rows = ev.natural_rows,
    source_rows = ev.source_rows,
  }

  return new_state, effects
end

local function reduce_overlay_resources_allocated(state, ev)
  local new_state = clone_state(state)
  local overlay = new_state.overlays[ev.overlay_id]
  if overlay == nil then
    return new_state, {}
  end

  overlay.image_id = ev.image_id
  overlay.extmark_id = ev.extmark_id
  return new_state, {}
end

local function reduce_overlay_commit_succeeded(state, ev)
  local new_state = clone_state(state)
  local effects = {}

  local overlay = new_state.overlays[ev.overlay_id]
  if overlay == nil or overlay.owner_node_id ~= ev.node_id then
    return new_state, effects
  end

  local buf = new_state.buffers[overlay.owner_bufnr]
  if buf == nil then
    return new_state, effects
  end

  local node = buf.nodes[overlay.owner_node_id]
  if node == nil or node.candidate_overlay_id ~= overlay.overlay_id then
    return new_state, effects
  end

  local old_visible_id = node.visible_overlay_id
  overlay.status = "visible"
  node.visible_overlay_id = overlay.overlay_id
  node.candidate_overlay_id = nil
  node.status = "stable"
  node.last_rendered_epoch = overlay.render_epoch
  node.last_buffer_version = overlay.buffer_version
  node.last_layout_version = overlay.layout_version

  if old_visible_id ~= nil and old_visible_id ~= overlay.overlay_id then
    local old_overlay = new_state.overlays[old_visible_id]
    if old_overlay ~= nil then
      old_overlay.status = "retiring"
      effects[#effects + 1] = {
        kind = "retire_overlay",
        overlay_id = old_visible_id,
      }
    end
  end
  retire_overlapping_orphans(new_state, buf, node, effects)

  return new_state, effects
end

local function reduce_buffer_layout_changed(state, ev)
  local new_state = clone_state(state)
  local effects = {}

  local buf = new_state.buffers[ev.bufnr]
  if buf == nil then
    return new_state, effects
  end

  buf.layout_version = ev.new_layout_version
  for _, node_id in ipairs(buf.node_order or {}) do
    local node = buf.nodes[node_id]
    if node ~= nil and node.status ~= "orphaned" and node.status ~= "deleted_confirmed" then
      node.candidate_overlay_id = nil
      node.status = node.visible_overlay_id ~= nil and "stale" or "pending"
    end
  end

  effects[#effects + 1] = {
    kind = "rerender_buffer",
    bufnr = ev.bufnr,
  }

  return new_state, effects
end

local function reduce_request_abandoned(state, ev)
  local new_state = clone_state(state)
  local effects = {}

  for _, overlay in pairs(new_state.overlays or {}) do
    if overlay.owner_bufnr == ev.bufnr and overlay.request_id == ev.request_id and overlay.status ~= "visible" then
      overlay.status = "retiring"
      effects[#effects + 1] = {
        kind = "retire_overlay",
        overlay_id = overlay.overlay_id,
      }
    end
  end

  local buf = new_state.buffers[ev.bufnr]
  if buf ~= nil then
    for _, node in pairs(buf.nodes or {}) do
      local candidate = node.candidate_overlay_id and new_state.overlays[node.candidate_overlay_id] or nil
      if candidate ~= nil and candidate.request_id == ev.request_id then
        node.candidate_overlay_id = nil
        if node.status ~= "orphaned" and node.status ~= "deleted_confirmed" then
          node.status = node.visible_overlay_id ~= nil and "stale" or "pending"
        end
      end
    end
  end

  return new_state, effects
end

local function reduce_node_deleted_confirmed(state, ev)
  local new_state = clone_state(state)
  local effects = {}

  local buf = new_state.buffers[ev.bufnr]
  if buf == nil then
    return new_state, effects
  end

  local node = buf.nodes[ev.node_id]
  if node == nil then
    return new_state, effects
  end

  local old_visible_id = node.visible_overlay_id
  node.status = "deleted_confirmed"
  node.candidate_overlay_id = nil
  node.visible_overlay_id = nil

  if old_visible_id ~= nil then
    local overlay = new_state.overlays[old_visible_id]
    if overlay ~= nil and overlay.status ~= "retired" then
      overlay.status = "retiring"
      effects[#effects + 1] = {
        kind = "retire_overlay",
        overlay_id = old_visible_id,
      }
    end
  end

  return new_state, effects
end

function M.reduce(state, event)
  if event.type == "nodes_scanned" then
    return reduce_nodes_scanned(state, event)
  elseif event.type == "full_render_requested" then
    return reduce_full_render_requested(state, event)
  elseif event.type == "overlay_page_ready" then
    return reduce_overlay_page_ready(state, event)
  elseif event.type == "overlay_resources_allocated" then
    return reduce_overlay_resources_allocated(state, event)
  elseif event.type == "overlay_commit_succeeded" then
    return reduce_overlay_commit_succeeded(state, event)
  elseif event.type == "buffer_layout_changed" then
    return reduce_buffer_layout_changed(state, event)
  elseif event.type == "request_abandoned" then
    return reduce_request_abandoned(state, event)
  elseif event.type == "node_deleted_confirmed" then
    return reduce_node_deleted_confirmed(state, event)
  end

  return state or types.initial_state(), {}
end

M._clone_state = clone_state

return M
