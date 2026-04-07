--- LaTeX backend for typst-concealer.
--- Implements the backend interface by delegating to submodules.
---
--- Diagnostics contract: same as Typst backend.
--- Errors are accumulated via update_diagnostics_from_log() in session.lua,
--- then state.hooks.on_diagnostics_changed(bufnr, items) is fired.
--- The frontend (init.lua) owns quickfix display.

local state = require("typst-concealer.state")
local M = {}

local session = require("typst-concealer.backends.latex.session")
local semantics = require("typst-concealer.backends.latex.semantics")
local units = require("typst-concealer.backends.latex.units")
local preview = require("typst-concealer.backends.latex.preview")

-- ── Styling prelude ────────────────────────────────────────────────────────────
-- For LaTeX, the styling prelude consists of colour/font commands injected into
-- the document preamble via the build_preamble helper in wrapper.lua.
-- Currently only "colorscheme" (set text colour from Normal fg) is supported.

local _config = {}
M._styling_prelude = ""

--- Rebuild the styling prelude from the current config and colorscheme.
function M.refresh_styling_prelude()
  local color = _config.color
  if _config.styling_type == "colorscheme" then
    if color == nil then
      local fg = vim.api.nvim_get_hl(0, { name = "Normal" })["fg"]
      if fg then
        color = string.format("#%06X", fg)
      end
    end
    if color then
      M._styling_prelude = "\\definecolor{tcfg}{HTML}{" .. color:gsub("^#", "") .. "}\\color{tcfg}"
    else
      M._styling_prelude = ""
    end
  elseif _config.styling_type == "none" then
    M._styling_prelude = ""
  else
    M._styling_prelude = ""
  end
end

--- Return the current styling prelude string.
--- @return string
function M.get_styling_prelude()
  return M._styling_prelude
end

--- Store config, validate prerequisites, and rebuild the styling prelude.
--- @param config table
function M.setup(config)
  _config = config or {}
  local latex_parser_ok = pcall(vim.treesitter.get_parser, 0, "latex")
  if not latex_parser_ok then
    error("LaTeX treesitter parser not found. Install nvim-treesitter and run :TSInstall latex")
  end
  M.refresh_styling_prelude()
end

-- ── AST traversal ──────────────────────────────────────────────────────────────
M.collect_units = units.collect_units
M.can_incrementally_merge_units = units.can_incrementally_merge_units
M.merge_units_in_rows = units.merge_units_in_rows

-- ── Classification ─────────────────────────────────────────────────────────────
M.classify = semantics.classify

-- ── Compiler dispatch ──────────────────────────────────────────────────────────
M.render_items = session.render_items_via_compile
M.render_preview_tail = session.render_preview_tail
M.clear_preview_tail = session.clear_preview_tail

-- ── Session lifecycle ──────────────────────────────────────────────────────────
M.ensure_session = session.ensure_watch_session
M.stop_session = session.stop_watch_session
M.stop_sessions_for_buf = session.stop_watch_sessions_for_buf
M.has_session = session.has_watch_session

-- ── Live preview helpers ───────────────────────────────────────────────────────
M.make_highlighted_preview = preview.make_highlighted_preview

-- ── Backend-owned state cleanup ────────────────────────────────────────────────
M.reset_buf_state = units.reset_buf_state

--- Return the current flat list of diagnostic items for bufnr.
--- @param bufnr integer
--- @return table[]
function M.get_diagnostics(bufnr)
  local bucket = state.watch_diagnostics[bufnr] or {}
  local items = {}
  for _, item in ipairs(bucket["full"] or {}) do
    items[#items + 1] = item
  end
  return items
end

return M
