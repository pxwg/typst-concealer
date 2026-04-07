--- LaTeX compile session for typst-concealer.
--- Each buffer gets one compile session that runs pdflatex → pdftoppm on demand.
--- Pages are dispatched to apply.accept_page_update immediately after pdftoppm exits.
---
--- LaTeXBackend interface:
---   M.render_items_via_compile(bufnr, items)    trigger a full compile cycle
---   M.render_preview_tail(bufnr, item)          compile a single preview item
---   M.clear_preview_tail(bufnr)                 cancel any running preview compile
---   M.ensure_watch_session(bufnr)               create/reuse session (noop if alive)
---   M.stop_watch_session(bufnr, kind)           kill processes and clean up
---   M.stop_watch_sessions_for_buf(bufnr)        stop the buffer session
---   M.has_watch_session(bufnr, kind)            check session is alive

local state = require("typst-concealer.state")
local M = {}

-- ── Diagnostics ────────────────────────────────────────────────────────────────

local function rebuild_quickfix(bufnr)
  local bucket = state.watch_diagnostics[bufnr] or {}
  local items = {}
  for _, item in ipairs(bucket["full"] or {}) do
    items[#items + 1] = item
  end
  if state.hooks.on_diagnostics_changed then
    state.hooks.on_diagnostics_changed(bufnr, items)
  end
end

-- ── File utilities ─────────────────────────────────────────────────────────────

--- @param path string
local function safe_unlink(path)
  if vim.uv.fs_stat(path) ~= nil then
    vim.uv.fs_unlink(path)
  end
end

--- @param path string
--- @param text string
--- @return boolean, string?
local function write_file_in_place(path, text)
  local dir = vim.fn.fnamemodify(path, ":h")
  local base = vim.fn.fnamemodify(path, ":t")
  local tmp_path = string.format("%s/.%s.tmp-%d", dir, base, vim.uv.hrtime())
  local fd, open_err = vim.uv.fs_open(tmp_path, "w", tonumber("644", 8))
  if not fd then
    return false, open_err
  end
  local _, write_err = vim.uv.fs_write(fd, text, 0)
  vim.uv.fs_close(fd)
  if write_err ~= nil then
    safe_unlink(tmp_path)
    return false, write_err
  end
  local ok, rename_err = vim.uv.fs_rename(tmp_path, path)
  if not ok then
    safe_unlink(tmp_path)
    return false, rename_err
  end
  return true
end

--- @param bufnr integer
--- @return string
local function get_buf_dir(bufnr)
  local buf_file = vim.api.nvim_buf_get_name(bufnr)
  if buf_file == nil or buf_file == "" then
    return vim.uv.cwd()
  end
  return vim.fn.fnamemodify(buf_file, ":h")
end

--- @param bufnr integer
--- @return string
local function get_cache_dir(bufnr)
  local buf_file = vim.api.nvim_buf_get_name(bufnr)
  local safe_name
  if buf_file == nil or buf_file == "" then
    safe_name = "unnamed"
  else
    safe_name = vim.fn.fnamemodify(buf_file, ":t:r"):gsub("[^%w%-]", "_")
    if #safe_name > 40 then
      safe_name = safe_name:sub(1, 40)
    end
  end
  local hash_input = (buf_file ~= nil and buf_file ~= "") and buf_file or tostring(bufnr)
  local h = 0
  for i = 1, #hash_input do
    h = (h * 31 + hash_input:byte(i)) % 0xFFFF
  end
  local dir = vim.fn.stdpath("cache") .. "/typst-concealer/" .. safe_name .. "-" .. string.format("%04x", h)
  vim.fn.mkdir(dir, "p")
  return dir
end

-- ── Path helpers ───────────────────────────────────────────────────────────────

--- @param bufnr integer
--- @return string  path to the .tex batch input file
local function session_input_path(bufnr)
  return get_cache_dir(bufnr) .. "/latex-concealer-" .. state.full_pid .. "-" .. bufnr .. ".tex"
end

--- @param bufnr integer
--- @return string  path to the compiled .pdf
local function session_pdf_path(bufnr)
  return get_cache_dir(bufnr) .. "/latex-concealer-" .. state.full_pid .. "-" .. bufnr .. ".pdf"
end

--- @param bufnr integer
--- @return string  prefix passed to pdftoppm for full render PNGs
local function session_output_prefix(bufnr)
  return "/tmp/tty-graphics-protocol-latex-concealer-" .. state.full_pid .. "-" .. bufnr
end

--- @param bufnr integer
--- @return string  path to the preview .tex input file
local function preview_input_path(bufnr)
  return get_cache_dir(bufnr) .. "/latex-concealer-preview-" .. state.full_pid .. "-" .. bufnr .. ".tex"
end

--- @param bufnr integer
--- @return string  path to the preview compiled .pdf
local function preview_pdf_path(bufnr)
  return get_cache_dir(bufnr) .. "/latex-concealer-preview-" .. state.full_pid .. "-" .. bufnr .. ".pdf"
end

--- @param bufnr integer
--- @return string  pdftoppm prefix for preview PNGs
local function preview_output_prefix(bufnr)
  return "/tmp/tty-graphics-protocol-latex-concealer-preview-" .. state.full_pid .. "-" .. bufnr
end

-- ── Session lookup ─────────────────────────────────────────────────────────────

--- @param bufnr integer
--- @param kind string
--- @return table|nil
local function get_session(bufnr, kind)
  local bucket = state.watch_sessions[bufnr]
  return bucket and bucket[kind] or nil
end

--- @param bufnr integer
--- @param kind string
--- @return boolean
function M.has_watch_session(bufnr, kind)
  return get_session(bufnr, kind) ~= nil
end

-- ── on_page_rendered ───────────────────────────────────────────────────────────

--- Called when a PNG is ready.  Reads dimensions and calls accept_page_update.
--- @param bufnr          integer
--- @param page_path      string
--- @param image_id       integer
--- @param extmark_id     integer
--- @param original_range table
--- @param page_stamp     string
local function on_page_rendered(bufnr, page_path, image_id, extmark_id, original_range, page_stamp)
  local pngData = require("typst-concealer.png-lua")
  local kitty_codes = require("typst-concealer.kitty-codes")

  local item = state.get_item_by_image_id(image_id)
  if item == nil or type(extmark_id) ~= "number" then
    return
  end

  local target_range = original_range
  if item and item.render_target == "float" then
    target_range = item.target_range or original_range
  end

  local source_rows = target_range[3] - target_range[1] + 1
  local success, data = pcall(pngData, page_path)
  if not success then
    return
  end

  local natural_rows, natural_cols
  if state._cell_px_w and state._cell_px_h then
    natural_rows = math.max(1, math.floor(data.height / state._cell_px_h + 0.5))
    natural_cols = math.max(1, math.floor(data.width / state._cell_px_w + 0.5))
  else
    natural_rows = source_rows
    natural_cols = math.ceil((data.width / data.height) * 2) * source_rows
  end

  if
    source_rows == 1
    and natural_rows > 1
    and not (item and item.semantics and item.semantics.display_kind == "block")
  then
    if state._cell_px_w and state._cell_px_h then
      local aspect = data.width / data.height
      natural_cols = math.max(1, math.floor(state._cell_px_h * aspect / state._cell_px_w + 0.5))
    else
      natural_cols = math.max(1, math.floor((data.width / data.height) * 2))
    end
    natural_rows = 1
  end

  if natural_cols >= #kitty_codes.diacritics then
    natural_cols = #kitty_codes.diacritics - 1
  end

  require("typst-concealer.apply").accept_page_update({
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    original_range = original_range,
    page_path = page_path,
    page_stamp = page_stamp,
    natural_cols = natural_cols,
    natural_rows = natural_rows,
    source_rows = source_rows,
  })
end

-- ── Diagnostics parser ─────────────────────────────────────────────────────────

--- Parse a pdflatex .log file for errors and warnings.
--- Maps line numbers back to source positions via line_map.
--- @param session table
--- @param log_text string
--- @return table[]
local function parse_latex_log(session, log_text)
  local items = {}
  local bufname = vim.api.nvim_buf_get_name(session.bufnr)

  -- pdflatex errors: "! Error message." followed by "l.N context"
  local current_msg = nil
  for line in (log_text .. "\n"):gmatch("(.-)\n") do
    local err = line:match("^!%s+(.+)$")
    if err then
      current_msg = err
    end
    if current_msg then
      local lnum = line:match("^l%.(%d+)%s")
      if lnum then
        local gen_lnum = tonumber(lnum) or 1
        local mapped = nil
        if session.line_map then
          for _, seg in ipairs(session.line_map) do
            if gen_lnum >= seg.gen_start and gen_lnum <= seg.gen_end then
              mapped = {
                filename = vim.api.nvim_buf_get_name(seg.bufnr),
                lnum = seg.src_start + (gen_lnum - seg.gen_start),
                col = 1,
              }
              break
            end
          end
        end
        items[#items + 1] = {
          filename = (mapped and mapped.filename) or bufname,
          lnum = (mapped and mapped.lnum) or 1,
          col = (mapped and mapped.col) or 1,
          text = "[full] " .. current_msg,
          type = "E",
        }
        current_msg = nil
      end
    end
  end

  return items
end

--- Read pdflatex log and update diagnostics.
--- @param session table
local function update_diagnostics_from_log(session)
  local main = require("typst-concealer")
  if not (main.config and main.config.do_diagnostics) then
    return
  end
  local log_path = session.log_path
  if log_path == nil then
    return
  end
  local fd = vim.uv.fs_open(log_path, "r", 0)
  if fd == nil then
    return
  end
  local stat = vim.uv.fs_fstat(fd)
  local size = stat and stat.size or 0
  local text = ""
  if size > 0 then
    local data, _ = vim.uv.fs_read(fd, size, 0)
    text = data or ""
  end
  vim.uv.fs_close(fd)

  local diag_items = parse_latex_log(session, text)
  state.watch_diagnostics[session.bufnr] = state.watch_diagnostics[session.bufnr] or {}
  state.watch_diagnostics[session.bufnr]["full"] = diag_items
  rebuild_quickfix(session.bufnr)
end

-- ── Compile pipeline ───────────────────────────────────────────────────────────

--- Kill a handle if it's still alive.
--- @param handle any
local function kill_handle(handle)
  if handle and not handle:is_closing() then
    pcall(function()
      handle:kill(15)
    end)
    handle:close()
  end
end

--- Forward declaration for mutual recursion.
local start_full_compile

--- Run pdftoppm on the session's PDF and dispatch on_page_rendered for each page.
--- @param session table
--- @param n_items integer  total number of items (= number of PDF pages)
local function start_full_convert(session, n_items)
  local main = require("typst-concealer")
  local config = main.config.backends and main.config.backends.latex or {}
  local converter = config.converter or "pdftoppm"
  local ppi = state._render_ppi or main.config.ppi or 150
  local pdf_path = session.pdf_path
  local prefix = session.output_prefix

  local stderr = vim.uv.new_pipe()
  local handle
  handle = vim.uv.spawn(converter, {
    stdio = { nil, nil, stderr },
    args = { "-r", tostring(ppi), "-png", pdf_path, prefix },
  }, function(code)
    session.convert_handle = nil
    kill_handle(stderr)
    kill_handle(handle)

    vim.schedule(function()
      if session.dead then
        return
      end

      -- Dispatch on_page_rendered for each page that now exists
      local wrapper = require("typst-concealer.backends.latex.wrapper")
      for i, item in ipairs(session.items or {}) do
        if item.image_id ~= nil and item.extmark_id ~= nil then
          local page_path = wrapper.page_path(prefix, i, n_items)
          local stat = vim.uv.fs_stat(page_path)
          if stat ~= nil and stat.size > 0 then
            local stamp = tostring(stat.mtime.sec) .. ":" .. tostring(stat.mtime.nsec) .. ":" .. tostring(stat.size)
            on_page_rendered(session.bufnr, page_path, item.image_id, item.extmark_id, item.range, stamp)
          end
        end
      end

      if code ~= 0 then
        vim.notify("[typst-concealer/latex] pdftoppm exited with code " .. tostring(code), vim.log.levels.WARN)
      end

      if session.compile_pending then
        session.compile_pending = false
        start_full_compile(session)
      end
    end)
  end)

  if stderr then
    stderr:read_start(function() end)
  end

  if handle == nil then
    vim.schedule(function()
      vim.notify("[typst-concealer/latex] failed to spawn pdftoppm", vim.log.levels.ERROR)
    end)
    return
  end

  session.convert_handle = handle
end

--- Run pdflatex on session.input_path, then start_full_convert on success.
--- @param session table
start_full_compile = function(session)
  local main = require("typst-concealer")
  local config = main.config.backends and main.config.backends.latex or {}
  local compiler = config.compiler or "pdflatex"

  local cache_dir = vim.fn.fnamemodify(session.input_path, ":h")
  local stderr = vim.uv.new_pipe()
  local n_items = #(session.items or {})

  local handle
  handle = vim.uv.spawn(compiler, {
    stdio = { nil, nil, stderr },
    args = {
      "-interaction=nonstopmode",
      "-output-directory=" .. cache_dir,
      session.input_path,
    },
    cwd = cache_dir,
  }, function(code)
    session.compile_handle = nil
    kill_handle(stderr)
    kill_handle(handle)

    vim.schedule(function()
      if session.dead then
        return
      end

      update_diagnostics_from_log(session)

      if code ~= 0 then
        -- Compile error: still try pdftoppm in case partial output exists,
        -- but mark compile_pending false so we don't loop.
        session.compile_pending = false
        return
      end

      if n_items > 0 then
        start_full_convert(session, n_items)
      else
        if session.compile_pending then
          session.compile_pending = false
          start_full_compile(session)
        end
      end
    end)
  end)

  if stderr then
    stderr:read_start(function() end)
  end

  if handle == nil then
    vim.schedule(function()
      vim.notify("[typst-concealer/latex] failed to spawn " .. compiler, vim.log.levels.ERROR)
    end)
    return
  end

  session.compile_handle = handle
end

--- Write items to session.input_path (if changed) then trigger a compile.
--- If already compiling, sets compile_pending to restart after finish.
--- @param session table
local function trigger_full_compile(session)
  local main = require("typst-concealer")
  local latex_backend = require("typst-concealer.backends.latex")
  local config = main.config.backends and main.config.backends.latex or {}
  local wrapper = require("typst-concealer.backends.latex.wrapper")
  local styling_prelude = latex_backend.get_styling_prelude()

  local doc_str, line_map = wrapper.build_batch_document(session.items or {}, config, styling_prelude)
  session.line_map = line_map

  if session.last_input_text == doc_str then
    return
  end

  local ok, err = write_file_in_place(session.input_path, doc_str)
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer/latex] failed to write input: " .. tostring(err), vim.log.levels.ERROR)
    end)
    return
  end
  session.last_input_text = doc_str

  if session.compile_handle ~= nil or session.convert_handle ~= nil then
    session.compile_pending = true
    return
  end

  start_full_compile(session)
end

-- ── Preview compile pipeline ───────────────────────────────────────────────────

--- Forward declaration for mutual recursion.
local start_preview_compile

--- Run pdftoppm for the preview PDF and dispatch on_page_rendered for page 1.
--- @param session table
--- @param preview_item table
local function start_preview_convert(session, preview_item)
  local main = require("typst-concealer")
  local config = main.config.backends and main.config.backends.latex or {}
  local converter = config.converter or "pdftoppm"
  local ppi = state._render_ppi or main.config.ppi or 150
  local prefix = session.preview_output_prefix

  local stderr = vim.uv.new_pipe()
  local handle
  handle = vim.uv.spawn(converter, {
    stdio = { nil, nil, stderr },
    args = { "-r", tostring(ppi), "-png", session.preview_pdf_path, prefix },
  }, function(code)
    session.preview_convert_handle = nil
    kill_handle(stderr)
    kill_handle(handle)

    vim.schedule(function()
      if session.dead then
        return
      end
      if code ~= 0 then
        return
      end

      -- Preview always produces a single page (one item)
      local wrapper = require("typst-concealer.backends.latex.wrapper")
      local page_path = wrapper.page_path(prefix, 1, 1)
      local stat = vim.uv.fs_stat(page_path)
      if stat ~= nil and stat.size > 0 and preview_item.image_id ~= nil and preview_item.extmark_id ~= nil then
        local stamp = tostring(stat.mtime.sec) .. ":" .. tostring(stat.mtime.nsec) .. ":" .. tostring(stat.size)
        on_page_rendered(
          session.bufnr,
          page_path,
          preview_item.image_id,
          preview_item.extmark_id,
          preview_item.range,
          stamp
        )
      end

      if session.preview_pending_item ~= nil then
        local pending = session.preview_pending_item
        session.preview_pending_item = nil
        start_preview_compile(session, pending)
      end
    end)
  end)

  if stderr then
    stderr:read_start(function() end)
  end

  if handle == nil then
    vim.schedule(function()
      vim.notify("[typst-concealer/latex] failed to spawn pdftoppm (preview)", vim.log.levels.ERROR)
    end)
  end

  session.preview_convert_handle = handle
end

--- Run pdflatex for the single-item preview document.
--- @param session table
--- @param preview_item table
start_preview_compile = function(session, preview_item)
  local main = require("typst-concealer")
  local latex_backend = require("typst-concealer.backends.latex")
  local config = main.config.backends and main.config.backends.latex or {}
  local compiler = config.compiler or "pdflatex"
  local styling_prelude = latex_backend.get_styling_prelude()
  local wrapper = require("typst-concealer.backends.latex.wrapper")

  local doc_str, _ = wrapper.build_batch_document({ preview_item }, config, styling_prelude)
  local ok, err = write_file_in_place(session.preview_input_path, doc_str)
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer/latex] failed to write preview input: " .. tostring(err), vim.log.levels.ERROR)
    end)
    return
  end

  local cache_dir = vim.fn.fnamemodify(session.preview_input_path, ":h")
  local stderr = vim.uv.new_pipe()
  local handle
  handle = vim.uv.spawn(compiler, {
    stdio = { nil, nil, stderr },
    args = {
      "-interaction=nonstopmode",
      "-output-directory=" .. cache_dir,
      session.preview_input_path,
    },
    cwd = cache_dir,
  }, function(code)
    session.preview_compile_handle = nil
    kill_handle(stderr)
    kill_handle(handle)

    vim.schedule(function()
      if session.dead then
        return
      end
      if code ~= 0 then
        if session.preview_pending_item ~= nil then
          local pending = session.preview_pending_item
          session.preview_pending_item = nil
          start_preview_compile(session, pending)
        end
        return
      end
      start_preview_convert(session, preview_item)
    end)
  end)

  if stderr then
    stderr:read_start(function() end)
  end

  if handle == nil then
    vim.schedule(function()
      vim.notify("[typst-concealer/latex] failed to spawn " .. compiler .. " (preview)", vim.log.levels.ERROR)
    end)
  end

  session.preview_compile_handle = handle
end

-- ── Public API ─────────────────────────────────────────────────────────────────

--- Create or reuse the compile session for bufnr.
--- @param bufnr integer
--- @return table|nil
function M.ensure_watch_session(bufnr)
  local existing = get_session(bufnr, "full")
  if existing ~= nil then
    return existing
  end

  local buf_dir = get_buf_dir(bufnr)
  local input_path = session_input_path(bufnr)
  local pdf_path = session_pdf_path(bufnr)
  local cache_dir = vim.fn.fnamemodify(input_path, ":h")
  -- Derive log path: pdflatex places it alongside the .tex with .log extension
  local log_path = cache_dir .. "/" .. vim.fn.fnamemodify(input_path, ":t:r") .. ".log"

  local session = {
    kind = "full",
    bufnr = bufnr,
    input_path = input_path,
    pdf_path = pdf_path,
    log_path = log_path,
    output_prefix = session_output_prefix(bufnr),
    preview_input_path = preview_input_path(bufnr),
    preview_pdf_path = preview_pdf_path(bufnr),
    preview_output_prefix = preview_output_prefix(bufnr),
    items = {},
    base_items = {},
    page_state = {},
    last_page_count = 0,
    last_input_text = nil,
    line_map = nil,
    dead = false,
    buf_dir = buf_dir,
    compile_handle = nil,
    convert_handle = nil,
    compile_pending = false,
    preview_compile_handle = nil,
    preview_convert_handle = nil,
    preview_pending_item = nil,
  }

  state.watch_sessions[bufnr] = state.watch_sessions[bufnr] or {}
  state.watch_sessions[bufnr]["full"] = session
  return session
end

--- Stop a compile session and clean up its files.
--- @param bufnr integer
--- @param kind  'full'
function M.stop_watch_session(bufnr, kind)
  local bucket = state.watch_sessions[bufnr]
  if bucket == nil or bucket[kind] == nil then
    return
  end
  local session = bucket[kind]
  session.dead = true

  kill_handle(session.compile_handle)
  kill_handle(session.convert_handle)
  kill_handle(session.preview_compile_handle)
  kill_handle(session.preview_convert_handle)
  session.compile_handle = nil
  session.convert_handle = nil
  session.preview_compile_handle = nil
  session.preview_convert_handle = nil

  safe_unlink(session.input_path)
  safe_unlink(session.pdf_path)
  safe_unlink(session.preview_input_path)
  safe_unlink(session.preview_pdf_path)

  local wrapper = require("typst-concealer.backends.latex.wrapper")
  local n = session.last_page_count or 0
  for i = 1, n do
    safe_unlink(wrapper.page_path(session.output_prefix, i, n))
  end
  -- Also clean up preview PNG (always 1 page)
  safe_unlink(wrapper.page_path(session.preview_output_prefix, 1, 1))

  bucket[kind] = nil
  if next(bucket) == nil then
    state.watch_sessions[bufnr] = nil
  end
end

--- @param bufnr integer
function M.stop_watch_sessions_for_buf(bufnr)
  M.stop_watch_session(bufnr, "full")
end

--- Dispatch a batch of items to the compile session.
--- @param bufnr integer
--- @param items table[]
function M.render_items_via_compile(bufnr, items)
  local session = M.ensure_watch_session(bufnr)
  if session == nil then
    return
  end

  session.base_items = items or {}
  session.items = session.base_items
  session.last_page_count = #session.items

  trigger_full_compile(session)
end

--- Compile a single preview item and dispatch on_page_rendered when ready.
--- @param bufnr integer
--- @param item table
function M.render_preview_tail(bufnr, item)
  local session = get_session(bufnr, "full")
  if session == nil or session.dead then
    return
  end

  if session.preview_compile_handle ~= nil or session.preview_convert_handle ~= nil then
    session.preview_pending_item = item
    return
  end

  start_preview_compile(session, item)
end

--- Cancel any running preview compilation.
--- @param bufnr integer
function M.clear_preview_tail(bufnr)
  local session = get_session(bufnr, "full")
  if session == nil then
    return
  end

  kill_handle(session.preview_compile_handle)
  kill_handle(session.preview_convert_handle)
  session.preview_compile_handle = nil
  session.preview_convert_handle = nil
  session.preview_pending_item = nil
end

return M
