--- Watch session management for typst-concealer.
--- Manages long-running `typst watch` processes, polling for rendered pages,
--- and calling into the extmark layer when a page is ready.
---
--- TypstBackend interface (current: Typst only)
---   M.render_items_via_watch(bufnr, items, kind)    dispatch items to a watch session
---   M.ensure_watch_session(bufnr, kind)             start/reuse a watch session
---   M.stop_watch_session(bufnr, kind)               kill and clean up a session
---   M.stop_watch_sessions_for_buf(bufnr)            kill the buffer session

local state = require("typst-concealer.state")
local M = {}

--- Generate quickfix title for all watch diagnostics belonging to a buffer.
--- @param bufnr integer
--- @return string
local function qf_title(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == nil or name == "" then
    name = ("buf:%d"):format(bufnr)
  end
  return ("typst-concealer: %s"):format(name)
end

--- Rebuild the global quickfix list for a buffer from active watch diagnostics.
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
      }
    end

    -- The error points into generated wrapper/prelude space rather than the
    -- original item body. Jump directly to the generated cache file so the
    -- user can inspect the real failing Typst source.
    return {
      filename = session.input_path,
      lnum = lnum,
      col = col,
      exact = true,
      generated = true,
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

--- Write debugging artifacts next to the generated watch input so path rewrite
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

local function get_buf_dir(bufnr)
  local buf_file = vim.api.nvim_buf_get_name(bufnr)
  if buf_file == nil or buf_file == "" then
    return vim.uv.cwd()
  end
  return vim.fn.fnamemodify(buf_file, ":h")
end

--- Returns (and creates) a per-buffer cache directory.
--- Prefer placing it inside source_root so generated watch inputs stay within
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

--- Generates the fixed input path for a watch session.
--- @param bufnr integer
--- @param kind  'full' | 'preview'
--- @param source_root string|nil
--- @return string
local function session_input_path(bufnr, kind, source_root)
  local dir = get_cache_dir(bufnr, source_root)
  local suffix = kind == "preview" and "-preview" or ""
  return dir .. "/.typst-concealer-" .. state.full_pid .. "-" .. bufnr .. suffix .. ".typ"
end

--- Generates the fixed output template/prefix for a watch session.
--- @param bufnr integer
--- @param kind  'full' | 'preview'
--- @return string template, string prefix
local function session_output_template(bufnr, kind)
  local suffix = kind == "preview" and "-preview" or ""
  local prefix = "/tmp/tty-graphics-protocol-typst-concealer-" .. state.full_pid .. "-" .. bufnr .. suffix
  return prefix .. "-{p}.png", prefix
end

local function get_watch_session(bufnr, kind)
  local bucket = state.watch_sessions[bufnr]
  return bucket and bucket[kind] or nil
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
end

--- Called when a rendered page file is stable and ready to display.
--- Looks up item.semantics for the swap / padding decisions.
--- @param bufnr          integer
--- @param page_path      string
--- @param image_id       integer
--- @param extmark_id     integer
--- @param original_range table
--- @param page_stamp     string
local function on_page_rendered(bufnr, page_path, image_id, extmark_id, original_range, page_stamp)
  local pngData = require("typst-concealer.png-lua")
  local extmark = require("typst-concealer.extmark")
  local kitty_codes = require("typst-concealer.kitty-codes")

  local item = state.get_item_by_image_id(image_id)
  if item == nil or type(extmark_id) ~= "number" then
    return
  end

  local target_bufnr = bufnr
  local target_range = original_range
  if item and item.render_target == "float" then
    target_bufnr = item.target_bufnr or bufnr
    target_range = item.target_range or original_range
  end
  if not vim.api.nvim_buf_is_valid(target_bufnr) then
    return
  end
  if state.image_id_to_extmark[image_id] ~= extmark_id then
    return
  end
  local ok_mark, mark =
    pcall(vim.api.nvim_buf_get_extmark_by_id, target_bufnr, state.ns_id, extmark_id, { details = true })
  if not ok_mark or mark == nil or #mark == 0 then
    return
  end
  if item.str ~= nil and range_to_string(item.bufnr, item.range) ~= item.str then
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

  if source_rows == 1 and natural_rows > 1 then
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

  if item ~= nil then
    item.natural_cols = natural_cols
    item.natural_rows = natural_rows
    item.source_rows = source_rows
    item.page_path = page_path
    item.page_stamp = page_stamp
  end

  -- Swap extmark to new range when the new image is ready.
  -- item.semantics drives the is_block decision (replaces display_as_block boolean).
  local bstate = state.buffer_render_state[bufnr]
  if bstate and bstate.full_items then
    for _, item in ipairs(bstate.full_items) do
      if item.image_id == image_id then
        if item.needs_swap then
          extmark.swap_extmark_to_range(bufnr, image_id, extmark_id, item.range, item.semantics)
          item.needs_swap = false
        end
        break
      end
    end
  end

  extmark.create_image(page_path, image_id, natural_cols, natural_rows)
  extmark.conceal_for_image_id(target_bufnr, image_id, natural_cols, natural_rows, source_rows)
  require("typst-concealer.render").hide_extmarks_at_cursor(bufnr)
  require("typst-concealer.render").render_live_typst_preview(bufnr)
end

--- Attempt to render page i of session if the file is stable (two consecutive equal stamps).
--- @param session typst_watch_session
--- @param i       integer
--- @param item    table
local function try_render_session_page(session, i, item)
  local page_path = session.output_prefix .. "-" .. i .. ".png"
  local stat = vim.uv.fs_stat(page_path)
  if stat == nil or stat.size == 0 then
    return
  end

  local stamp = tostring(stat.mtime.sec) .. ":" .. tostring(stat.mtime.nsec) .. ":" .. tostring(stat.size)
  local page_state = session.page_state[i] or {}

  -- First sighting: remember only, do not render yet
  if page_state.last_seen ~= stamp then
    page_state.last_seen = stamp
    session.page_state[i] = page_state
    return
  end

  -- Second consecutive sighting of same stamp: assume write is stable
  if page_state.rendered == stamp then
    return
  end
  page_state.rendered = stamp
  session.page_state[i] = page_state

  vim.schedule(function()
    local current = get_watch_session(session.bufnr, session.kind)
    if current ~= session then
      return
    end
    on_page_rendered(session.bufnr, page_path, item.image_id, item.extmark_id, item.range, stamp)
  end)
end

--- @param session typst_watch_session
local function ensure_session_poller(session)
  if session.poll_timer ~= nil and not session.poll_timer:is_closing() then
    return
  end
  session.poll_timer = vim.uv.new_timer()
  session.poll_timer:start(
    80,
    80,
    vim.schedule_wrap(function()
      if session.dead then
        return
      end
      for i, item in ipairs(session.items or {}) do
        try_render_session_page(session, i, item)
      end
    end)
  )
end

--- Start or reuse a `typst watch` session for bufnr.
--- @param bufnr integer
--- @param kind  'full'
--- @return typst_watch_session|nil
function M.ensure_watch_session(bufnr, kind)
  local existing = get_watch_session(bufnr, kind)
  if existing ~= nil and existing.handle ~= nil and not existing.dead then
    return existing
  end

  local main = require("typst-concealer")
  local config = main.config
  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()

  local path_rewrite = require("typst-concealer.path-rewrite")
  local buf_dir = get_buf_dir(bufnr)
  local project_root = path_rewrite.get_project_root(buf_dir)
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

  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fn.getcwd()
  local configured_root = nil
  if type(config.get_root) == "function" then
    local ok, result = pcall(config.get_root, bufnr, buf_path, cwd, kind)
    if ok and type(result) == "string" and result ~= "" then
      configured_root = result
    end
  end

  local source_root = normalize_root(configured_root or project_root)
  local input_path = session_input_path(bufnr, kind, source_root)
  local cache_base = vim.fn.fnamemodify(input_path, ":h")
  -- effective_root = common ancestor of the intended project root and the
  -- actual generated input directory. When the cache lives under source_root,
  -- this stays equal to source_root and preserves rooted-path semantics for
  -- real project files imported by context helpers.
  local base_root = source_root or project_root
  local effective_root = path_rewrite.common_ancestor(base_root, cache_base)
  local template, prefix = session_output_template(bufnr, kind)

  -- Collect extra --input pairs from get_inputs.
  local extra_inputs = {}
  if type(config.get_inputs) == "function" then
    local ok, result = pcall(config.get_inputs, bufnr, buf_path, cwd, kind)
    if ok and type(result) == "table" then
      extra_inputs = result
    end
  end

  local args = { "watch", input_path, template, "--ppi=" .. (state._render_ppi or config.ppi) }
  for _, arg in ipairs(filtered_compiler_args) do
    args[#args + 1] = arg
  end
  args[#args + 1] = "--root=" .. effective_root
  for _, s in ipairs(extra_inputs) do
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

  local session = {
    kind = kind,
    bufnr = bufnr,
    handle = nil,
    stdout = stdout,
    stderr = stderr,
    input_path = input_path,
    output_prefix = prefix,
    output_template = template,
    poll_timer = nil,
    items = {},
    page_state = {},
    last_page_count = 0,
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

--- Send a batch of items to a watch session for rendering.
--- @param bufnr integer
--- @param items table[]
--- @param kind  'full'
function M.render_items_via_watch(bufnr, items, kind)
  if #items == 0 then
    M.stop_watch_session(bufnr, kind)
    return
  end

  local session = M.ensure_watch_session(bufnr, kind)
  if session == nil then
    return
  end
  session.items = items
  session.page_state = {}
  session.line_map = nil
  session.last_page_count = #items
  clear_session_output_pages(session.output_prefix)

  if require("typst-concealer").config.do_diagnostics then
    session.stderr_chunks = {}
    session.stderr_text = ""
    session.stderr_line_buffer = ""
    clear_quickfix(bufnr, kind)
  end

  local wrapper = require("typst-concealer.wrapper")
  local doc_str, line_map =
    wrapper.build_batch_document(items, session.buf_dir, session.source_root, session.effective_root, session.kind)
  session.line_map = line_map
  local ok, err = write_file_in_place(session.input_path, doc_str)
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to update watch input: " .. tostring(err), vim.log.levels.ERROR)
    end)
    return
  end
end

return M
