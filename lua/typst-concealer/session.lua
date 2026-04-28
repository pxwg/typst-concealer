--- Render backend session management for typst-concealer.
--- Manages legacy `typst watch` sessions and Rust compiler-service processes.
--- Watch pages still use file polling; service pages use explicit JSON-lines
--- request/response boundaries. Machine-owned full pages are emitted as
--- overlay_page_ready events.
---
--- TypstBackend interface
---   M.render_items_via_watch(bufnr, items)          dispatch full items to the watch session
---   M.render_request_via_service(bufnr, request)    dispatch full overlay request to Rust service
---   M.render_preview_tail(bufnr, item)              update the preview tail page
---   M.clear_preview_tail(bufnr)                     disable the preview tail page
---   M.ensure_watch_session(bufnr)                   start/reuse the full watch session
---   M.ensure_compiler_service(bufnr)                start/reuse the Rust compiler service
---   M.stop_watch_session(bufnr, kind)               kill and clean up a session
---   M.stop_compiler_service(bufnr)                  kill and clean up compiler service
---   M.stop_watch_sessions_for_buf(bufnr)            kill the buffer session

local state = require("typst-concealer.state")
local M = {}

--- Generate quickfix title for all render diagnostics belonging to a buffer.
--- @param bufnr integer
--- @return string
local function qf_title(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == nil or name == "" then
    name = ("buf:%d"):format(bufnr)
  end
  return ("typst-concealer: %s"):format(name)
end

--- Rebuild the global quickfix list for a buffer from active render diagnostics.
--- @param bufnr integer
local function rebuild_quickfix(bufnr)
  local bucket = state.watch_diagnostics[bufnr] or {}
  local items = {}
  for _, kind in ipairs({ "full" }) do
    for _, item in ipairs(bucket[kind] or {}) do
      items[#items + 1] = item
    end
  end
  vim.schedule(function()
    vim.fn.setqflist({}, "r", {
      title = qf_title(bufnr),
      items = items,
    })
  end)
end

--- Clear quickfix diagnostics for one session kind and rebuild the aggregated
--- buffer quickfix list.
--- @param bufnr integer
--- @param kind  'full'
local function clear_quickfix(bufnr, kind)
  state.watch_diagnostics[bufnr] = state.watch_diagnostics[bufnr] or {}
  state.watch_diagnostics[bufnr][kind] = {}
  rebuild_quickfix(bufnr)
end

--- @param line_map table[]|nil
--- @param gen_lnum integer
--- @param gen_col integer
--- @return table|nil
local function map_generated_pos(line_map, gen_lnum, gen_col)
  if not line_map or #line_map == 0 then
    return nil
  end

  local function clamp(x, lo, hi)
    return math.max(lo, math.min(hi, x))
  end

  local function map_col(seg)
    local line_offset = gen_lnum - seg.gen_start
    local src_lnum = seg.src_start + line_offset

    if seg.src_start == seg.src_end and seg.gen_start == seg.gen_end then
      local delta = math.max(0, gen_col - seg.gen_start_col)
      local hi = math.max(seg.src_start_col, seg.src_end_col - 1)
      return src_lnum, clamp(seg.src_start_col + delta, seg.src_start_col, hi)
    end

    if gen_lnum == seg.gen_start then
      local delta = math.max(0, gen_col - seg.gen_start_col)
      return src_lnum, math.max(seg.src_start_col, seg.src_start_col + delta)
    end

    if gen_lnum == seg.gen_end then
      local hi = math.max(1, seg.src_end_col - 1)
      return src_lnum, clamp(gen_col, 1, hi)
    end

    return src_lnum, math.max(1, gen_col)
  end

  local nearest = nil
  for _, seg in ipairs(line_map) do
    if gen_lnum >= seg.gen_start and gen_lnum <= seg.gen_end then
      local src_lnum, src_col = map_col(seg)
      return {
        filename = vim.api.nvim_buf_get_name(seg.bufnr),
        lnum = src_lnum,
        col = src_col,
        exact = true,
        item_idx = seg.item_idx,
        src_start = seg.src_start,
        src_end = seg.src_end,
      }
    end
    if gen_lnum < seg.gen_start then
      nearest = seg
      break
    end
    nearest = seg
  end

  if nearest then
    return {
      filename = vim.api.nvim_buf_get_name(nearest.bufnr),
      lnum = nearest.src_start,
      col = nearest.src_start_col or 1,
      exact = false,
      item_idx = nearest.item_idx,
      src_start = nearest.src_start,
      src_end = nearest.src_end,
    }
  end
end

--- Normalize a path for comparison when possible.
--- @param path string
--- @return string
local function normalize_path(path)
  if path == nil or path == "" then
    return ""
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function normalize_root(path)
  if path == nil or path == "" then
    return nil
  end
  return normalize_path(path):gsub("/$", "")
end

--- Determine whether a Typst-reported path refers to this session's generated
--- temporary input file. Typst may report the path as absolute or relative.
--- @param session typst_watch_session
--- @param file string
--- @return boolean
local function is_session_input_path(session, file)
  if file == nil or file == "" then
    return false
  end

  local target = normalize_path(session.input_path)
  local candidates = {
    file,
    vim.fn.getcwd() .. "/" .. file,
    vim.fn.expand("~") .. "/" .. file,
  }
  if session.buf_dir then
    candidates[#candidates + 1] = session.buf_dir .. "/" .. file
  end
  if session.source_root then
    candidates[#candidates + 1] = session.source_root .. "/" .. file
  end
  if session.effective_root then
    candidates[#candidates + 1] = session.effective_root .. "/" .. file
  end

  for _, candidate in ipairs(candidates) do
    if normalize_path(candidate) == target then
      return true
    end
  end
  return false
end

--- Discover Typst package roots once, preferring `typst info --format=json`.
--- Falls back to common environment variables and platform defaults.
--- @return string[]
local function get_typst_package_roots()
  if state.typst_package_roots ~= nil then
    return state.typst_package_roots
  end

  local roots = {}
  local seen = {}
  local function add(path)
    if path == nil or path == "" then
      return
    end
    local norm = normalize_path(path)
    if norm == "" or seen[norm] then
      return
    end
    seen[norm] = true
    roots[#roots + 1] = norm
  end

  local ok_main, main = pcall(require, "typst-concealer")
  local typst_location = (ok_main and main.config and main.config.typst_location) or "typst"
  local ok_run, result = pcall(vim.system, { typst_location, "info", "--format=json" }, { text = true })
  if ok_run and result then
    local completed = result:wait(1500)
    if completed and completed.code == 0 and completed.stdout and completed.stdout ~= "" then
      local ok_json, info = pcall(vim.json.decode, completed.stdout)
      if ok_json and info and info.packages then
        add(info.packages["package-cache-path"])
        add(info.packages["package-path"])
      end
    end
  end

  add(vim.env.TYPST_PACKAGE_CACHE_PATH)
  add(vim.env.TYPST_PACKAGE_PATH)
  add(vim.fn.expand("~/Library/Caches/typst/packages"))
  add(vim.fn.expand("~/Library/Application Support/typst/packages"))
  add(vim.fn.expand("~/.cache/typst/packages"))
  add(vim.fn.expand("~/.local/share/typst/packages"))

  state.typst_package_roots = roots
  return roots
end

--- Resolve a Typst-reported source path into a local filesystem path when
--- possible. Supports:
---   - absolute paths
---   - Typst package references like @preview/pkg:1.2.3/file.typ
---   - paths relative to the buffer directory / project root
--- @param session typst_watch_session
--- @param file string
--- @return string
local function resolve_typst_source_path(session, file)
  if file == nil or file == "" then
    return vim.api.nvim_buf_get_name(session.bufnr)
  end

  if file:sub(1, 1) == "/" then
    local path_rewrite = require("typst-concealer.path-rewrite")
    return path_rewrite.resolve_to_absolute(file, session.buf_dir, session.source_root) or file
  end

  local namespace, pkg, ver, rest = file:match("^@([^/]+)/([^:]+):([^/]+)/(.*)$")
  if namespace and pkg and ver and rest then
    for _, base in ipairs(get_typst_package_roots()) do
      local path = table.concat({ base, namespace, pkg, ver, rest }, "/")
      if vim.uv.fs_stat(path) ~= nil then
        return path
      end
    end
  end

  local relative_candidates = {}
  if session.buf_dir then
    relative_candidates[#relative_candidates + 1] = session.buf_dir .. "/" .. file
  end
  if session.source_root then
    relative_candidates[#relative_candidates + 1] = session.source_root .. "/" .. file
  end
  if session.effective_root then
    relative_candidates[#relative_candidates + 1] = session.effective_root .. "/" .. file
  end

  for _, path in ipairs(relative_candidates) do
    if vim.uv.fs_stat(path) ~= nil then
      return path
    end
  end

  return file
end

--- Classify a Typst stderr location as either generated-wrapper space (map back
--- into the edited source buffer) or an external/real source file that should
--- be navigated directly.
--- @param session typst_watch_session
--- @param file string
--- @param lnum integer
--- @param col integer
--- @return table
local function resolve_report_location(session, file, lnum, col)
  if is_session_input_path(session, file) then
    local mapped = map_generated_pos(session.line_map, lnum, col)
    if mapped and mapped.exact then
      return {
        filename = mapped.filename,
        lnum = mapped.lnum,
        col = mapped.col,
        exact = true,
        generated = false,
        item_idx = mapped.item_idx,
        src_start = mapped.src_start,
        src_end = mapped.src_end,
      }
    end

    -- The error points into generated wrapper/prelude space rather than the
    -- original item body. Jump directly to the generated cache file so the
    -- user can inspect the real failing Typst source.
    return {
      filename = mapped and mapped.filename or session.input_path,
      lnum = mapped and mapped.lnum or lnum,
      col = mapped and mapped.col or col,
      exact = true,
      generated = true,
      item_idx = mapped and mapped.item_idx or nil,
      src_start = mapped and mapped.src_start or nil,
      src_end = mapped and mapped.src_end or nil,
    }
  end

  return {
    filename = resolve_typst_source_path(session, file),
    lnum = lnum,
    col = col,
    exact = true,
    generated = false,
  }
end

--- @param path string
local function safe_unlink(path)
  if vim.uv.fs_stat(path) ~= nil then
    vim.uv.fs_unlink(path)
  end
end

--- Return true when a service PNG path is still referenced by a live overlay
--- or preview item. Service PNG names are content-addressed, so a stale
--- response can point at the same file as the currently visible render.
--- @param path string|nil
--- @return boolean
local function service_page_path_in_use(path)
  if type(path) ~= "string" or path == "" then
    return false
  end

  local target = normalize_path(path)
  local machine_state = state.machine_state
  for _, overlay in pairs((machine_state and machine_state.overlays) or {}) do
    if overlay.page_path ~= nil and overlay.status ~= "retired" and normalize_path(overlay.page_path) == target then
      return true
    end
  end

  for _, bstate in pairs(state.buffer_render_state or {}) do
    for _, item in ipairs(bstate.full_items or {}) do
      if item.page_path ~= nil and normalize_path(item.page_path) == target then
        return true
      end
    end
    for _, item in ipairs(bstate.lingering_items or {}) do
      if item.page_path ~= nil and normalize_path(item.page_path) == target then
        return true
      end
    end
  end

  for _, bs in pairs(state.buffers or {}) do
    for _, item in ipairs({ bs.preview_item, bs.preview_last_rendered_item }) do
      if item ~= nil and item.page_path ~= nil and normalize_path(item.page_path) == target then
        return true
      end
    end
  end

  return false
end

--- @param path string|nil
local function safe_unlink_service_artifact(path)
  if type(path) ~= "string" or path == "" then
    return
  end
  if not service_page_path_in_use(path) then
    safe_unlink(path)
  end
end

M._service_page_path_in_use = service_page_path_in_use
M._safe_unlink_service_artifact = safe_unlink_service_artifact

--- @param path string
--- @param text string
--- @return boolean, string?
local function write_file_in_place(path, text)
  local dir = vim.fn.fnamemodify(path, ":h")
  local base = vim.fn.fnamemodify(path, ":t")
  vim.fn.mkdir(dir, "p")
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

--- @param path string
--- @param text string
--- @return boolean, string?, boolean
local function write_file_if_changed(path, text)
  local stat = vim.uv.fs_stat(path)
  if stat ~= nil then
    local fd = vim.uv.fs_open(path, "r", tonumber("644", 8))
    if fd ~= nil then
      local existing = vim.uv.fs_read(fd, stat.size, 0)
      vim.uv.fs_close(fd)
      if existing == text then
        return true, nil, false
      end
    end
  end
  local ok, err = write_file_in_place(path, text)
  return ok, err, ok
end

--- @param bufnr integer
--- @param effective_root string
--- @param kind "full"
--- @return string
local function resolve_preamble_include_line(bufnr, effective_root, kind)
  local main = require("typst-concealer")
  local config = main.config
  if type(config.get_preamble_file) ~= "function" then
    return ""
  end

  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fn.getcwd()
  local ok, pf = pcall(config.get_preamble_file, bufnr, buf_path, cwd, kind)
  if not ok or type(pf) ~= "string" or pf == "" then
    return ""
  end

  local path_rewrite = require("typst-concealer.path-rewrite")
  local abs = vim.fs.normalize(vim.fn.fnamemodify(pf, ":p")):gsub("/$", "")
  local typst_path = path_rewrite.encode_root_relative(abs, effective_root)
  return '#include "' .. typst_path .. '"\n'
end

--- Write debugging artifacts next to the generated input so path rewrite
--- issues can be inspected from the exact Typst source that was compiled.
--- @param session typst_watch_session
--- @param doc_str string
--- Remove previously rendered page images so a new watch cycle never consumes
--- stale pages before Typst finishes writing the current generation.
--- @param prefix string
local function clear_session_output_pages(prefix)
  local first = 1
  while true do
    local page_path = prefix .. "-" .. first .. ".png"
    if vim.uv.fs_stat(page_path) == nil then
      break
    end
    safe_unlink(page_path)
    first = first + 1
  end
end

--- @param prefix string
--- @param page_idx integer
local function clear_session_output_page(prefix, page_idx)
  if type(page_idx) ~= "number" or page_idx < 1 then
    return
  end
  safe_unlink(prefix .. "-" .. page_idx .. ".png")
end

local function parse_typst_stderr(session, text)
  local items = {}
  local current_msg = nil
  local current_type = "E"
  local current_has_location = false

  local function fallback_item(msg, typ)
    local mapped = map_generated_pos(session.line_map, 1, 1)
    return {
      filename = mapped and mapped.filename or vim.api.nvim_buf_get_name(session.bufnr),
      lnum = mapped and mapped.lnum or 1,
      col = mapped and mapped.col or 1,
      text = msg,
      type = typ or "E",
    }
  end

  local function flush_pending_message()
    if current_msg ~= nil and current_msg ~= "" and not current_has_location then
      items[#items + 1] = fallback_item(current_msg, current_type)
    end
    current_msg = nil
    current_type = "E"
    current_has_location = false
  end

  for line in (text .. "\n"):gmatch("(.-)\n") do
    local trimmed = vim.trim(line)

    if trimmed == "" then
      flush_pending_message()
    else
      local err_msg = trimmed:match("^error:%s*(.*)$")
      local warn_msg = trimmed:match("^warning:%s*(.*)$")
      if err_msg and err_msg ~= "" then
        flush_pending_message()
        current_msg = err_msg
        current_type = "E"
      elseif warn_msg and warn_msg ~= "" then
        flush_pending_message()
        current_msg = warn_msg
        current_type = "W"
      end

      local file, lnum, col = trimmed:match("^┌─%s+(.+):(%d+):(%d+)$")
      if not file then
        file, lnum, col = trimmed:match("^╭─%s+(.+):(%d+):(%d+)$")
      end
      if not file then
        file, lnum, col = trimmed:match("^%s*[╭┌]─%s+(.+):(%d+):(%d+)$")
      end

      if file and lnum and col then
        current_has_location = true
        local gen_lnum = tonumber(lnum)
        local gen_col = tonumber(col)
        local resolved = resolve_report_location(session, file, gen_lnum, gen_col)

        items[#items + 1] = {
          filename = resolved.filename,
          lnum = resolved.lnum,
          col = resolved.col,
          text = current_msg or "typst watch error",
          type = current_type,
        }
      end
    end
  end

  flush_pending_message()

  return items
end

--- Update quickfix from accumulated stderr chunks.
--- @param bufnr integer
--- @param kind  'full' | 'preview'
--- @param input_path string
--- @param chunks string[]
local function update_quickfix_from_stderr(session)
  local text = session.stderr_text or ""
  if session.stderr_line_buffer and session.stderr_line_buffer ~= "" then
    text = text .. session.stderr_line_buffer
  end
  local items = parse_typst_stderr(session, text)
  for _, item in ipairs(items) do
    item.text = ("[%s] %s"):format(session.kind, item.text)
  end
  state.watch_diagnostics[session.bufnr] = state.watch_diagnostics[session.bufnr] or {}
  state.watch_diagnostics[session.bufnr][session.kind] = items
  rebuild_quickfix(session.bufnr)
end

--- Returns (and creates) a per-buffer cache directory.
--- Prefer placing it inside source_root so generated inputs stay within
--- the same Typst project root as real source files.
--- @param bufnr integer
--- @param source_root string|nil
--- @return string
local function get_cache_dir(bufnr, source_root)
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
  -- Simple polynomial hash to distinguish same-named files in different directories
  local hash_input = (buf_file ~= nil and buf_file ~= "") and buf_file or tostring(bufnr)
  local h = 0
  for i = 1, #hash_input do
    h = (h * 31 + hash_input:byte(i)) % 0xFFFF
  end
  local base_dir
  if source_root ~= nil and source_root ~= "" then
    base_dir = source_root .. "/.typst-concealer"
  else
    base_dir = vim.fn.stdpath("cache") .. "/typst-concealer"
  end
  local dir = base_dir .. "/" .. safe_name .. "-" .. string.format("%04x", h)
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Remove unreferenced service-generated PNGs and preview sidecars for a buffer
--- cache directory. PNG deletion goes through safe_unlink_service_artifact
--- because service output paths are content-addressed and may be shared.
--- @param dir string|nil
local function cleanup_service_cache_dir(dir)
  if dir == nil or dir == "" then
    return
  end
  local scan = vim.uv.fs_scandir(dir)
  if scan == nil then
    return
  end
  while true do
    local name, typ = vim.uv.fs_scandir_next(scan)
    if name == nil then
      break
    end
    if typ == "file" and (name:match("%.png$") or name:match("^%.typst%-concealer%-preview%-.*%.typ$")) then
      local path = dir .. "/" .. name
      if name:match("%.png$") then
        safe_unlink_service_artifact(path)
      else
        safe_unlink(path)
      end
    end
  end
end

--- @param dir string|nil
local function cleanup_service_workspace_dir(dir)
  if dir == nil or dir == "" then
    return
  end
  local scan = vim.uv.fs_scandir(dir)
  if scan == nil then
    return
  end
  while true do
    local name, typ = vim.uv.fs_scandir_next(scan)
    if name == nil then
      break
    end
    local path = dir .. "/" .. name
    if typ == "directory" then
      cleanup_service_workspace_dir(path)
      pcall(vim.uv.fs_rmdir, path)
    elseif typ == "file" then
      if name:match("%.png$") then
        safe_unlink_service_artifact(path)
      elseif name:match("%.typ$") or name:match("^%.") then
        safe_unlink(path)
      end
    end
  end
end

function M._cleanup_service_workspace_for_buf(bufnr)
  cleanup_service_workspace_dir(state.service_workspace_dirs and state.service_workspace_dirs[bufnr])
  if state.service_workspace_dirs then
    state.service_workspace_dirs[bufnr] = nil
  end
end

--- Generates the fixed input path for a watch session.
--- @param bufnr integer
--- @param source_root string|nil
--- @return string
local function session_input_path(bufnr, source_root)
  local dir = get_cache_dir(bufnr, source_root)
  return dir .. "/.typst-concealer-" .. state.full_pid .. "-" .. bufnr .. ".typ"
end

--- Generates the fixed output template/prefix for a watch session.
--- @param bufnr integer
--- @return string template, string prefix
local function session_output_template(bufnr)
  local prefix = "/tmp/tty-graphics-protocol-typst-concealer-" .. state.full_pid .. "-" .. bufnr
  return prefix .. "-{p}.png", prefix
end

--- @param bufnr integer
--- @param source_root string|nil
--- @return string
local function session_preview_sidecar_path(bufnr, source_root)
  local dir = get_cache_dir(bufnr, source_root)
  return dir .. "/.typst-concealer-" .. state.full_pid .. "-" .. bufnr .. "-preview.typ"
end

local function get_watch_session(bufnr, kind)
  local bucket = state.watch_sessions[bufnr]
  return bucket and bucket[kind] or nil
end

--- Report whether a watch session exists and is still alive.
--- @param bufnr integer
--- @param kind "full"
--- @return boolean
function M.has_watch_session(bufnr, kind)
  local session = get_watch_session(bufnr, kind)
  return session ~= nil and session.dead ~= true
end

local function compose_session_items(session)
  local items = {}
  for _, item in ipairs(session.base_items or {}) do
    items[#items + 1] = item
  end
  if session.preview_tail_item ~= nil then
    items[#items + 1] = session.preview_tail_item
  end
  return items
end

--- @param request RenderRequest
--- @return RenderRequestMeta
local function build_render_request_meta(request)
  local jobs = request.jobs or {}
  local page_to_slot = {}
  local slot_to_node = {}
  local slot_to_overlay = {}

  for i, job in ipairs(jobs) do
    local page_index = job.request_page_index or i
    job.request_id = request.request_id
    job.request_page_index = page_index
    job.slot_id = job.slot_id or ("slot:" .. tostring(page_index))
    if job.slot_id ~= nil then
      page_to_slot[page_index] = job.slot_id
      if job.node_id ~= nil then
        slot_to_node[job.slot_id] = job.node_id
      end
      if job.overlay_id ~= nil then
        slot_to_overlay[job.slot_id] = job.overlay_id
      end
    end
  end

  return {
    request_id = request.request_id,
    bufnr = request.bufnr,
    render_epoch = request.render_epoch,
    buffer_version = request.buffer_version,
    layout_version = request.layout_version,
    shape_epoch = request.shape_epoch or 0,
    project_scope_id = request.project_scope_id,
    jobs = jobs,
    page_to_slot = page_to_slot,
    slot_to_node = slot_to_node,
    slot_to_overlay = slot_to_overlay,
    page_count = #jobs,
    status = "active",
  }
end

--- Watch adapter metadata retains fixed output page maps required by typst
--- watch polling. Service code uses build_render_request_meta directly.
--- @param request RenderRequest
--- @return RenderRequestMeta
local function build_watch_request_meta(request)
  local meta = build_render_request_meta(request)
  local page_to_overlay = {}
  local overlay_to_page = {}
  for i, job in ipairs(meta.jobs or {}) do
    local page_index = job.request_page_index or i
    if job.overlay_id ~= nil then
      page_to_overlay[page_index] = job.overlay_id
      overlay_to_page[job.overlay_id] = page_index
    end
  end
  meta.page_to_overlay = page_to_overlay
  meta.overlay_to_page = overlay_to_page
  return meta
end

local function is_active_request_page(session, i)
  local request = session.current_request
  return request ~= nil and request.status == "active" and i >= 1 and i <= request.page_count
end

local function replace_current_request(session, request)
  if session.current_request ~= nil then
    session.current_request.status = "abandoned"
  end
  session.current_request = build_watch_request_meta(request)
  return session.current_request
end

local function clear_request_output_pages(session, page_count)
  local last_count = session.last_page_count or 0
  local clear_count = math.max(last_count, page_count or 0)
  for i = 1, clear_count do
    clear_session_output_page(session.output_prefix, i)
  end
  session.page_state = {}
  session.last_page_count = 0
  -- If the generated input text is identical to the previous request, Typst
  -- still needs a fresh write after pages were cleared.
  session.last_input_text = nil
end

local function session_render_start_index(session)
  local total = #(session.items or {})
  if total == 0 then
    return 1
  end
  local start_idx = tonumber(session.render_start_index) or 1
  if start_idx > total then
    return total + 1
  end
  return math.max(1, start_idx)
end

local FAST_POLL_INTERVAL_MS = 30
local IDLE_POLL_INTERVAL_MS = 80
local try_render_session_page
local on_service_response
local finish_service_response
local get_compiler_service
local send_next_service_payload
local service_cache_key

--- @param session typst_watch_session
--- @return boolean
local function full_pages_have_stable_renders(session)
  local total = session.current_request and session.current_request.page_count or #(session.base_items or {})
  if total == 0 then
    return false
  end
  for i = 1, total do
    local page_state = session.page_state[i]
    if page_state == nil or page_state.rendered == nil then
      return false
    end
  end
  return true
end

--- @param bufnr integer
--- @return string[]
local function snapshot_full_context_preludes(bufnr)
  local bstate = state.buffer_render_state[bufnr]
  return (bstate and bstate.runtime_preludes) or {}
end

--- @param session typst_watch_session
--- @param item table|nil
--- @return string
local function build_preview_sidecar_document(session, item)
  local wrapper = require("typst-concealer.wrapper")
  local preview_item = item
  if preview_item == nil then
    preview_item = {
      bufnr = session.bufnr,
      range = { 0, 0, 0, 0 },
      str = "[]",
      prelude_count = 0,
      node_type = "math",
      semantics = { constraint_kind = "inline" },
    }
  else
    preview_item = vim.tbl_extend("force", preview_item, {
      prelude_count = preview_item.prelude_count or 0,
    })
  end

  local doc_str = wrapper.build_item_fragment(
    preview_item,
    session.buf_dir,
    session.source_root,
    session.effective_root,
    session.prelude_chunks
  )
  return doc_str
end

--- @param session typst_watch_session
--- @param item table|nil
--- @return boolean, string?
local function write_preview_sidecar(session, item)
  local text = build_preview_sidecar_document(session, item)
  if session.last_preview_sidecar_text == text then
    return true
  end
  local ok, err = write_file_in_place(session.preview_sidecar_path, text)
  if ok then
    session.last_preview_sidecar_text = text
  end
  return ok, err
end

local function preview_tail_include_text(session)
  return '#include "' .. session.preview_sidecar_root_relative_path .. '"'
end

--- @param session typst_watch_session
--- @param item table|nil
--- @return table
local function make_preview_tail_item(session, item)
  local source = item or {}
  return {
    bufnr = session.bufnr,
    image_id = source.image_id,
    extmark_id = source.extmark_id,
    range = source.range and vim.deepcopy(source.range) or { 0, 0, 0, 0 },
    str = preview_tail_include_text(session),
    source_str = source.source_str,
    prelude_count = 0,
    node_type = source.node_type or "math",
    semantics = source.semantics or { constraint_kind = "inline" },
    skip_wrapper = true,
    render_target = source.render_target or "preview_tail_inactive",
    source_image_id = source.source_image_id,
  }
end

--- @param session typst_watch_session
--- @param mode '"full"' | '"preview"'
local function write_session_document(session, mode)
  local items = compose_session_items(session)
  if #items == 0 then
    M.stop_watch_session(session.bufnr, session.kind)
    return
  end

  local old_page_count = session.last_page_count or 0
  session.items = items
  session.line_map = nil
  session.last_page_count = #items

  if mode == "preview" then
    local tail_idx = #session.base_items + 1
    clear_session_output_page(session.output_prefix, tail_idx)
    session.page_state[tail_idx] = nil
    if old_page_count > #items then
      clear_session_output_page(session.output_prefix, old_page_count)
      session.page_state[old_page_count] = nil
    end
  else
    -- Keep the previous full render visible until replacement pages arrive.
    -- Only prune stale tail pages when the new document shrinks.
    if old_page_count > #items then
      for i = #items + 1, old_page_count do
        clear_session_output_page(session.output_prefix, i)
        session.page_state[i] = nil
      end
    end
  end

  if require("typst-concealer").config.do_diagnostics then
    session.stderr_chunks = {}
    session.stderr_text = ""
    session.stderr_line_buffer = ""
    clear_quickfix(session.bufnr, session.kind)
  end

  local wrapper = require("typst-concealer.wrapper")
  local do_diagnostics = require("typst-concealer").config.do_diagnostics
  local doc_str, line_map = wrapper.build_batch_document(
    items,
    session.buf_dir,
    session.source_root,
    session.effective_root,
    "full",
    session.prelude_chunks,
    session.preamble_include_line,
    do_diagnostics,
    session.wrapper_cache
  )
  session.line_map = line_map
  if session.last_input_text == doc_str then
    return
  end
  local ok, err = write_file_in_place(session.input_path, doc_str)
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to update watch input: " .. tostring(err), vim.log.levels.ERROR)
    end)
    return
  end
  session.last_input_text = doc_str
  session.last_input_write_count = (session.last_input_write_count or 0) + 1
end

--- @param bufnr integer
--- @param range table
--- @return string|nil
local function range_to_string(bufnr, range)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local start_row, start_col, end_row, end_col = range[1], range[2], range[3], range[4]
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count <= 0 then
    return ""
  end

  start_row = math.max(0, math.min(start_row, line_count - 1))
  end_row = math.max(start_row, math.min(end_row, line_count - 1))

  local content = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
  if #content == 0 then
    return ""
  end

  local first_len = #(content[1] or "")
  local last_len = #(content[#content] or "")
  start_col = math.max(0, math.min(start_col, first_len))
  end_col = math.max(0, math.min(end_col, last_len))

  if start_row == end_row then
    if end_col < start_col then
      end_col = start_col
    end
    content[1] = string.sub(content[1], start_col + 1, end_col)
  else
    content[1] = string.sub(content[1], start_col + 1)
    content[#content] = string.sub(content[#content], 1, end_col)
  end

  return table.concat(content, "\n")
end

--- Stop a watch session and clean up its files.
--- @param bufnr integer
--- @param kind  'full'
function M.stop_watch_session(bufnr, kind)
  local bucket = state.watch_sessions[bufnr]
  if bucket == nil or bucket[kind] == nil then
    return
  end
  local session = bucket[kind]

  if session.stderr_debounce and not session.stderr_debounce:is_closing() then
    session.stderr_debounce:stop()
    session.stderr_debounce:close()
  end
  if session.poll_timer and not session.poll_timer:is_closing() then
    session.poll_timer:stop()
    session.poll_timer:close()
  end
  if session.stdout and not session.stdout:is_closing() then
    session.stdout:close()
  end
  if session.stderr and not session.stderr:is_closing() then
    session.stderr:close()
  end
  if session.handle and not session.handle:is_closing() then
    session.handle:kill(15)
    session.handle:close()
  end

  safe_unlink(session.input_path)
  safe_unlink(session.preview_sidecar_path)
  for i = 1, session.last_page_count or 0 do
    safe_unlink(session.output_prefix .. "-" .. i .. ".png")
  end

  bucket[kind] = nil
  if state.watch_diagnostics[bufnr] then
    state.watch_diagnostics[bufnr][kind] = nil
    if next(state.watch_diagnostics[bufnr]) == nil then
      state.watch_diagnostics[bufnr] = nil
    end
    rebuild_quickfix(bufnr)
  end
  if next(bucket) == nil then
    state.watch_sessions[bufnr] = nil
  end
end

--- @param bufnr integer
function M.stop_watch_sessions_for_buf(bufnr)
  M.stop_watch_session(bufnr, "full")
  M.stop_compiler_service(bufnr)
end

--- Called when a rendered page file is stable enough to inspect.
--- @param bufnr          integer
--- @param page_path      string
--- @param item           table
--- @param original_range table
--- @param page_stamp     string
--- @return table|nil
local function build_page_update(bufnr, page_path, item, original_range, page_stamp)
  local pngData = require("typst-concealer.png-lua")
  local kitty_codes = require("typst-concealer.kitty-codes")

  if item == nil then
    return
  end

  local target_range = original_range
  if item and item.render_target == "float" then
    target_range = item.target_range or original_range
  end

  local expected_str = item.source_str or item.source_text or item.str
  if expected_str ~= nil and range_to_string(item.bufnr, item.range) ~= expected_str then
    return
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

  return {
    bufnr = bufnr,
    image_id = item.image_id,
    extmark_id = item.extmark_id,
    original_range = original_range,
    page_path = page_path,
    page_stamp = page_stamp,
    natural_cols = natural_cols,
    natural_rows = natural_rows,
    source_rows = source_rows,
  }
end

--- Called when a legacy rendered page is ready to display.
--- @param bufnr          integer
--- @param page_path      string
--- @param image_id       integer
--- @param extmark_id     integer
--- @param original_range table
--- @param page_stamp     string
local function on_page_rendered(bufnr, page_path, image_id, extmark_id, original_range, page_stamp)
  local item = state.get_item_by_image_id(image_id)
  if item == nil or type(extmark_id) ~= "number" then
    return false
  end

  local update = build_page_update(bufnr, page_path, item, original_range, page_stamp)
  if update == nil then
    return false
  end
  if item.preview_request_id ~= nil then
    update.preview_request_id = item.preview_request_id
    return require("typst-concealer.machine.runtime").accept_preview_page_update(update)
  end
  require("typst-concealer.apply").accept_page_update(update)
  return true
end

--- @param session typst_watch_session
--- @param request RenderRequestMeta
--- @param request_page_index integer
--- @param job RenderJob
--- @param page_path string
--- @param page_stamp string
--- @return boolean
local function on_request_page_rendered(session, request, request_page_index, job, page_path, page_stamp)
  if job == nil or request == nil or request.status ~= "active" then
    return false
  end
  if request.page_to_overlay[request_page_index] ~= job.overlay_id then
    return false
  end

  local update = build_page_update(session.bufnr, page_path, job, job.range, page_stamp)
  if update == nil then
    return false
  end

  require("typst-concealer.machine.runtime").dispatch({
    type = "overlay_page_ready",
    request_id = request.request_id,
    request_page_index = request_page_index,
    overlay_id = job.overlay_id,
    owner_node_id = job.node_id,
    owner_bufnr = job.bufnr,
    owner_project_scope_id = job.project_scope_id,
    render_epoch = job.render_epoch,
    buffer_version = job.buffer_version,
    layout_version = job.layout_version,
    page_path = page_path,
    page_stamp = page_stamp,
    natural_cols = update.natural_cols,
    natural_rows = update.natural_rows,
    source_rows = update.source_rows,
  })
  return true
end

--- @param width_px integer
--- @param height_px integer
--- @param job RenderJob
--- @return integer
local function compute_natural_cols(width_px, height_px, job)
  width_px = tonumber(width_px) or 1
  height_px = tonumber(height_px) or 1
  if width_px <= 0 then
    width_px = 1
  end
  if height_px <= 0 then
    height_px = 1
  end

  local source_rows = job.range[3] - job.range[1] + 1
  local natural_cols
  if state._cell_px_w and state._cell_px_h then
    natural_cols = math.max(1, math.floor(width_px / state._cell_px_w + 0.5))
    if source_rows == 1 and not (job.semantics and job.semantics.display_kind == "block") then
      local aspect = width_px / height_px
      natural_cols = math.max(1, math.floor(state._cell_px_h * aspect / state._cell_px_w + 0.5))
    end
  elseif source_rows == 1 and not (job.semantics and job.semantics.display_kind == "block") then
    natural_cols = math.max(1, math.floor((width_px / height_px) * 2))
  else
    natural_cols = math.ceil((width_px / height_px) * 2) * source_rows
  end

  local kitty_codes = require("typst-concealer.kitty-codes")
  if natural_cols >= #kitty_codes.diacritics then
    natural_cols = #kitty_codes.diacritics - 1
  end
  return natural_cols
end

--- @param width_px integer
--- @param height_px integer
--- @param job RenderJob
--- @return integer
local function compute_natural_rows(width_px, height_px, job)
  width_px = tonumber(width_px) or 1
  height_px = tonumber(height_px) or 1
  if width_px <= 0 then
    width_px = 1
  end
  if height_px <= 0 then
    height_px = 1
  end

  local source_rows = job.range[3] - job.range[1] + 1
  if state._cell_px_w and state._cell_px_h then
    if source_rows == 1 and not (job.semantics and job.semantics.display_kind == "block") then
      return 1
    end
    return math.max(1, math.floor(height_px / state._cell_px_h + 0.5))
  end
  return source_rows
end

--- Extract --input key=value pairs from compiler_args and project_scope.inputs.
--- @param config table
--- @param project_scope table
--- @return table<string, string>
local function extract_service_inputs(config, project_scope)
  local inputs = {}
  if config.compiler_args then
    local i = 1
    while i <= #config.compiler_args do
      local arg = config.compiler_args[i]
      if arg == "--input" and i + 1 <= #config.compiler_args then
        local kv = config.compiler_args[i + 1]
        local eq = kv:find("=", 1, true)
        if eq then
          inputs[kv:sub(1, eq - 1)] = kv:sub(eq + 1)
        end
        i = i + 2
      elseif arg:sub(1, 8) == "--input=" then
        local kv = arg:sub(9)
        local eq = kv:find("=", 1, true)
        if eq then
          inputs[kv:sub(1, eq - 1)] = kv:sub(eq + 1)
        end
        i = i + 1
      else
        i = i + 1
      end
    end
  end
  for _, s in ipairs(project_scope.inputs or {}) do
    local eq = s:find("=", 1, true)
    if eq ~= nil then
      inputs[s:sub(1, eq - 1)] = s:sub(eq + 1)
    end
  end
  return inputs
end

--- @param text string
--- @return string
local function stable_hash(text)
  local ok, digest = pcall(vim.fn.sha256, text)
  if ok and type(digest) == "string" and digest ~= "" then
    return digest:sub(1, 16)
  end

  local h = 0
  for i = 1, #text do
    h = (h * 31 + text:byte(i)) % 0xFFFFFFFF
  end
  return string.format("%08x", h)
end

--- @param item table
--- @return integer
local function item_source_rows(item)
  local range = item.range or { 0, 0, 0, 0 }
  return math.max(1, (range[3] or 0) - (range[1] or 0) + 1)
end

--- Build the preview sidecar exactly like a full-render slot: runtime prelude,
--- wrapper, and the current preview body all live in the included file.  The
--- preview main document stays stable and only includes this context-owned
--- sidecar, matching the full service render layout.
--- @param item table
--- @param project_scope table
--- @param prelude_chunks string[]
--- @return string
local function build_preview_service_sidecar_source(item, project_scope, prelude_chunks)
  local text = require("typst-concealer.wrapper").build_slot_document(
    item,
    project_scope.buf_dir,
    project_scope.source_root,
    project_scope.effective_root,
    prelude_chunks
  )
  return text
end

--- @param service typst_compiler_service
--- @param sidecar_path string
--- @param sidecar_text string
--- @return fun(): boolean, string?
local function make_preview_sidecar_prepare(service, sidecar_path, sidecar_text)
  return function()
    service._preview_sidecar_texts = service._preview_sidecar_texts or {}
    if service._preview_sidecar_texts[sidecar_path] == sidecar_text and vim.uv.fs_stat(sidecar_path) ~= nil then
      return true
    end
    local ok, err = write_file_in_place(sidecar_path, sidecar_text)
    if ok then
      service._preview_sidecar_texts[sidecar_path] = sidecar_text
    end
    return ok, err
  end
end

local function root_relative(path, effective_root)
  return require("typst-concealer.path-rewrite").encode_root_relative(path, effective_root)
end

--- @param request RenderRequest
--- @param project_scope table
--- @param workspace table
--- @param context_text string
--- @return string
local function build_full_main_document(request, project_scope, workspace, context_text)
  local parts = {}
  if context_text ~= nil and context_text ~= "" then
    parts[#parts + 1] = context_text
    if context_text:sub(-1) ~= "\n" then
      parts[#parts + 1] = "\n"
    end
    parts[#parts + 1] = "#pagebreak(weak: true)\n"
  end
  for idx, job in ipairs(request.jobs or {}) do
    if idx > 1 then
      parts[#parts + 1] = "#pagebreak()\n"
    end
    local slot_path = require("typst-concealer.workspace").slot_path(workspace, job.slot_id or idx)
    parts[#parts + 1] = '#include "' .. root_relative(slot_path, project_scope.effective_root) .. '"\n'
  end
  return table.concat(parts)
end

--- @param service typst_compiler_service
--- @param writes table[]
--- @return fun(): boolean, string?
local function make_full_sidecar_prepare(service, writes)
  return function()
    service._full_sidecar_texts = service._full_sidecar_texts or {}
    for _, entry in ipairs(writes or {}) do
      local path = entry.path
      local text = entry.text or ""
      if service._full_sidecar_texts[path] ~= text or vim.uv.fs_stat(path) == nil then
        local ok, err = write_file_if_changed(path, text)
        if not ok then
          return false, err
        end
        service._full_sidecar_texts[path] = text
      end
    end
    return true
  end
end

--- @param request RenderRequest
--- @param project_scope table
--- @param prelude_chunks string[]
--- @param preamble_include_line string
--- @param config table
--- @return table
local function build_full_service_spec(request, project_scope, prelude_chunks, preamble_include_line, config)
  local wrapper = require("typst-concealer.wrapper")
  local workspace_mod = require("typst-concealer.workspace")
  local workspace = workspace_mod.for_buffer(request.bufnr, project_scope.source_root)
  local context_text = wrapper.build_context_document(
    request.bufnr,
    project_scope.buf_dir,
    project_scope.source_root,
    project_scope.effective_root,
    preamble_include_line
  )
  local main_text = build_full_main_document(request, project_scope, workspace, context_text)
  local writes = {
    { path = workspace.context_path, text = context_text, kind = "context" },
    { path = workspace.main_path, text = main_text, kind = "main" },
  }
  local slot_line_maps = {}
  local generated_slot_paths = {}

  for _, job in ipairs(request.jobs or {}) do
    local slot_path = workspace_mod.slot_path(workspace, job.slot_id)
    generated_slot_paths[job.slot_id] = slot_path
    local slot_text, slot_map = wrapper.build_slot_document(
      job,
      project_scope.buf_dir,
      project_scope.source_root,
      project_scope.effective_root,
      prelude_chunks
    )
    if slot_map ~= nil then
      slot_map.filename = vim.api.nvim_buf_get_name(job.bufnr)
      slot_line_maps[normalize_path(slot_path)] = slot_map
    end
    if job.slot_dirty == true or vim.uv.fs_stat(slot_path) == nil then
      writes[#writes + 1] = {
        path = slot_path,
        text = slot_text,
        kind = "slot",
        slot_id = job.slot_id,
      }
    end
  end

  return {
    workspace = workspace,
    source_text = main_text,
    writes = writes,
    slot_line_maps = slot_line_maps,
    generated_slot_paths = generated_slot_paths,
    generated_input_path = workspace.main_path,
    generated_context_path = workspace.context_path,
    output_dir = workspace.outputs_dir,
    -- Keep one full-render compiler per project scope. Using shape_epoch here
    -- causes the service to retain one Compiler per structural edit.
    cache_key = service_cache_key(project_scope, "full"),
  }
end

--- @param resp table
local function cleanup_request_artifacts(resp)
  for _, page in ipairs(resp.pages or {}) do
    if type(page.path) == "string" and page.path ~= "" then
      safe_unlink_service_artifact(page.path)
    end
  end
end

local function cleanup_service_pages(pages)
  for _, page in ipairs(pages or {}) do
    if type(page.path) == "string" and page.path ~= "" then
      safe_unlink_service_artifact(page.path)
    end
  end
end

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

local function select_last_service_page(resp)
  if type(resp.pages) ~= "table" or #resp.pages == 0 then
    return nil, {}
  end

  local selected = nil
  local selected_pos = nil
  local selected_page_index = nil
  for pos, page in ipairs(resp.pages) do
    local page_index = tonumber(page.page_index)
    if is_integer(page_index) and (selected_page_index == nil or page_index > selected_page_index) then
      selected = page
      selected_pos = pos
      selected_page_index = page_index
    end
  end

  if selected == nil then
    selected = resp.pages[#resp.pages]
    selected_pos = #resp.pages
  end

  local leading_pages = {}
  for pos, page in ipairs(resp.pages) do
    if pos ~= selected_pos then
      leading_pages[#leading_pages + 1] = page
    end
  end

  return selected, leading_pages
end

--- Validate the compiler-service page contract before dispatching any page.
--- @param meta RenderRequestMeta
--- @param resp table
--- @return boolean, table|string
local function validate_service_pages(meta, resp)
  if type(resp.pages) ~= "table" then
    return false, "missing pages array"
  end
  local expected_pages = meta.page_count or 0
  local total_pages = #resp.pages
  if total_pages < expected_pages then
    return false, ("page count mismatch: expected at least %d, got %d"):format(expected_pages, total_pages)
  end

  local seen = {}
  local pages_by_doc_index = {}
  local pages_by_request_index = {}
  for _, page in ipairs(resp.pages) do
    local raw_page_index = tonumber(page.page_index)
    if not is_integer(raw_page_index) then
      return false, "page_index must be an integer"
    end
    if raw_page_index < 0 then
      return false, ("page_index out of range: %s"):format(tostring(page.page_index))
    end
    if seen[raw_page_index] then
      return false, ("duplicate page_index: %d"):format(raw_page_index)
    end
    seen[raw_page_index] = true
    if type(page.path) ~= "string" or page.path == "" then
      return false, "page path must be a non-empty string"
    end
    if (tonumber(page.width_px) or 0) <= 0 or (tonumber(page.height_px) or 0) <= 0 then
      return false, "page width/height must be positive"
    end
    pages_by_doc_index[raw_page_index + 1] = page
  end

  for i = 1, total_pages do
    if pages_by_doc_index[i] == nil then
      return false, ("missing page_index: %d"):format(i - 1)
    end
  end

  local leading_page_count = total_pages - expected_pages
  pages_by_request_index.leading_pages = {}
  pages_by_request_index.leading_page_count = leading_page_count
  pages_by_request_index.total_pages = total_pages
  for i = 1, leading_page_count do
    pages_by_request_index.leading_pages[#pages_by_request_index.leading_pages + 1] = pages_by_doc_index[i]
  end
  for request_index = 1, expected_pages do
    pages_by_request_index[request_index] = pages_by_doc_index[leading_page_count + request_index]
  end

  return true, pages_by_request_index
end

--- @param bufnr integer
--- @param meta RenderRequestMeta
--- @return boolean, string?
local function validate_service_request_fresh(bufnr, meta)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "buffer is no longer valid"
  end
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  if tonumber(meta.buffer_version) ~= changedtick then
    return false,
      ("buffer changedtick mismatch: expected %s, got %s"):format(tostring(meta.buffer_version), tostring(changedtick))
  end
  local ms = state.machine_state
  local buf = ms and ms.buffers and ms.buffers[bufnr] or nil
  if buf == nil then
    return false, "machine buffer is gone"
  end
  if buf.active_request_id ~= meta.request_id then
    return false,
      ("active request mismatch: expected %s, got %s"):format(
        tostring(meta.request_id),
        tostring(buf.active_request_id)
      )
  end
  if buf.project_scope_id ~= meta.project_scope_id then
    return false, "project scope changed"
  end
  if tonumber(buf.layout_version) ~= tonumber(meta.layout_version) then
    return false, "layout version changed"
  end
  return true
end

--- @param meta RenderRequestMeta
--- @return boolean, string?
local function validate_service_job_ranges(meta)
  for _, job in ipairs(meta.jobs or {}) do
    if job.is_stub or job.overlay_id == nil then
      goto continue_validate
    end
    local expected_str = job.source_str or job.source_text or job.str
    if expected_str ~= nil and range_to_string(job.bufnr, job.range) ~= expected_str then
      return false, ("source range changed for %s"):format(tostring(job.overlay_id))
    end
    ::continue_validate::
  end
  return true
end

--- @param bufnr integer
--- @param meta RenderRequestMeta
--- @param reason string
--- @param event_type string
local function dispatch_request_cleanup(bufnr, meta, reason, event_type)
  if meta ~= nil then
    meta.status = event_type == "render_request_superseded" and "superseded" or "failed"
  end
  if state.active_service_requests and state.active_service_requests[bufnr] == meta then
    state.active_service_requests[bufnr] = nil
  end
  if meta == nil or meta.request_id == nil then
    return
  end
  require("typst-concealer.machine.runtime").dispatch({
    type = event_type,
    bufnr = bufnr,
    request_id = meta and meta.request_id or nil,
    reason = reason,
  })
end

--- @param bufnr integer
--- @param meta RenderRequestMeta|nil
--- @param reason string
local function fail_full_service_request(bufnr, meta, reason)
  dispatch_request_cleanup(bufnr, meta, reason, "render_request_failed")
end

--- @param bufnr integer
--- @param meta RenderRequestMeta|nil
--- @param reason string
local function supersede_full_service_request(bufnr, meta, reason)
  dispatch_request_cleanup(bufnr, meta, reason, "render_request_superseded")
end

M._validate_service_pages = validate_service_pages

--- @param bufnr integer
--- @param meta table|nil
--- @param diagnostics table[]|nil
local function handle_compile_diagnostics(bufnr, meta, diagnostics)
  local config = require("typst-concealer").config
  if not config.do_diagnostics then
    return
  end

  local function generated_path(path)
    if type(path) ~= "string" or path == "" then
      return false
    end
    local norm = normalize_path(path)
    if meta ~= nil and normalize_path(meta.generated_input_path) == norm then
      return true
    end
    if meta ~= nil and normalize_path(meta.generated_context_path) == norm then
      return true
    end
    return false
  end

  local items = {}
  for _, diag in ipairs(diagnostics or {}) do
    local line = tonumber(diag.line) or 1
    local column = tonumber(diag.column) or 1
    local filename = diag.file
    local prefix = "[service]"

    if filename == nil or filename == "" then
      local mapped = meta and map_generated_pos(meta.line_map, line, column) or nil
      if mapped ~= nil and mapped.exact == true then
        filename = mapped.filename
        line = mapped.lnum
        column = mapped.col
      else
        filename = (meta and meta.generated_input_path) or vim.api.nvim_buf_get_name(bufnr)
        prefix = "[service/generated]"
      end
    else
      local resolved_filename = resolve_typst_source_path({
        bufnr = bufnr,
        buf_dir = meta and meta.buf_dir or nil,
        source_root = meta and meta.source_root or nil,
        effective_root = meta and meta.effective_root or nil,
      }, filename)
      local slot_map = meta and meta.slot_line_maps and meta.slot_line_maps[normalize_path(resolved_filename)] or nil
      if slot_map ~= nil then
        local mapped = map_generated_pos({ slot_map }, line, column)
        if mapped ~= nil and mapped.exact == true then
          filename = mapped.filename
          line = mapped.lnum
          column = mapped.col
          prefix = "[service]"
        else
          filename = resolved_filename
          prefix = "[service/generated]"
        end
      elseif generated_path(resolved_filename) then
        filename = resolved_filename
        prefix = "[service/generated]"
      else
        filename = resolved_filename
        prefix = "[service/external]"
      end
    end

    items[#items + 1] = {
      filename = filename,
      lnum = line,
      col = column,
      text = ("%s %s"):format(prefix, diag.message or "typst compile error"),
      type = diag.severity == "warning" and "W" or "E",
    }
  end

  state.watch_diagnostics[bufnr] = state.watch_diagnostics[bufnr] or {}
  state.watch_diagnostics[bufnr].full = items
  rebuild_quickfix(bufnr)
end

--- Handle a preview compile response from the service.
--- @param bufnr integer
--- @param service_kind '"full"'|'"preview"'
--- @param resp table
--- @return boolean true if this was a preview response
local function try_handle_preview_service_response(bufnr, service_kind, resp)
  if service_kind ~= "preview" then
    return false
  end
  local pmeta = state.active_preview_service_requests and state.active_preview_service_requests[bufnr]
  if pmeta == nil or pmeta.request_id ~= resp.request_id then
    return false
  end

  -- Matched a preview request — consume it regardless of status.
  state.active_preview_service_requests[bufnr] = nil
  state._last_preview_service_bench = {
    request_id = resp.request_id,
    total_pages = #(resp.pages or {}),
    compile_us = resp.compile_us,
    render_us = resp.render_us,
    rendered_pages = resp.rendered_pages,
    request_sent_at = pmeta.sent_at,
    response_at = vim.uv.hrtime(),
  }

  if resp.status ~= "ok" or not resp.pages or #resp.pages == 0 then
    cleanup_request_artifacts(resp)
    return true
  end

  local page, leading_pages = select_last_service_page(resp)
  if type(page.path) ~= "string" then
    cleanup_request_artifacts(resp)
    return true
  end

  local item = pmeta.item
  local update = build_page_update(bufnr, page.path, item, item.range, nil)
  if update == nil then
    cleanup_request_artifacts(resp)
    return true
  end

  update.preview_request_id = item.preview_request_id
  local accepted = require("typst-concealer.machine.runtime").accept_preview_page_update(update)
  cleanup_service_pages(leading_pages)
  if not accepted then
    safe_unlink_service_artifact(page.path)
  end
  return true
end

--- Handle a preview backend prewarm response.  Prewarm pages are never shown;
--- they exist only to populate the service world's prelude/import/font caches.
--- @param bufnr integer
--- @param service_kind '"full"'|'"preview"'
--- @param resp table
--- @return boolean
local function try_handle_preview_prewarm_response(bufnr, service_kind, resp)
  local service = get_compiler_service(bufnr, service_kind)
  local inflight = service and service.inflight or nil
  if
    service_kind ~= "preview"
    or inflight == nil
    or inflight.request_id ~= resp.request_id
    or inflight.is_prewarm ~= true
  then
    return false
  end

  cleanup_request_artifacts(resp)
  service.preview_warmed_signatures = service.preview_warmed_signatures or {}
  if resp.status == "ok" and inflight.preview_context_hash ~= nil then
    service.preview_warmed_signatures[inflight.preview_context_hash] = true
  end
  state._last_preview_prewarm_bench = {
    request_id = resp.request_id,
    context_hash = inflight.preview_context_hash,
    total_pages = #(resp.pages or {}),
    compile_us = resp.compile_us,
    render_us = resp.render_us,
    rendered_pages = resp.rendered_pages,
    response_at = vim.uv.hrtime(),
  }
  finish_service_response(bufnr, service_kind, resp.request_id)
  return true
end

--- @param bufnr integer
--- @param service_kind '"full"'|'"preview"'
--- @param resp table  pre-decoded JSON response from the compiler service
on_service_response = function(bufnr, service_kind, resp)
  if type(resp) ~= "table" or resp.type ~= "compile_result" then
    return
  end

  if try_handle_preview_prewarm_response(bufnr, service_kind, resp) then
    return
  end

  -- Check preview requests first (they have distinct request_ids).
  if try_handle_preview_service_response(bufnr, service_kind, resp) then
    finish_service_response(bufnr, service_kind, resp.request_id)
    return
  end

  if service_kind ~= "full" then
    cleanup_request_artifacts(resp)
    finish_service_response(bufnr, service_kind, resp.request_id)
    return
  end

  local meta = state.active_service_requests and state.active_service_requests[bufnr]
  if meta == nil or meta.request_id ~= resp.request_id or meta.status ~= "active" then
    cleanup_request_artifacts(resp)
    finish_service_response(bufnr, service_kind, resp.request_id)
    return
  end

  if resp.status ~= "ok" then
    handle_compile_diagnostics(bufnr, meta, resp.diagnostics)
    cleanup_request_artifacts(resp)
    fail_full_service_request(bufnr, meta, resp.status or "compile failed")
    finish_service_response(bufnr, service_kind, resp.request_id)
    return
  end

  handle_compile_diagnostics(bufnr, meta, resp.diagnostics)

  local ok_pages, pages_or_err = validate_service_pages(meta, resp)
  if not ok_pages then
    cleanup_request_artifacts(resp)
    fail_full_service_request(bufnr, meta, pages_or_err)
    vim.schedule(function()
      vim.notify(
        "[typst-concealer] compiler service page contract failed: " .. tostring(pages_or_err),
        vim.log.levels.ERROR
      )
    end)
    finish_service_response(bufnr, service_kind, resp.request_id)
    return
  end

  local fresh, stale_reason = validate_service_request_fresh(bufnr, meta)
  if not fresh then
    cleanup_request_artifacts(resp)
    supersede_full_service_request(bufnr, meta, stale_reason or "stale service response")
    finish_service_response(bufnr, service_kind, resp.request_id)
    return
  end

  local ranges_ok, range_reason = validate_service_job_ranges(meta)
  if not ranges_ok then
    cleanup_request_artifacts(resp)
    supersede_full_service_request(bufnr, meta, range_reason or "source range changed")
    finish_service_response(bufnr, service_kind, resp.request_id)
    return
  end

  local t_lua_start = vim.uv.hrtime()
  local dispatched = 0
  local skipped_cached = 0

  local runtime = require("typst-concealer.machine.runtime")
  local pages_by_request_index = pages_or_err
  local batch_entries = {}
  for page_index = 1, meta.page_count or 0 do
    local page = pages_by_request_index[page_index]
    local job = meta.jobs[page_index]
    if job ~= nil then
      -- Skip stub jobs — these are stable slots with no active overlay
      if job.is_stub or job.overlay_id == nil then
        skipped_cached = skipped_cached + 1
        goto continue_page
      end

      -- Skip re-dispatching for cached (unchanged) pages whose overlay is
      -- already visible — avoids redundant image uploads and extmark updates.
      if page.cached then
        local ms = state.machine_state
        local overlay = ms and ms.overlays and ms.overlays[job.overlay_id]
        if overlay and overlay.status == "visible" and overlay.page_path == page.path then
          skipped_cached = skipped_cached + 1
          goto continue_page
        end
      end

      local width_px = tonumber(page.width_px) or 1
      local height_px = tonumber(page.height_px) or 1
      batch_entries[#batch_entries + 1] = {
        request_id = resp.request_id,
        request_page_index = page_index,
        overlay_id = job.overlay_id,
        owner_node_id = job.node_id,
        owner_bufnr = job.bufnr,
        owner_project_scope_id = job.project_scope_id,
        render_epoch = job.render_epoch,
        buffer_version = job.buffer_version,
        layout_version = job.layout_version,
        page_path = page.path,
        page_stamp = nil,
        natural_cols = compute_natural_cols(width_px, height_px, job),
        natural_rows = compute_natural_rows(width_px, height_px, job),
        source_rows = job.range[3] - job.range[1] + 1,
      }
      dispatched = dispatched + 1
      ::continue_page::
    end
  end

  if #batch_entries > 0 then
    runtime.dispatch({
      type = "overlay_pages_batch_ready",
      entries = batch_entries,
    })
  end
  runtime.dispatch({
    type = "render_request_completed",
    bufnr = bufnr,
    request_id = resp.request_id,
  })
  cleanup_service_pages(pages_by_request_index.leading_pages)

  local lua_us = math.floor((vim.uv.hrtime() - t_lua_start) / 1000)

  if state.active_service_requests[bufnr] == meta then
    meta.status = "completed"
    state.active_service_requests[bufnr] = nil
  end

  -- Store benchmark data for retrieval
  state._last_service_bench = {
    request_id = resp.request_id,
    total_pages = #(resp.pages or {}),
    leading_pages = pages_by_request_index.leading_page_count or 0,
    dispatched = dispatched,
    skipped_cached = skipped_cached,
    compile_us = resp.compile_us,
    render_us = resp.render_us,
    rendered_pages = resp.rendered_pages,
    lua_dispatch_us = lua_us,
    request_sent_at = meta.sent_at,
    response_at = vim.uv.hrtime(),
  }
  finish_service_response(bufnr, service_kind, resp.request_id)
end

--- @param session typst_watch_session
--- @param interval_ms integer
local function set_session_poll_interval(session, interval_ms)
  if session.poll_timer == nil or session.poll_timer:is_closing() then
    return
  end
  if session.poll_interval_ms == interval_ms then
    return
  end
  session.poll_interval_ms = interval_ms
  session.poll_timer:stop()
  session.poll_timer:start(
    interval_ms,
    interval_ms,
    vim.schedule_wrap(function()
      if session.dead then
        return
      end
      local start_idx = session_render_start_index(session)
      for i = start_idx, #(session.items or {}) do
        local item = session.items[i]
        try_render_session_page(session, i, item)
      end
    end)
  )
end

--- @param session typst_watch_session
--- @param i integer
--- @param item table|nil
--- @return boolean
local function session_page_needs_render(session, i, item)
  if item == nil or item.image_id == nil or item.render_target == "preview_tail_inactive" then
    return false
  end
  if item.extmark_id == nil and not is_active_request_page(session, i) then
    return false
  end

  local page_state = session.page_state[i]
  if page_state == nil or page_state.rendered == nil then
    return true
  end

  local page_path = session.output_prefix .. "-" .. i .. ".png"
  local stat = vim.uv.fs_stat(page_path)
  if stat == nil or stat.size == 0 then
    return true
  end

  local stamp = tostring(stat.mtime.sec) .. ":" .. tostring(stat.mtime.nsec) .. ":" .. tostring(stat.size)
  return page_state.rendered ~= stamp
end

--- @param session typst_watch_session
local function refresh_session_poll_interval(session)
  local start_idx = session_render_start_index(session)
  local has_pending = false
  for i = start_idx, #(session.items or {}) do
    if session_page_needs_render(session, i, session.items[i]) then
      has_pending = true
      break
    end
  end
  set_session_poll_interval(session, has_pending and FAST_POLL_INTERVAL_MS or IDLE_POLL_INTERVAL_MS)
end

--- Schedule a page render attempt once the poller decides the current stamp is ready enough.
--- @param session typst_watch_session
--- @param i integer
--- @param item table
--- @param page_path string
--- @param stamp string
local function schedule_session_page_render(session, i, item, page_path, stamp)
  local page_state = session.page_state[i] or {}
  session.page_state[i] = page_state
  local request = is_active_request_page(session, i) and session.current_request or nil
  vim.schedule(function()
    local current = get_watch_session(session.bufnr, session.kind)
    if current ~= session then
      return
    end
    if request ~= nil then
      if session.current_request ~= request or request.status ~= "active" then
        return
      end
      local job = request.jobs[i]
      if job == nil then
        return
      end
      if on_request_page_rendered(session, request, i, job, page_path, stamp) then
        page_state.rendered = stamp
        session.page_state[i] = page_state
        refresh_session_poll_interval(session)
      end
      return
    end

    local before_item = state.get_item_by_image_id(item.image_id)
    local before_stamp = before_item and before_item.page_stamp or nil
    on_page_rendered(session.bufnr, page_path, item.image_id, item.extmark_id, item.range, stamp)
    local after_item = state.get_item_by_image_id(item.image_id)
    if after_item ~= nil and after_item.page_stamp == stamp and before_stamp ~= stamp then
      page_state.rendered = stamp
      session.page_state[i] = page_state
      refresh_session_poll_interval(session)
    end
  end)
end

--- Attempt to render page i of session.
--- First paint goes through immediately once the file exists and is non-empty.
--- Subsequent updates still require two consecutive equal stamps.
--- @param session typst_watch_session
--- @param i       integer
--- @param item    table
try_render_session_page = function(session, i, item)
  if item == nil or item.image_id == nil or item.render_target == "preview_tail_inactive" then
    return
  end
  if item.extmark_id == nil and not is_active_request_page(session, i) then
    return
  end
  local page_path = session.output_prefix .. "-" .. i .. ".png"
  local stat = vim.uv.fs_stat(page_path)
  if stat == nil or stat.size == 0 then
    return
  end

  local stamp = tostring(stat.mtime.sec) .. ":" .. tostring(stat.mtime.nsec) .. ":" .. tostring(stat.size)
  local page_state = session.page_state[i] or {}

  -- First paint fast path: try immediately once a non-empty page appears.
  if page_state.rendered == nil and page_state.last_seen == nil then
    page_state.last_seen = stamp
    session.page_state[i] = page_state
    schedule_session_page_render(session, i, item, page_path, stamp)
    return
  end

  -- Subsequent updates stay conservative and wait for a repeated stamp.
  if page_state.last_seen ~= stamp then
    page_state.last_seen = stamp
    session.page_state[i] = page_state
    return
  end

  if page_state.rendered == stamp then
    return
  end
  schedule_session_page_render(session, i, item, page_path, stamp)
end

--- @param session typst_watch_session
local function ensure_session_poller(session)
  if session.poll_timer ~= nil and not session.poll_timer:is_closing() then
    return
  end
  session.poll_timer = vim.uv.new_timer()
  session.poll_interval_ms = nil
  refresh_session_poll_interval(session)
end

--- Start or reuse a `typst watch` session for bufnr.
--- @param bufnr integer
--- @return typst_watch_session|nil
function M.ensure_watch_session(bufnr)
  local kind = "full"
  local existing = get_watch_session(bufnr, kind)
  if existing ~= nil and existing.handle ~= nil and not existing.dead then
    return existing
  end

  local main = require("typst-concealer")
  local config = main.config
  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()

  local path_rewrite = require("typst-concealer.path-rewrite")
  local project_scope = require("typst-concealer.project-scope").resolve(bufnr, kind)
  local buf_dir = project_scope.buf_dir
  local source_root = project_scope.source_root
  local effective_root = project_scope.effective_root
  -- Strip any --root from compiler_args (typst rejects duplicates). Source root
  -- comes only from get_root or project auto-detection.
  local filtered_compiler_args = {}
  if config.compiler_args then
    local i = 1
    while i <= #config.compiler_args do
      local arg = config.compiler_args[i]
      if arg == "--root" and i + 1 <= #config.compiler_args then
        i = i + 2
      elseif arg:sub(1, 7) == "--root=" then
        i = i + 1
      else
        filtered_compiler_args[#filtered_compiler_args + 1] = arg
        i = i + 1
      end
    end
  end

  local input_path = session_input_path(bufnr, source_root)
  local template, prefix = session_output_template(bufnr)
  local preview_sidecar_path = session_preview_sidecar_path(bufnr, source_root)

  local args = { "watch", input_path, template, "--ppi=" .. (state._render_ppi or config.ppi) }
  for _, arg in ipairs(filtered_compiler_args) do
    args[#args + 1] = arg
  end
  args[#args + 1] = "--root=" .. effective_root
  for _, s in ipairs(project_scope.inputs or {}) do
    args[#args + 1] = "--input"
    args[#args + 1] = s
  end

  -- typst watch expects the input file to exist before startup.
  local ok, err = write_file_in_place(input_path, main._styling_prelude)
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to create watch input: " .. tostring(err), vim.log.levels.ERROR)
    end)
    return nil
  end

  local preview_sidecar_root_relative_path = path_rewrite.encode_root_relative(preview_sidecar_path, effective_root)
  local preamble_include_line = resolve_preamble_include_line(bufnr, effective_root, kind)
  local ok_preview, preview_err = write_preview_sidecar({
    bufnr = bufnr,
    buf_dir = buf_dir,
    source_root = source_root,
    effective_root = effective_root,
    preview_sidecar_path = preview_sidecar_path,
    prelude_chunks = {},
    last_preview_sidecar_text = nil,
  }, nil)
  if not ok_preview then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to create preview sidecar: " .. tostring(preview_err), vim.log.levels.ERROR)
    end)
    return nil
  end

  local session = {
    kind = kind,
    bufnr = bufnr,
    project_scope_id = project_scope.project_scope_id,
    handle = nil,
    stdout = stdout,
    stderr = stderr,
    input_path = input_path,
    output_prefix = prefix,
    output_template = template,
    poll_timer = nil,
    items = {},
    base_items = {},
    preview_tail_item = nil,
    preview_sidecar_item = nil,
    preview_sidecar_path = preview_sidecar_path,
    preview_sidecar_root_relative_path = preview_sidecar_root_relative_path,
    preamble_include_line = preamble_include_line,
    preview_active = false,
    prelude_chunks = {},
    page_state = {},
    render_start_index = 1,
    poll_interval_ms = nil,
    last_page_count = 0,
    last_input_text = nil,
    last_input_write_count = 0,
    last_preview_sidecar_text = nil,
    wrapper_cache = {
      item_fragments = {},
    },
    current_request = nil,
    line_map = nil,
    stderr_chunks = {},
    stderr_text = "",
    stderr_line_buffer = "",
    stderr_debounce = nil,
    dead = false,
    buf_dir = buf_dir,
    source_root = source_root,
    effective_root = effective_root,
  }
  session.preview_tail_item = make_preview_tail_item(session, nil)

  local handle
  handle = vim.uv.spawn(config.typst_location, {
    stdio = { nil, stdout, stderr },
    args = args,
  }, function()
    session.dead = true
    if session.stderr_line_buffer and session.stderr_line_buffer ~= "" then
      session.stderr_text = (session.stderr_text or "") .. session.stderr_line_buffer
      session.stderr_line_buffer = ""
    end
    if config.do_diagnostics then
      update_quickfix_from_stderr(session)
    end
    if session.stderr_debounce and not session.stderr_debounce:is_closing() then
      session.stderr_debounce:stop()
      session.stderr_debounce:close()
      session.stderr_debounce = nil
    end
    if session.poll_timer and not session.poll_timer:is_closing() then
      session.poll_timer:stop()
      session.poll_timer:close()
      session.poll_timer = nil
    end
    if stdout and not stdout:is_closing() then
      stdout:close()
    end
    if stderr and not stderr:is_closing() then
      stderr:close()
    end
    if handle and not handle:is_closing() then
      handle:close()
    end
  end)

  if handle == nil then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to spawn typst watch", vim.log.levels.ERROR)
    end)
    return nil
  end

  session.handle = handle

  stdout:read_start(function() end)
  stderr:read_start(function(err2, data)
    if err2 ~= nil then
      return
    end
    if not config.do_diagnostics then
      return
    end
    if data ~= nil and data ~= "" then
      session.stderr_line_buffer = (session.stderr_line_buffer or "") .. data
      while true do
        local nl = session.stderr_line_buffer:find("\n", 1, true)
        if nl == nil then
          break
        end
        local line = session.stderr_line_buffer:sub(1, nl)
        session.stderr_text = (session.stderr_text or "") .. line
        session.stderr_line_buffer = session.stderr_line_buffer:sub(nl + 1)
      end

      if session.stderr_debounce == nil or session.stderr_debounce:is_closing() then
        session.stderr_debounce = vim.uv.new_timer()
      end
      session.stderr_debounce:stop()
      session.stderr_debounce:start(
        120,
        0,
        vim.schedule_wrap(function()
          local current = get_watch_session(bufnr, kind)
          if current ~= session or session.dead then
            return
          end
          update_quickfix_from_stderr(session)
        end)
      )
    end
  end)

  state.watch_sessions[bufnr] = state.watch_sessions[bufnr] or {}
  state.watch_sessions[bufnr][kind] = session
  ensure_session_poller(session)
  return session
end

--- Report whether a compiler service exists and is still alive.
--- @param bufnr integer
--- @return boolean
function M.has_compiler_service(bufnr)
  local bucket = state.compiler_services and state.compiler_services[bufnr]
  local service = bucket and bucket.full or nil
  return service ~= nil and service.dead ~= true
end

--- @param bufnr integer
--- @return table
local function get_service_bucket(bufnr)
  state.compiler_services = state.compiler_services or {}
  state.compiler_services[bufnr] = state.compiler_services[bufnr] or {}
  return state.compiler_services[bufnr]
end

--- @param bufnr integer
--- @param kind '"full"'|'"preview"'
--- @return typst_compiler_service|nil
get_compiler_service = function(bufnr, kind)
  local bucket = state.compiler_services and state.compiler_services[bufnr]
  return bucket and bucket[kind] or nil
end

local function close_pipe(pipe)
  if pipe ~= nil and not pipe:is_closing() then
    pipe:close()
  end
end

--- Start or reuse the Rust compiler service for bufnr.
--- @param bufnr integer
--- @param kind '"full"'|'"preview"'|nil
--- @return typst_compiler_service|nil
function M.ensure_compiler_service(bufnr, kind)
  kind = kind or "full"
  local bucket = get_service_bucket(bufnr)
  local existing = bucket[kind]
  if existing ~= nil and existing.dead ~= true then
    return existing
  end

  local main = require("typst-concealer")
  local service_path = main.config.service_binary or "typst-concealer-service"
  local stdin = vim.uv.new_pipe()
  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()
  local service
  local handle

  handle = vim.uv.spawn(service_path, {
    stdio = { stdin, stdout, stderr },
    args = {},
  }, function()
    if service ~= nil then
      service.dead = true
      local inflight_request_id = service.inflight and service.inflight.request_id or nil
      local pending_full = service.pending_full_request
      local pending_preview = service.pending_preview_request
      service.inflight = nil
      service.pending_full_request = nil
      service.pending_preview_request = nil
      service.pending_prewarm_requests = nil
      vim.schedule(function()
        mark_inflight_service_request_failed(bufnr, inflight_request_id, "compiler service exited")
        mark_service_payload_failed(bufnr, pending_full, "compiler service exited")
        mark_service_payload_failed(bufnr, pending_preview, "compiler service exited")
      end)
    end
    local current_bucket = state.compiler_services and state.compiler_services[bufnr]
    if current_bucket ~= nil and current_bucket[kind] == service then
      current_bucket[kind] = nil
      if next(current_bucket) == nil then
        state.compiler_services[bufnr] = nil
      end
    end
    close_pipe(stdin)
    close_pipe(stdout)
    close_pipe(stderr)
    if handle ~= nil and not handle:is_closing() then
      handle:close()
    end
  end)

  if handle == nil then
    close_pipe(stdin)
    close_pipe(stdout)
    close_pipe(stderr)
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to spawn compiler service: " .. service_path, vim.log.levels.ERROR)
    end)
    return nil
  end

  service = {
    handle = handle,
    stdin = stdin,
    stdout = stdout,
    stderr = stderr,
    bufnr = bufnr,
    kind = kind,
    dead = false,
    line_buffer = "",
    stderr_line_buffer = "",
    cache_dir = nil,
  }

  stdout:read_start(function(err, data)
    if err ~= nil or data == nil then
      return
    end
    service.line_buffer = service.line_buffer .. data
    while true do
      local nl = service.line_buffer:find("\n", 1, true)
      if nl == nil then
        break
      end
      local line = service.line_buffer:sub(1, nl - 1)
      service.line_buffer = service.line_buffer:sub(nl + 1)
      if line ~= "" then
        -- Decode JSON in the UV callback to keep the main-thread work minimal.
        local decode_ok, resp = pcall(vim.json.decode, line)
        if decode_ok and type(resp) == "table" then
          vim.schedule(function()
            on_service_response(bufnr, kind, resp)
          end)
        end
      end
    end
  end)

  stderr:read_start(function(err, data)
    if err ~= nil or data == nil or data == "" then
      return
    end
    service.stderr_line_buffer = (service.stderr_line_buffer or "") .. data
    while true do
      local nl = service.stderr_line_buffer:find("\n", 1, true)
      if nl == nil then
        break
      end
      local line = vim.trim(service.stderr_line_buffer:sub(1, nl - 1))
      service.stderr_line_buffer = service.stderr_line_buffer:sub(nl + 1)
      if line ~= "" then
        vim.schedule(function()
          vim.notify("[typst-concealer-service] " .. line, vim.log.levels.WARN)
        end)
      end
    end
  end)

  bucket[kind] = service
  return service
end

--- @param project_scope table
--- @param kind '"full"'|'"preview"'
--- @return string
service_cache_key = function(project_scope, kind)
  return table.concat({
    kind,
    tostring(project_scope.project_scope_id or ""),
    tostring(project_scope.effective_root or ""),
  }, ":")
end

--- @param prelude_chunks string[]
--- @param prelude_count integer
--- @return string
local function preview_prelude_signature(prelude_chunks, prelude_count)
  local parts = { tostring(prelude_count) }
  for i = 1, prelude_count do
    parts[#parts + 1] = prelude_chunks[i] or ""
  end
  return table.concat(parts, "\0")
end

--- Build the stable preview main document and sidecar metadata for one
--- prelude/wrapper context.  The main document intentionally contains only the
--- global document context plus an include of the context-owned sidecar; the
--- sidecar itself contains the runtime prelude, wrapper, and current formula.
--- @param bufnr integer
--- @param service typst_compiler_service
--- @param item table
--- @param project_scope table
--- @param prelude_chunks string[]
--- @param preamble_include_line string
--- @return table|nil
local function build_preview_service_spec(bufnr, service, item, project_scope, prelude_chunks, preamble_include_line)
  local main = require("typst-concealer")
  local config = main.config
  local wrapper = require("typst-concealer.wrapper")

  local prelude_count = math.max(0, math.min(item.prelude_count or 0, #prelude_chunks))
  local probe_item = vim.deepcopy(item)
  probe_item.prelude_count = prelude_count
  probe_item.range = probe_item.range or { 0, 0, 0, 0 }
  probe_item.node_type = probe_item.node_type or "math"
  probe_item.semantics = probe_item.semantics or { display_kind = "inline", constraint_kind = "intrinsic" }

  local source_rows = item_source_rows(probe_item)
  local wrap_prefix, wrap_suffix = wrapper.build_wrapper(probe_item, source_rows)
  local context_text = table.concat({
    project_scope.buf_dir or "",
    project_scope.source_root or "",
    project_scope.effective_root or "",
    tostring(state._cell_px_w or ""),
    tostring(state._cell_px_h or ""),
    tostring(state._render_ppi or config.ppi or ""),
    config.header or "",
    main._styling_prelude or "",
    preamble_include_line or "",
    preview_prelude_signature(prelude_chunks, prelude_count),
    tostring(probe_item.node_type or ""),
    tostring(probe_item.semantics and probe_item.semantics.constraint_kind or ""),
    tostring(probe_item.semantics and probe_item.semantics.display_kind or ""),
    tostring(source_rows),
    wrap_prefix,
    wrap_suffix,
  }, "\0")
  local context_hash = stable_hash(context_text)

  local cache_dir = get_cache_dir(bufnr, project_scope.source_root)
  local sidecar_path = cache_dir .. "/.typst-concealer-preview-" .. context_hash .. ".typ"
  local sidecar_root_relative_path =
    require("typst-concealer.path-rewrite").encode_root_relative(sidecar_path, project_scope.effective_root)

  local include_item = vim.deepcopy(probe_item)
  include_item.str = '#include "' .. sidecar_root_relative_path .. '"\n'
  include_item.source_str = nil
  include_item.source_text = nil
  include_item.prelude_count = 0
  include_item.skip_wrapper = true

  service._preview_wrapper_caches = service._preview_wrapper_caches or {}
  service._preview_wrapper_caches[context_hash] = service._preview_wrapper_caches[context_hash]
    or { item_fragments = {} }
  local doc_str = wrapper.build_batch_document(
    { include_item },
    project_scope.buf_dir,
    project_scope.source_root,
    project_scope.effective_root,
    "full",
    prelude_chunks,
    preamble_include_line,
    false,
    service._preview_wrapper_caches[context_hash]
  )

  return {
    context_hash = context_hash,
    cache_key = service_cache_key(project_scope, "preview") .. ":" .. context_hash,
    cache_dir = cache_dir,
    source_text = doc_str,
    sidecar_path = sidecar_path,
    sidecar_text = build_preview_service_sidecar_source(probe_item, project_scope, prelude_chunks),
  }
end

--- @param item table|nil
--- @param bufnr integer
--- @param prelude_chunks string[]
--- @return table
local function make_preview_prewarm_item(item, bufnr, prelude_chunks)
  local out = item ~= nil and vim.deepcopy(item) or {}
  out.bufnr = out.bufnr or bufnr
  out.range = out.range and vim.deepcopy(out.range) or { 0, 0, 0, 3 }
  out.str = "$x$"
  out.source_str = "$x$"
  out.source_text = "$x$"
  out.prelude_count = out.prelude_count or #prelude_chunks
  out.node_type = out.node_type or "math"
  out.semantics = out.semantics or { display_kind = "inline", constraint_kind = "intrinsic" }
  out.request_id = nil
  out.preview_request_id = nil
  out.image_id = nil
  out.extmark_id = nil
  return out
end

--- @param bufnr integer
--- @param payload table|nil
--- @param reason string
local function mark_service_payload_failed(bufnr, payload, reason)
  if payload == nil then
    return
  end
  if payload.kind == "full" then
    local meta = payload.meta
    if meta == nil and state.active_service_requests then
      local active = state.active_service_requests[bufnr]
      if active ~= nil and active.request_id == payload.request_id then
        meta = active
      end
    end
    fail_full_service_request(bufnr, meta, reason)
  elseif payload.kind == "preview" and payload.is_prewarm ~= true then
    local active = state.active_preview_service_requests and state.active_preview_service_requests[bufnr]
    if active ~= nil and active.request_id == payload.request_id then
      state.active_preview_service_requests[bufnr] = nil
    end
  end
end

--- @param bufnr integer
--- @param request_id string|nil
--- @param reason string
local function mark_inflight_service_request_failed(bufnr, request_id, reason)
  if request_id == nil then
    return
  end
  local meta = state.active_service_requests and state.active_service_requests[bufnr]
  if meta ~= nil and meta.request_id == request_id then
    fail_full_service_request(bufnr, meta, reason)
  end
  local preview = state.active_preview_service_requests and state.active_preview_service_requests[bufnr]
  if preview ~= nil and preview.request_id == request_id then
    state.active_preview_service_requests[bufnr] = nil
  end
end

--- @param service typst_compiler_service
--- @param payload table
--- @return boolean
local function write_service_payload(service, payload)
  if service == nil or service.dead == true or service.stdin == nil or service.stdin:is_closing() then
    return false
  end
  if payload.prepare ~= nil then
    local ok, err = payload.prepare()
    if not ok then
      if payload.on_prepare_failed ~= nil then
        payload.on_prepare_failed(err)
      end
      vim.schedule(function()
        vim.notify("[typst-concealer] failed to prepare compiler request: " .. tostring(err), vim.log.levels.ERROR)
      end)
      return false
    end
  end

  local sent_at = vim.uv.hrtime()
  service.inflight = {
    kind = payload.kind,
    request_id = payload.request_id,
    is_prewarm = payload.is_prewarm == true,
    preview_context_hash = payload.preview_context_hash,
  }
  if payload.meta ~= nil then
    payload.meta.sent_at = sent_at
  end

  service.stdin:write(payload.message .. "\n", function(err)
    if err ~= nil then
      if service.inflight ~= nil and service.inflight.request_id == payload.request_id then
        service.inflight = nil
      end
      vim.schedule(function()
        mark_service_payload_failed(service.bufnr, payload, "stdin write failed")
        vim.notify("[typst-concealer] failed to write compiler request: " .. tostring(err), vim.log.levels.ERROR)
        if send_next_service_payload ~= nil then
          send_next_service_payload(service)
        end
      end)
    end
  end)
  return true
end

--- @param bufnr integer
--- @param service typst_compiler_service
--- @param payload table
local function send_or_queue_service_payload(bufnr, service, payload)
  if service.inflight ~= nil then
    if payload.is_prewarm == true then
      service.preview_warmed_signatures = service.preview_warmed_signatures or {}
      if service.preview_warmed_signatures[payload.preview_context_hash] then
        return true
      end
      if service.inflight.preview_context_hash == payload.preview_context_hash then
        return true
      end
      service.pending_prewarm_requests = service.pending_prewarm_requests or {}
      for _, pending in ipairs(service.pending_prewarm_requests) do
        if pending.preview_context_hash == payload.preview_context_hash then
          return true
        end
      end
      service.pending_prewarm_requests[#service.pending_prewarm_requests + 1] = payload
    elseif payload.kind == "preview" then
      service.pending_preview_request = payload
    else
      if service.pending_full_request ~= nil then
        supersede_full_service_request(bufnr, service.pending_full_request.meta, "pending full request superseded")
      end
      service.pending_full_request = payload
    end
    return true
  end

  return write_service_payload(service, payload)
end

--- @param bufnr integer
--- @param service_kind '"full"'|'"preview"'
--- @param request_id string
send_next_service_payload = function(service)
  if service == nil then
    return
  end
  local payload = service.pending_full_request or service.pending_preview_request
  service.pending_full_request = nil
  service.pending_preview_request = nil
  if payload == nil and service.pending_prewarm_requests ~= nil then
    payload = table.remove(service.pending_prewarm_requests, 1)
    if #service.pending_prewarm_requests == 0 then
      service.pending_prewarm_requests = nil
    end
  end
  if payload ~= nil then
    local sent = write_service_payload(service, payload)
    if not sent then
      mark_service_payload_failed(service.bufnr, payload, "failed to send queued compiler request")
      send_next_service_payload(service)
    end
  end
end

--- @param bufnr integer
--- @param service_kind '"full"'|'"preview"'
--- @param request_id string
finish_service_response = function(bufnr, service_kind, request_id)
  local service = get_compiler_service(bufnr, service_kind)
  if service == nil then
    return
  end
  if service.inflight ~= nil and service.inflight.request_id == request_id then
    service.inflight = nil
  end
  send_next_service_payload(service)
end

--- @param bufnr integer
--- @param service typst_compiler_service|nil
--- @param jobs table[]|nil
--- @param project_scope table
--- @param config table
--- @param prelude_chunks string[]
--- @param preamble_include_line string
local function prewarm_preview_service(
  bufnr,
  service,
  jobs,
  project_scope,
  config,
  prelude_chunks,
  preamble_include_line
)
  if service == nil or service.dead == true then
    return
  end

  local inputs = extract_service_inputs(config, project_scope)
  local candidates = {}
  if jobs ~= nil and #jobs > 0 then
    for _, job in ipairs(jobs) do
      candidates[#candidates + 1] = make_preview_prewarm_item(job, bufnr, prelude_chunks)
    end
  else
    candidates[#candidates + 1] = make_preview_prewarm_item(nil, bufnr, prelude_chunks)
  end

  service.preview_warmed_signatures = service.preview_warmed_signatures or {}
  local seen = {}
  for _, item in ipairs(candidates) do
    local spec = build_preview_service_spec(bufnr, service, item, project_scope, prelude_chunks, preamble_include_line)
    if spec ~= nil and not seen[spec.context_hash] then
      seen[spec.context_hash] = true
      if not service.preview_warmed_signatures[spec.context_hash] then
        local request_id = ("preview-prewarm:%d:%s"):format(bufnr, spec.context_hash)
        local ok, msg = pcall(vim.json.encode, {
          type = "compile",
          request_id = request_id,
          cache_key = spec.cache_key,
          source_text = spec.source_text,
          root = project_scope.effective_root,
          inputs = inputs,
          output_dir = spec.cache_dir,
          ppi = state._render_ppi or config.ppi,
        })
        if ok then
          service.cache_dir = spec.cache_dir
          state.service_cache_dirs = state.service_cache_dirs or {}
          state.service_cache_dirs[bufnr] = spec.cache_dir
          send_or_queue_service_payload(bufnr, service, {
            kind = "preview",
            request_id = request_id,
            message = msg,
            is_prewarm = true,
            preview_context_hash = spec.context_hash,
            prepare = make_preview_sidecar_prepare(service, spec.sidecar_path, spec.sidecar_text),
          })
        else
          vim.schedule(function()
            vim.notify(
              "[typst-concealer] failed to encode preview prewarm request: " .. tostring(msg),
              vim.log.levels.ERROR
            )
          end)
        end
      end
    end
  end
end

--- Stop a Rust compiler service and remove service-generated PNGs.
--- @param bufnr integer
--- @param kind '"full"'|'"preview"'|nil
function M.stop_compiler_service(bufnr, kind)
  local bucket = state.compiler_services and state.compiler_services[bufnr]
  if bucket == nil then
    cleanup_service_cache_dir(state.service_cache_dirs and state.service_cache_dirs[bufnr])
    M._cleanup_service_workspace_for_buf(bufnr)
    if state.service_cache_dirs then
      state.service_cache_dirs[bufnr] = nil
    end
    return
  end

  local kinds = kind and { kind } or { "full", "preview" }
  for _, service_kind in ipairs(kinds) do
    local service = bucket[service_kind]
    if service ~= nil then
      service.dead = true
      bucket[service_kind] = nil

      if service_kind == "full" and state.active_service_requests and state.active_service_requests[bufnr] then
        supersede_full_service_request(bufnr, state.active_service_requests[bufnr], "compiler service stopped")
      end
      if service_kind == "preview" and state.active_preview_service_requests then
        state.active_preview_service_requests[bufnr] = nil
      end

      mark_service_payload_failed(bufnr, service.pending_full_request, "compiler service stopped")
      mark_service_payload_failed(bufnr, service.pending_preview_request, "compiler service stopped")
      service.inflight = nil
      service.pending_full_request = nil
      service.pending_preview_request = nil
      service.pending_prewarm_requests = nil

      if service.stdin ~= nil and not service.stdin:is_closing() then
        service.stdin:write(vim.json.encode({ type = "shutdown" }) .. "\n")
      end

      close_pipe(service.stdin)
      close_pipe(service.stdout)
      close_pipe(service.stderr)
      if service.handle ~= nil and not service.handle:is_closing() then
        service.handle:kill(15)
        service.handle:close()
      end
    end
  end

  if next(bucket) == nil then
    if state.compiler_services then
      state.compiler_services[bufnr] = nil
    end
    cleanup_service_cache_dir(state.service_cache_dirs and state.service_cache_dirs[bufnr])
    M._cleanup_service_workspace_for_buf(bufnr)
    if state.service_cache_dirs then
      state.service_cache_dirs[bufnr] = nil
    end
  end
end

--- Send a batch of items to the full watch session for rendering.
--- @param bufnr integer
--- @param items table[]
function M.render_items_via_watch(bufnr, items)
  local session = M.ensure_watch_session(bufnr)
  if session == nil then
    return
  end
  if session.current_request ~= nil then
    session.current_request.status = "abandoned"
    session.current_request = nil
  end
  session.base_items = items or {}
  session.prelude_chunks = snapshot_full_context_preludes(bufnr)
  if session.preview_active and session.preview_sidecar_item ~= nil then
    session.preview_tail_item = make_preview_tail_item(session, session.preview_sidecar_item)
  else
    session.preview_tail_item = make_preview_tail_item(session, nil)
  end
  local ok_preview, preview_err = write_preview_sidecar(session, session.preview_sidecar_item)
  if not ok_preview then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to refresh preview sidecar: " .. tostring(preview_err), vim.log.levels.ERROR)
    end)
  end
  session.render_start_index = 1
  write_session_document(session, "full")
  refresh_session_poll_interval(session)
end

--- Send a machine-owned full render request to the compiler service.
--- @param bufnr integer
--- @param request RenderRequest
function M.render_request_via_service(bufnr, request)
  local early_meta = build_render_request_meta(request)
  local service = M.ensure_compiler_service(bufnr, "full")
  if service == nil or service.stdin == nil or service.stdin:is_closing() then
    fail_full_service_request(bufnr, early_meta, "compiler service unavailable")
    return
  end
  -- Start the preview backend with the same buffer/project lifetime so the
  -- first cursor preview does not pay process startup while full rendering is
  -- busy. It compiles only preview requests, so it cannot block full updates.
  local preview_service = M.ensure_compiler_service(bufnr, "preview")

  local project_scope = require("typst-concealer.project-scope").resolve(bufnr, "full")
  local main = require("typst-concealer")
  local config = main.config
  local prelude_chunks = snapshot_full_context_preludes(bufnr)
  local preamble_include_line = resolve_preamble_include_line(bufnr, project_scope.effective_root, "full")
  local spec = build_full_service_spec(request, project_scope, prelude_chunks, preamble_include_line, config)
  service.cache_dir = spec.output_dir
  state.service_cache_dirs = state.service_cache_dirs or {}
  state.service_cache_dirs[bufnr] = spec.output_dir
  state.service_workspace_dirs = state.service_workspace_dirs or {}
  state.service_workspace_dirs[bufnr] = spec.workspace.root

  local current_request = build_render_request_meta(request)
  current_request.line_map = nil
  current_request.slot_line_maps = spec.slot_line_maps
  current_request.generated_slot_paths = spec.generated_slot_paths
  current_request.project_scope_id = project_scope.project_scope_id or current_request.project_scope_id
  current_request.buf_dir = project_scope.buf_dir
  current_request.source_root = project_scope.source_root
  current_request.effective_root = project_scope.effective_root
  current_request.generated_input_path = spec.generated_input_path
  current_request.generated_context_path = spec.generated_context_path

  local old = state.active_service_requests and state.active_service_requests[bufnr]
  if old ~= nil then
    old.status = "abandoned"
  end
  state.active_service_requests = state.active_service_requests or {}
  current_request.queued_at = vim.uv.hrtime()
  state.active_service_requests[bufnr] = current_request

  if config.do_diagnostics then
    clear_quickfix(bufnr, "full")
  end

  local inputs = extract_service_inputs(config, project_scope)

  local ok, msg = pcall(vim.json.encode, {
    type = "compile",
    request_id = request.request_id,
    cache_key = spec.cache_key,
    source_text = spec.source_text,
    root = project_scope.effective_root,
    inputs = inputs,
    output_dir = spec.output_dir,
    ppi = state._render_ppi or config.ppi,
  })
  if not ok then
    fail_full_service_request(bufnr, current_request, "failed to encode compiler request")
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to encode compiler request: " .. tostring(msg), vim.log.levels.ERROR)
    end)
    return
  end

  local sent = send_or_queue_service_payload(bufnr, service, {
    kind = "full",
    request_id = request.request_id,
    message = msg,
    meta = current_request,
    prepare = make_full_sidecar_prepare(service, spec.writes),
    on_prepare_failed = function(err)
      fail_full_service_request(bufnr, current_request, "failed to prepare sidecars: " .. tostring(err))
    end,
  })
  if not sent then
    fail_full_service_request(bufnr, current_request, "failed to send compiler request")
    return
  end

  prewarm_preview_service(
    bufnr,
    preview_service,
    request.jobs,
    project_scope,
    config,
    prelude_chunks,
    preamble_include_line
  )
end

--- Send a preview item to the compiler service for rendering.
--- @param bufnr integer
--- @param item table  preview item from allocate_preview_item
function M.render_preview_tail_via_service(bufnr, item)
  local service = M.ensure_compiler_service(bufnr, "preview")
  if service == nil or service.stdin == nil or service.stdin:is_closing() then
    return
  end

  local project_scope = require("typst-concealer.project-scope").resolve(bufnr, "full")
  local main = require("typst-concealer")
  local config = main.config
  local prelude_chunks = snapshot_full_context_preludes(bufnr)
  local preamble_include_line = resolve_preamble_include_line(bufnr, project_scope.effective_root, "full")
  local spec = build_preview_service_spec(bufnr, service, item, project_scope, prelude_chunks, preamble_include_line)
  if spec == nil then
    return
  end

  local request_id = item.preview_request_id
  if request_id == nil then
    return
  end

  -- Track the preview request so the response handler can route it.
  state.active_preview_service_requests = state.active_preview_service_requests or {}
  local preview_meta = {
    request_id = request_id,
    item = item,
    queued_at = vim.uv.hrtime(),
  }
  state.active_preview_service_requests[bufnr] = preview_meta

  local inputs = extract_service_inputs(config, project_scope)
  service.cache_dir = spec.cache_dir
  state.service_cache_dirs = state.service_cache_dirs or {}
  state.service_cache_dirs[bufnr] = spec.cache_dir

  local ok, msg = pcall(vim.json.encode, {
    type = "compile",
    request_id = request_id,
    cache_key = spec.cache_key,
    source_text = spec.source_text,
    root = project_scope.effective_root,
    inputs = inputs,
    output_dir = spec.cache_dir,
    ppi = state._render_ppi or config.ppi,
  })
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to encode preview request: " .. tostring(msg), vim.log.levels.ERROR)
    end)
    return
  end

  local sent = send_or_queue_service_payload(bufnr, service, {
    kind = "preview",
    request_id = request_id,
    message = msg,
    meta = preview_meta,
    preview_context_hash = spec.context_hash,
    prepare = make_preview_sidecar_prepare(service, spec.sidecar_path, spec.sidecar_text),
    on_prepare_failed = function()
      local active = state.active_preview_service_requests and state.active_preview_service_requests[bufnr]
      if active ~= nil and active.request_id == request_id then
        state.active_preview_service_requests[bufnr] = nil
      end
    end,
  })
  if not sent then
    state.active_preview_service_requests[bufnr] = nil
  end
end

--- Send a machine-owned full render request to the watch session.
--- @param bufnr integer
--- @param request RenderRequest
function M.render_request_via_watch(bufnr, request)
  local session = M.ensure_watch_session(bufnr)
  if session == nil then
    return
  end

  local current_request = replace_current_request(session, request)
  clear_request_output_pages(session, current_request.page_count)
  -- Rewriting the same Typst document is still required after clearing pages:
  -- watch only regenerates the fixed output paths when the input file changes.
  session.last_input_text = nil
  session.base_items = current_request.jobs
  session.prelude_chunks = snapshot_full_context_preludes(bufnr)
  if session.preview_active and session.preview_sidecar_item ~= nil then
    session.preview_tail_item = make_preview_tail_item(session, session.preview_sidecar_item)
  else
    session.preview_tail_item = make_preview_tail_item(session, nil)
  end
  local ok_preview, preview_err = write_preview_sidecar(session, session.preview_sidecar_item)
  if not ok_preview then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to refresh preview sidecar: " .. tostring(preview_err), vim.log.levels.ERROR)
    end)
  end
  session.render_start_index = 1
  write_session_document(session, "full")
  refresh_session_poll_interval(session)
end

--- Mark an in-flight machine request as abandoned if it is still current.
--- @param bufnr integer
--- @param old_request_id string
--- @param _new_request_id string
function M.abandon_request(bufnr, old_request_id, _new_request_id)
  local session = get_watch_session(bufnr, "full")
  if session == nil or session.current_request == nil then
    return
  end
  if session.current_request.request_id == old_request_id then
    session.current_request.status = "abandoned"
  end
end

--- Update the transient preview tail page on the full watch session.
--- @param bufnr integer
--- @param item table
function M.render_preview_tail(bufnr, item)
  local session = get_watch_session(bufnr, "full")
  if session == nil or #(session.base_items or {}) == 0 then
    return
  end

  session.preview_sidecar_item = vim.deepcopy(item)
  local ok, err = write_preview_sidecar(session, session.preview_sidecar_item)
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to update preview sidecar: " .. tostring(err), vim.log.levels.ERROR)
    end)
    return
  end

  session.preview_active = true
  session.preview_tail_item = make_preview_tail_item(session, item)
  if full_pages_have_stable_renders(session) then
    session.render_start_index = #session.base_items + 1
  else
    session.render_start_index = 1
  end
  write_session_document(session, "preview")
  refresh_session_poll_interval(session)
end

--- Disable the transient preview tail page on the full watch session.
--- @param bufnr integer
function M.clear_preview_tail(bufnr)
  local session = get_watch_session(bufnr, "full")
  if session == nil then
    return
  end

  local had_preview = session.preview_active
  session.preview_active = false
  session.preview_sidecar_item = nil
  session.preview_tail_item = make_preview_tail_item(session, nil)
  local ok, err = write_preview_sidecar(session, nil)
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to clear preview sidecar: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end

  if had_preview then
    session.render_start_index = #session.base_items + 1
    write_session_document(session, "preview")
    refresh_session_poll_interval(session)
  end
end

return M
