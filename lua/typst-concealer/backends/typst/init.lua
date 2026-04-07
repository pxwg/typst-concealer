--- Typst backend for typst-concealer.
--- Implements the backend interface by delegating to submodules.

local M = {}

local session = require("typst-concealer.backends.typst.session")
local semantics = require("typst-concealer.backends.typst.semantics")
local units = require("typst-concealer.backends.typst.units")
local preview = require("typst-concealer.backends.typst.preview")

--- No-op setup; reserved for future per-backend configuration.
function M.setup(_config) end

-- AST traversal
M.collect_units = units.collect_units
M.can_incrementally_merge_units = units.can_incrementally_merge_units
M.merge_units_in_rows = units.merge_units_in_rows

-- Classification
M.classify = semantics.classify

-- Compiler dispatch
M.render_items = session.render_items_via_watch
M.render_preview_tail = session.render_preview_tail
M.clear_preview_tail = session.clear_preview_tail

-- Session lifecycle
M.ensure_session = session.ensure_watch_session
M.stop_session = session.stop_watch_session
M.stop_sessions_for_buf = session.stop_watch_sessions_for_buf
M.has_session = session.has_watch_session

-- Live preview helpers
M.get_math_symbol_span_at_pos = preview.get_math_symbol_span_at_pos
M.make_highlighted_preview = preview.make_highlighted_preview

-- Backend-owned state cleanup
M.reset_buf_state = units.reset_buf_state

return M
