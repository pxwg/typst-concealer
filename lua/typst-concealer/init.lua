--- typst-concealer public API
--- This file is intentionally thin: setup, enable/disable, and autocmd wiring.
--- All rendering logic lives in the sub-modules (semantics, wrapper, extmark, session, render).

--- @class typstconcealer
local M = {}

--- @type { [integer]: boolean }
M._enabled_buffers = {}

-- ── Terminal cell-size detection (FFI) ────────────────────────────────────────

local ffi = require("ffi")
ffi.cdef([[
  typedef struct { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; } winsize_t;
  int ioctl(int fd, unsigned long request, ...);
]])
local TIOCGWINSZ = vim.fn.has("mac") == 1 and 0x40087468 or 0x5413

--- Refresh the terminal cell pixel dimensions stored in state.
--- Called at setup time and on VimResized.
local function refresh_cell_px_size()
  local state = require("typst-concealer.state")
  local ws = ffi.new("winsize_t")
  if ffi.C.ioctl(1, TIOCGWINSZ, ws) == 0 and ws.ws_xpixel > 0 and ws.ws_col > 0 then
    state._cell_px_w = ws.ws_xpixel / ws.ws_col
    state._cell_px_h = ws.ws_ypixel / ws.ws_row
    local baseline_pt = (M.config and M.config.math_baseline_pt) or 10
    state._render_ppi = math.max(72, math.floor(state._cell_px_h * 72 / baseline_pt))
  end
end

-- ── Typst prelude / styling ────────────────────────────────────────────────────

--- Rebuild M._styling_prelude from the current colour scheme / styling config.
local function setup_prelude()
  if M.config.styling_type == "colorscheme" then
    local color = M.config.color
    if color == nil then
      color = string.format('rgb("#%06X")', vim.api.nvim_get_hl(0, { name = "Normal" })["fg"])
    end
    -- FIXME: lists everything. agony. hope https://github.com/typst/typst/issues/3356 is resolved.
    M._styling_prelude = ""
      .. "#set page(width: auto, height: auto, margin: (x: 0pt, y: 0pt), fill: none)\n"
      .. "#set text("
      .. color
      .. ', top-edge: "ascender", bottom-edge: "descender")\n'
      .. "#set line(stroke: "
      .. color
      .. ")\n"
      .. "#set table(stroke: "
      .. color
      .. ")\n"
      .. "#set circle(stroke: "
      .. color
      .. ")\n"
      .. "#set ellipse(stroke: "
      .. color
      .. ")\n"
      .. "#set line(stroke: "
      .. color
      .. ")\n"
      .. "#set curve(stroke: "
      .. color
      .. ")\n"
      .. "#set polygon(stroke: "
      .. color
      .. ")\n"
      .. "#set rect(stroke: "
      .. color
      .. ")\n"
      .. "#set square(stroke: "
      .. color
      .. ")\n"
  elseif M.config.styling_type == "simple" then
    M._styling_prelude = ""
      .. "#set page(width: auto, height: auto, margin: 0.75pt)\n"
      .. '#set text(top-edge: "ascender", bottom-edge: "descender")\n'
  elseif M.config.styling_type == "none" then
    M._styling_prelude = ""
  end
end

-- ── Public API ─────────────────────────────────────────────────────────────────

--- @class typstconfig
--- @field typst_location?        string    Path to typst binary. Defaults to "typst" (PATH).
--- @field do_diagnostics?        boolean   Provide diagnostics on compile error.
--- @field color?                 string    Render colour (only when styling_type = "colorscheme").
--- @field enabled_by_default?    boolean   Conceal newly opened buffers by default.
--- @field styling_type?          "none"|"simple"|"colorscheme"  Styling strategy.
--- @field ppi?                   integer   Fallback PPI when terminal pixel size is unavailable.
--- @field math_baseline_pt?      number    Expected math line height in pt for 1 terminal row. Default 11.
--- @field conceal_in_normal      boolean   Keep concealing when the cursor is on a line in normal mode.
--- @field compiler_args?         string[]  Extra typst CLI arguments.
--- @field header?                string    Custom Typst code prepended to every rendered document.
--- @field block_padding_cols?    integer   Terminal columns reserved as outer padding for code blocks.
--- @field block_preview_margin_pt? number  Extra Typst-side inner margin for code block previews.
--- @field live_preview_enabled?  boolean   Enable inline live preview around the active math node. Default true.
--- @field live_preview_debounce? number    Debounce delay for live preview in ms. Default 100.
--- @field cursor_hover_throttle_ms? number  Throttle delay for CursorMoved hover in ms. Default 0 (disabled).
--- @field render_paths?          { include?: (string|fun(path: string, bufnr: integer): boolean)[], exclude?: (string|fun(path: string, bufnr: integer): boolean)[] }
---                                     Optional path rules. `include` acts as a whitelist when non-empty; `exclude` always wins.
--- @field get_root?              fun(bufnr: integer, path: string, cwd: string, kind: "full"|"preview"): string|nil
---                                     Return the source/project root used to interpret rooted Typst paths like `/fig/a.png`.
---                                     Must be an absolute filesystem path. `nil` falls back to detected project root.
--- @field get_inputs?            fun(bufnr: integer, path: string, cwd: string, kind: "full"|"preview"): string[]|nil
---                                     Return extra `--input` values, e.g. `{"focus=123", "preview=true"}`. `nil`/`{}` appends nothing.
--- @field get_preamble_file?     fun(bufnr: integer, path: string, cwd: string, kind: "full"|"preview"): string|nil
---                                     Return an absolute path to a `.typ` file that is `#include`d at the top of every
---                                     batch document for this buffer. Use this to inject project-level context
---                                     (bibliography, imports, show rules) so that snippets compile under the correct
---                                     project scope. The file must be within `--root`. `nil` skips injection.

local function default(val, default_val)
  if val == nil then
    return default_val
  end
  return val
end

local augroup = vim.api.nvim_create_augroup("typst-concealer", { clear = true })

local function normalize_path(path)
  if path == nil or path == "" then
    return ""
  end
  return vim.fs.normalize(path)
end

local function matches_path_rule(rule, path, bufnr)
  if type(rule) == "string" then
    return path:match(rule) ~= nil
  end
  if type(rule) == "function" then
    local ok, matched = pcall(rule, path, bufnr)
    return ok and matched == true
  end
  return false
end

local function matches_any_path_rule(rules, path, bufnr)
  for _, rule in ipairs(rules or {}) do
    if matches_path_rule(rule, path, bufnr) then
      return true
    end
  end
  return false
end

function M.is_render_allowed(bufnr)
  bufnr = bufnr or vim.fn.bufnr()
  local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local render_paths = (M.config and M.config.render_paths) or {}
  local includes = render_paths.include or {}
  local excludes = render_paths.exclude or {}

  if #includes > 0 and not matches_any_path_rule(includes, path, bufnr) then
    return false
  end

  if matches_any_path_rule(excludes, path, bufnr) then
    return false
  end

  return true
end

M.enable_buf = function(bufnr)
  bufnr = bufnr or vim.fn.bufnr()
  if not M.is_render_allowed(bufnr) then
    M._enabled_buffers[bufnr] = nil
    require("typst-concealer.render").hard_reset_buf(bufnr)
    return
  end
  M._enabled_buffers[bufnr] = true
  require("typst-concealer.render").render_buf(bufnr)
end

M.disable_buf = function(bufnr)
  bufnr = bufnr or vim.fn.bufnr()
  M._enabled_buffers[bufnr] = nil
  require("typst-concealer.state").clear_hover_timer(bufnr)
  local session = require("typst-concealer.session")
  session.stop_watch_session(bufnr, "full")
  local render = require("typst-concealer.render")
  render.clear_live_typst_preview(bufnr)
  render.hard_reset_buf(bufnr)
end

M.toggle_buf = function(bufnr)
  bufnr = bufnr or vim.fn.bufnr()
  if M._enabled_buffers[bufnr] ~= nil then
    M.disable_buf(bufnr)
  else
    M.enable_buf(bufnr)
  end
end

M.rerender_buf = function(bufnr)
  bufnr = bufnr or vim.fn.bufnr()
  require("typst-concealer.render").render_buf(bufnr)
end

-- ── Setup ─────────────────────────────────────────────────────────────────────

function M.setup(cfg)
  local version = vim.version()
  if version.major == 0 and version.minor < 10 then
    error("Typst concealer requires at least nvim 10.0 to work")
  end

  if M._setup_ran ~= nil then
    error("typst-concealer's setup function may only be run once")
  end
  M._setup_ran = true

  M.config = {
    typst_location = default(cfg.typst_location, "typst"),
    do_diagnostics = default(cfg.do_diagnostics, true),
    enabled_by_default = default(cfg.enabled_by_default, true),
    styling_type = default(cfg.styling_type, "colorscheme"),
    ppi = default(cfg.ppi, 300),
    math_baseline_pt = default(cfg.math_baseline_pt, 11),
    color = cfg.color,
    conceal_in_normal = default(cfg.conceal_in_normal, false),
    compiler_args = default(cfg.compiler_args, {}),
    header = default(cfg.header, ""),
    block_padding_cols = default(cfg.block_padding_cols, 15),
    block_preview_margin_pt = default(cfg.block_preview_margin_pt, 6),
    live_preview_enabled = default(cfg.live_preview_enabled, true),
    live_preview_debounce = default(cfg.live_preview_debounce, 100),
    cursor_hover_throttle_ms = default(cfg.cursor_hover_throttle_ms, 0),
    render_paths = default(cfg.render_paths, {}),
    get_root = cfg.get_root,
    get_inputs = cfg.get_inputs,
    get_preamble_file = cfg.get_preamble_file,
  }

  if not vim.list_contains({ "none", "simple", "colorscheme" }, M.config.styling_type) then
    error(
      "typst styling_type "
        .. M.config.styling_type
        .. " is not a valid option. Please use 'none', 'simple' or 'colorscheme'"
    )
  end

  if M.config.get_root ~= nil and type(M.config.get_root) ~= "function" then
    error("typst get_root must be a function when provided")
  end

  setup_prelude()
  refresh_cell_px_size()

  if not cfg.allow_missing_typst and vim.fn.executable(M.config.typst_location) ~= 1 then
    if M.config.typst_location == "typst" then
      error("Typst executable not found in path, typst-concealer will not work")
    else
      error("Typst executable not found at '" .. M.config.typst_location .. "', typst-concealer will not work")
    end
  end

  local typst_parser_installed = pcall(vim.treesitter.get_parser, 0, "typst")
  if typst_parser_installed == false then
    error("Typst treesitter parser not found, typst-concealer will not work")
  end

  M._typst_query = vim.treesitter.query.parse(
    "typst",
    [[
[
 (code
  [(_) (call item: (ident) @call_ident)] @code
 )
 (math)
] @block
]]
  )

  -- ── Per-buffer initialisation ──────────────────────────────────────────────

  local function init_buf(bufnr)
    vim.opt_local.conceallevel = 2
    vim.opt_local.concealcursor = "nci"
    if M.config.enabled_by_default and M.is_render_allowed(bufnr) then
      M._enabled_buffers[bufnr] = true
    else
      M._enabled_buffers[bufnr] = nil
    end
  end

  if vim.v.vim_did_enter then
    local bufnr = vim.fn.bufnr()
    if vim.api.nvim_buf_get_name(bufnr):match(".*%.typ$") then
      init_buf(bufnr)
    end
  end

  -- ── Autocmds ──────────────────────────────────────────────────────────────

  vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = "*.typ",
    group = augroup,
    desc = "render file on enter",
    callback = function(ev)
      vim.schedule(function()
        require("typst-concealer.render").render_buf(ev.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufNew", "VimEnter" }, {
    pattern = "*.typ",
    group = augroup,
    desc = "enable file on creation if the option is set",
    callback = function(ev)
      init_buf(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = "*.typ",
    group = augroup,
    desc = "render file on write",
    callback = function(ev)
      vim.schedule(function()
        require("typst-concealer.render").render_buf(ev.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("TextChanged", {
    pattern = "*.typ",
    group = augroup,
    desc = "re-render on normal-mode text changes so block anchors stay correct",
    callback = function(ev)
      vim.schedule(function()
        local render = require("typst-concealer.render")
        render.render_buf(ev.buf)
        render.render_live_typst_preview(ev.buf)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    pattern = "*.typ",
    group = augroup,
    desc = "unconceal on line hover",
    callback = function(ev)
      require("typst-concealer.render").render_live_typst_preview(ev.buf)

      local throttle = require("typst-concealer").config.cursor_hover_throttle_ms
      if throttle <= 0 then
        -- No throttle: call directly (row-level guard is inside the function)
        require("typst-concealer.render").hide_extmarks_at_cursor(ev.buf)
        return
      end
      -- Per-buffer trailing throttle: always process latest cursor position
      local bs = require("typst-concealer.state").get_buf_state(ev.buf)
      if bs.hover.throttle_timer == nil then
        bs.hover.throttle_timer = vim.uv.new_timer()
      end
      bs.hover.throttle_timer:stop()
      bs.hover.throttle_timer:start(
        throttle,
        0,
        vim.schedule_wrap(function()
          require("typst-concealer.render").hide_extmarks_at_cursor(ev.buf)
        end)
      )
    end,
  })

  vim.api.nvim_create_autocmd({ "ModeChanged" }, {
    group = augroup,
    pattern = "v:*",
    desc = "unconceal when exiting visual mode (no CursorMoved event fires)",
    callback = function(ev)
      if vim.api.nvim_buf_get_name(ev.buf):match(".*%.typ$") then
        require("typst-concealer.render").hide_extmarks_at_cursor(ev.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = augroup,
    pattern = "*.typ",
    desc = "keep float preview synced while moving in insert mode",
    callback = function(ev)
      require("typst-concealer.render").render_live_typst_preview(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    pattern = "*.typ",
    desc = "sync float preview when entering a typst buffer",
    callback = function(ev)
      require("typst-concealer.render").render_live_typst_preview(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("TextChangedI", {
    pattern = "*.typ",
    group = augroup,
    desc = "render live preview float when insert-mode text changes",
    callback = function(ev)
      vim.schedule(function()
        local render = require("typst-concealer.render")
        render.render_buf(ev.buf)
        render.render_live_typst_preview(ev.buf)
      end)
    end,
  })

  if cfg.color == nil then
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = augroup,
      desc = "update colour scheme",
      callback = function()
        setup_prelude()
        local render = require("typst-concealer.render")
        for bufnr in pairs(M._enabled_buffers) do
          render.render_buf(bufnr)
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "typst",
    callback = function(ev)
      init_buf(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    desc = "refresh cell pixel size on terminal resize",
    callback = function(ev)
      refresh_cell_px_size()
      local render = require("typst-concealer.render")
      render.render_buf(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "BufWinLeave", "BufHidden", "BufDelete" }, {
    pattern = "*.typ",
    group = augroup,
    desc = "clear live preview when leaving a typst buffer",
    callback = function(ev)
      require("typst-concealer.render").clear_live_typst_preview(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = augroup,
    pattern = "*.typ",
    desc = "stop typst watch sessions for dead buffers",
    callback = function(ev)
      local session = require("typst-concealer.session")
      session.stop_watch_sessions_for_buf(ev.buf)
      require("typst-concealer.render").hard_reset_buf(ev.buf)
    end,
  })
end

return M
