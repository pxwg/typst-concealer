--- Shared type annotations and constructors for the full-overlay state machine.

local M = {}

--- @alias NodeStatus
--- | "stable"
--- | "stale"
--- | "pending"
--- | "ready"
--- | "deleted"

--- @alias OverlayStatus
--- | "placeholder"
--- | "rendering"
--- | "ready"
--- | "visible"
--- | "retiring"
--- | "retired"

--- @alias WatchRequestStatus
--- | "active"
--- | "abandoned"

--- @alias NodeType "math" | "code"
--- @alias ConstraintKind "intrinsic" | "flow"
--- @alias DisplayKind "inline" | "block"

--- @class Range4
--- @field [1] integer
--- @field [2] integer
--- @field [3] integer
--- @field [4] integer

--- @class ProjectScope
--- @field project_scope_id string
--- @field source_root string
--- @field effective_root string
--- @field inputs_signature string
--- @field preamble_signature string
--- @field context_signature string

--- @class NodeSemantics
--- @field constraint_kind ConstraintKind
--- @field display_kind DisplayKind
--- @field render_whole_line boolean?

--- @class NodeState
--- @field node_id string
--- @field stable_key string|nil
--- @field bufnr integer
--- @field project_scope_id string
--- @field item_idx integer
--- @field node_type NodeType
--- @field source_range Range4
--- @field display_range Range4
--- @field display_prefix string|nil
--- @field display_suffix string|nil
--- @field source_text string
--- @field source_text_hash string
--- @field context_hash string
--- @field prelude_count integer
--- @field semantics NodeSemantics
--- @field status NodeStatus
--- @field visible_overlay_id string|nil
--- @field candidate_overlay_id string|nil
--- @field last_rendered_epoch integer|nil
--- @field last_buffer_version integer
--- @field last_layout_version integer

--- @class OverlayState
--- @field overlay_id string
--- @field owner_node_id string
--- @field owner_bufnr integer
--- @field owner_project_scope_id string
--- @field request_id string|nil
--- @field page_index integer|nil
--- @field session_id string|nil
--- @field render_epoch integer
--- @field buffer_version integer
--- @field layout_version integer
--- @field extmark_id integer|nil
--- @field image_id integer|nil
--- @field page_path string|nil
--- @field page_stamp string|nil
--- @field natural_cols integer|nil
--- @field natural_rows integer|nil
--- @field source_rows integer|nil
--- @field status OverlayStatus

--- @class BufferState
--- @field bufnr integer
--- @field project_scope_id string
--- @field buffer_version integer
--- @field layout_version integer
--- @field render_epoch integer
--- @field active_request_id string|nil
--- @field nodes table<string, NodeState>
--- @field node_order string[]

--- @class MachineCounters
--- @field next_node_id integer
--- @field next_overlay_id integer
--- @field next_request_id integer

--- @class MachineState
--- @field buffers table<integer, BufferState>
--- @field projects table<string, ProjectScope>
--- @field overlays table<string, OverlayState>
--- @field counters MachineCounters

--- @class ScannedNode
--- @field stable_key string|nil
--- @field item_idx integer
--- @field node_type NodeType
--- @field source_range Range4
--- @field display_range Range4
--- @field display_prefix string|nil
--- @field display_suffix string|nil
--- @field source_text string
--- @field source_text_hash string
--- @field context_hash string
--- @field prelude_count integer
--- @field semantics NodeSemantics

--- @class RenderJob
--- @field request_id string
--- @field request_page_index integer
--- @field overlay_id string
--- @field node_id string
--- @field bufnr integer
--- @field project_scope_id string
--- @field render_epoch integer
--- @field buffer_version integer
--- @field layout_version integer
--- @field item_idx integer
--- @field range Range4
--- @field display_range Range4
--- @field source_text string
--- @field prelude_count integer
--- @field semantics NodeSemantics
--- @field display_prefix string|nil
--- @field display_suffix string|nil
--- @field image_id integer
--- @field extmark_id integer|nil

--- @class WatchRenderRequest
--- @field request_id string
--- @field bufnr integer
--- @field project_scope_id string
--- @field render_epoch integer
--- @field buffer_version integer
--- @field layout_version integer
--- @field jobs RenderJob[]

--- @class CurrentWatchRequest
--- @field request_id string
--- @field render_epoch integer
--- @field buffer_version integer
--- @field layout_version integer
--- @field project_scope_id string
--- @field jobs RenderJob[]
--- @field page_to_overlay table<integer, string>
--- @field overlay_to_page table<string, integer>
--- @field page_count integer
--- @field status WatchRequestStatus

--- @return MachineState
function M.initial_state()
  return {
    buffers = {},
    projects = {},
    overlays = {},
    counters = {
      next_node_id = 1,
      next_overlay_id = 1,
      next_request_id = 1,
    },
  }
end

return M
