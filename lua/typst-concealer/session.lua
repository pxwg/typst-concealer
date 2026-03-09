--- Watch session management for typst-concealer.
--- Manages long-running `typst watch` processes, polling for rendered pages,
--- and calling into the extmark layer when a page is ready.
---
--- TypstBackend interface (current: Typst only)
---   M.render_items_via_watch(bufnr, items, kind)    dispatch items to a watch session
---   M.ensure_watch_session(bufnr, kind)             start/reuse a watch session
---   M.stop_watch_session(bufnr, kind)               kill and clean up a session
---   M.stop_watch_sessions_for_buf(bufnr)            kill both sessions for a buffer

local state = require("typst-concealer.state")
local M = {}

--- Generate quickfix title for a watch session.
--- @param bufnr integer
--- @param kind  'full' | 'preview'
--- @return string
local function qf_title(bufnr, kind)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == nil or name == "" then
    name = ("buf:%d"):format(bufnr)
  end
  return ("typst-concealer (%s): %s"):format(kind, name)
end

--- Clear quickfix list for a session.
--- @param bufnr integer
--- @param kind  'full' | 'preview'
local function clear_quickfix(bufnr, kind)
  vim.schedule(function()
    vim.fn.setqflist({}, "r", {
      title = qf_title(bufnr, kind),
      items = {},
    })
  end)
end

--- @param line_map table[]|nil
--- @param gen_lnum integer
--- @param gen_col integer
--- @return table|nil
local function map_generated_pos(line_map, gen_lnum, gen_col)
  if not line_map or #line_map == 0 then
    return nil
  end

  local nearest = nil
  for _, seg in ipairs(line_map) do
    if gen_lnum >= seg.gen_start and gen_lnum <= seg.gen_end then
      return {
        filename = vim.api.nvim_buf_get_name(seg.bufnr),
        lnum = seg.src_start + (gen_lnum - seg.gen_start),
        col = gen_col,
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
      col = 1,
      exact = false,
    }
  end
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
  local fd, open_err = vim.uv.fs_open(path, "w", tonumber("644", 8))
  if not fd then
    return false, open_err
  end
  local _, write_err = vim.uv.fs_write(fd, text, 0)
  vim.uv.fs_close(fd)
  if write_err ~= nil then
    return false, write_err
  end
  return true
end

local function parse_typst_stderr(session, text)
  local items = {}
  local current_msg = nil

  for line in (text .. "\n"):gmatch("(.-)\n") do
    local trimmed = vim.trim(line)

    if trimmed ~= "" then
      local msg = trimmed:match("^error:%s*(.*)$")
      if msg and msg ~= "" then
        current_msg = msg
      end

      local file, lnum, col = trimmed:match("^┌─%s+(.+):(%d+):(%d+)$")
      if not file then
        file, lnum, col = trimmed:match("^╭─%s+(.+):(%d+):(%d+)$")
      end
      if not file then
        file, lnum, col = trimmed:match("^%s*[╭┌]─%s+(.+):(%d+):(%d+)$")
      end

      if file and lnum and col then
        local gen_lnum = tonumber(lnum)
        local gen_col = tonumber(col)
        local mapped = map_generated_pos(session.line_map, gen_lnum, gen_col)

        if mapped then
          items[#items + 1] = {
            filename = mapped.filename,
            lnum = mapped.lnum,
            col = mapped.col,
            text = mapped.exact and (current_msg or "typst watch error")
              or ((current_msg or "typst watch error") .. " [generated wrapper/prelude]"),
            type = "E",
          }
        else
          if file == session.input_path then
            file = vim.api.nvim_buf_get_name(session.bufnr)
          end
          items[#items + 1] = {
            filename = file,
            lnum = gen_lnum,
            col = gen_col,
            text = current_msg or "typst watch error",
            type = "E",
          }
        end
      end
    end
  end

  return items
end

--- Update quickfix from accumulated stderr chunks.
--- @param bufnr integer
--- @param kind  'full' | 'preview'
--- @param input_path string
--- @param chunks string[]
local function update_quickfix_from_stderr(session)
  local text = table.concat(session.stderr_chunks, "")
  local items = parse_typst_stderr(session, text)
  vim.schedule(function()
    vim.fn.setqflist({}, "r", {
      title = qf_title(session.bufnr, session.kind),
      items = items,
    })
  end)
end

local function get_buf_dir(bufnr)
  local buf_file = vim.api.nvim_buf_get_name(bufnr)
  if buf_file == nil or buf_file == "" then
    return vim.uv.cwd()
  end
  return vim.fn.fnamemodify(buf_file, ":h")
end

--- Generates the fixed input path for a watch session.
--- @param bufnr integer
--- @param kind  'full' | 'preview'
--- @return string
local function session_input_path(bufnr, kind)
  local dir = get_buf_dir(bufnr)
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

--- Stop a watch session and clean up its files.
--- @param bufnr integer
--- @param kind  'full' | 'preview'
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
  if next(bucket) == nil then
    state.watch_sessions[bufnr] = nil
  end
end

--- @param bufnr integer
function M.stop_watch_sessions_for_buf(bufnr)
  M.stop_watch_session(bufnr, "full")
  M.stop_watch_session(bufnr, "preview")
end

--- Called when a rendered page file is stable and ready to display.
--- Looks up item.semantics for the swap / padding decisions.
--- @param bufnr          integer
--- @param page_path      string
--- @param image_id       integer
--- @param extmark_id     integer
--- @param original_range table
local function on_page_rendered(bufnr, page_path, image_id, extmark_id, original_range)
  local pngData = require("typst-concealer.png-lua")
  local extmark = require("typst-concealer.extmark")
  local kitty_codes = require("typst-concealer.kitty-codes")

  local item = state.get_item_by_image_id(image_id)

  local target_bufnr = bufnr
  local target_range = original_range
  if item and item.render_target == "float" then
    target_bufnr = item.target_bufnr or bufnr
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
  if item and item.render_target == "float" then
    require("typst-concealer.render").commit_live_typst_preview(
      item.bufnr,
      image_id,
      extmark_id,
      natural_cols,
      natural_rows
    )
  else
    require("typst-concealer.render").hide_extmarks_at_cursor(bufnr)
  end
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
    on_page_rendered(session.bufnr, page_path, item.image_id, item.extmark_id, item.range)
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
--- @param kind  'full' | 'preview'
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
  local input_path = session_input_path(bufnr, kind)
  local template, prefix = session_output_template(bufnr, kind)

  local args = { "watch", input_path, template, "--ppi=" .. (state._render_ppi or config.ppi) }
  if config.compiler_args then
    for _, arg in ipairs(config.compiler_args) do
      table.insert(args, arg)
    end
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
    stderr_debounce = nil,
    dead = false,
  }

  local handle
  handle = vim.uv.spawn(config.typst_location, {
    stdio = { nil, stdout, stderr },
    args = args,
  }, function()
    session.dead = true
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
      session.stderr_chunks[#session.stderr_chunks + 1] = data
      if #session.stderr_chunks > 32 then
        table.remove(session.stderr_chunks, 1)
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
--- @param kind  'full' | 'preview'
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

  if require("typst-concealer").config.do_diagnostics then
    session.stderr_chunks = {}
    clear_quickfix(bufnr, kind)
  end

  local wrapper = require("typst-concealer.wrapper")
  local doc_str, line_map = wrapper.build_batch_document(items)
  session.line_map = line_map
  local ok, err = write_file_in_place(session.input_path, doc_str)
  if not ok then
    vim.schedule(function()
      vim.notify("[typst-concealer] failed to update watch input: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

return M
