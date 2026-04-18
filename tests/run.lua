local root = vim.fs.normalize(vim.fn.getcwd())
vim.opt.runtimepath:append(root)
vim.opt.swapfile = false

local function fail(msg)
  io.stderr:write(msg .. "\n")
  vim.cmd("cquit 1")
end

local function ok(msg)
  io.stdout:write(msg .. "\n")
end

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail(("%s\nexpected: %s\nactual: %s"):format(msg, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_truthy(value, msg)
  if not value then
    fail(msg)
  end
end

local function assert_startswith(actual, prefix, msg)
  if actual:sub(1, #prefix) ~= prefix then
    fail(("%s\nexpected prefix: %s\nactual: %s"):format(msg, vim.inspect(prefix), vim.inspect(actual)))
  end
end

local function write_file(path, text)
  local fd = assert(vim.uv.fs_open(path, "w", tonumber("644", 8)))
  assert(vim.uv.fs_write(fd, text, 0))
  assert(vim.uv.fs_close(fd))
end

local function real_path(path)
  return vim.uv.fs_realpath(path) or path
end

local function reset_modules()
  package.loaded["typst-concealer"] = nil
  package.loaded["typst-concealer.state"] = nil
  package.loaded["typst-concealer.apply"] = nil
  package.loaded["typst-concealer.plan"] = nil
  package.loaded["typst-concealer.cursor-visibility"] = nil
  package.loaded["typst-concealer.extmark"] = nil
  package.loaded["typst-concealer.session"] = nil
  package.loaded["typst-concealer.project-scope"] = nil
  package.loaded["typst-concealer.machine.types"] = nil
  package.loaded["typst-concealer.machine.reducer"] = nil
  package.loaded["typst-concealer.machine.effects"] = nil
  package.loaded["typst-concealer.machine.resources"] = nil
  package.loaded["typst-concealer.machine.runtime"] = nil
  package.loaded["typst-concealer.wrapper"] = nil
  package.loaded["typst-concealer.path-rewrite"] = nil
end

local function with_stubbed_uv(fn, opts)
  local uv_opts = opts or {}
  local uv = vim.uv
  local original = {
    new_pipe = uv.new_pipe,
    new_timer = uv.new_timer,
    spawn = uv.spawn,
  }

  local spawned = {}
  uv.new_pipe = function()
    return {
      writes = {},
      read_start = function(self, cb)
        self.read_cb = cb
      end,
      feed = function(self, data)
        if self.read_cb then
          self.read_cb(nil, data)
        end
      end,
      write = function(self, data, cb)
        self.writes[#self.writes + 1] = data
        if cb then
          cb(uv_opts.write_error)
        end
      end,
      is_closing = function()
        return false
      end,
      close = function(self)
        self.closed = true
      end,
    }
  end
  uv.new_timer = function()
    return {
      start = function() end,
      stop = function() end,
      close = function(self)
        self.closed = true
      end,
      is_closing = function(self)
        return self.closed == true
      end,
    }
  end
  uv.spawn = function(_cmd, opts, _on_exit)
    if uv_opts.spawn_fails then
      return nil
    end
    local handle = {
      closed = false,
      killed = false,
      kill = function(self)
        self.killed = true
      end,
      close = function(self)
        self.closed = true
      end,
      is_closing = function(self)
        return self.closed == true
      end,
    }
    spawned[#spawned + 1] = {
      cmd = _cmd,
      args = vim.deepcopy(opts.args),
      stdio = opts.stdio,
      handle = handle,
    }
    return handle
  end

  local ok_run, result = pcall(fn, spawned)

  uv.new_pipe = original.new_pipe
  uv.new_timer = original.new_timer
  uv.spawn = original.spawn

  if not ok_run then
    error(result)
  end
  return result
end

local function fresh_state()
  reset_modules()
  local state = require("typst-concealer.state")
  state.watch_sessions = {}
  state.watch_diagnostics = {}
  state.buffer_render_state = {}
  state.path_rewrite_cache = {}
  state.runtime_preludes = {}
  state.machine_state = require("typst-concealer.machine.types").initial_state()
  return state
end

local function with_stubbed_extmark(fn)
  local original = package.loaded["typst-concealer.extmark"]
  local calls = {
    placed = {},
    swapped = {},
    cleared = {},
    created = {},
    concealed = {},
    unconcealed = {},
    virtual = {},
  }

  package.loaded["typst-concealer.extmark"] = {
    place_render_extmark = function(bufnr, image_id, range, extmark_id, concealing, semantics)
      local id = extmark_id or (image_id + 10000)
      local state = require("typst-concealer.state")
      state.image_id_to_extmark[image_id] = id
      calls.placed[#calls.placed + 1] = {
        bufnr = bufnr,
        image_id = image_id,
        range = range,
        extmark_id = id,
        concealing = concealing,
        semantics = semantics,
      }
      return id
    end,
    swap_extmark_to_range = function(bufnr, image_id, extmark_id, range, semantics, concealing)
      local state = require("typst-concealer.state")
      state.image_id_to_extmark[image_id] = extmark_id
      calls.swapped[#calls.swapped + 1] = {
        bufnr = bufnr,
        image_id = image_id,
        extmark_id = extmark_id,
        range = range,
        semantics = semantics,
        concealing = concealing,
      }
    end,
    clear_image = function(image_id)
      local state = require("typst-concealer.state")
      calls.cleared[#calls.cleared + 1] = image_id
      state.image_ids_in_use[image_id] = nil
    end,
    create_image = function(path, image_id, width, height)
      calls.created[#calls.created + 1] = {
        path = path,
        image_id = image_id,
        width = width,
        height = height,
      }
    end,
    conceal_for_image_id = function(bufnr, image_id, natural_cols, natural_rows, source_rows)
      calls.concealed[#calls.concealed + 1] = {
        bufnr = bufnr,
        image_id = image_id,
        natural_cols = natural_cols,
        natural_rows = natural_rows,
        source_rows = source_rows,
      }
    end,
    unconceal_extmark = function(bufnr, extmark_id)
      calls.unconcealed[#calls.unconcealed + 1] = {
        bufnr = bufnr,
        extmark_id = extmark_id,
      }
      return true
    end,
    show_virtual_image = function(bufnr, extmark_id, anchor_row, render_image_id, natural_cols, natural_rows, opts)
      local id = extmark_id or (render_image_id + 20000)
      calls.virtual[#calls.virtual + 1] = {
        bufnr = bufnr,
        extmark_id = id,
        anchor_row = anchor_row,
        render_image_id = render_image_id,
        natural_cols = natural_cols,
        natural_rows = natural_rows,
        opts = opts,
      }
      return id
    end,
  }

  local ok_run, result = pcall(fn, calls)
  package.loaded["typst-concealer.extmark"] = original
  if not ok_run then
    error(result)
  end
  return result
end

local function make_render_item(fields)
  local item = {
    bufnr = 1,
    item_idx = 1,
    range = { 0, 0, 0, 3 },
    str = "$x$",
    prelude_count = 0,
    node_type = "math",
    semantics = { display_kind = "inline", constraint_kind = "inline" },
  }
  for key, value in pairs(fields or {}) do
    item[key] = value
  end
  item.display_range = item.display_range or item.range
  return item
end

local function make_scanned_node(fields)
  local node = {
    stable_key = nil,
    item_idx = 1,
    node_type = "math",
    source_range = { 0, 0, 0, 3 },
    display_range = { 0, 0, 0, 3 },
    source_text = "$x$",
    source_text_hash = "hash:x",
    context_hash = "ctx:0",
    prelude_count = 0,
    semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
  }
  for key, value in pairs(fields or {}) do
    node[key] = value
  end
  return node
end

local function scan_event(scanned_nodes, opts)
  opts = opts or {}
  return {
    type = "nodes_scanned",
    bufnr = opts.bufnr or 1,
    project_scope_id = opts.project_scope_id or "project:1",
    buffer_version = opts.buffer_version or 1,
    layout_version = opts.layout_version or 1,
    scanned_nodes = scanned_nodes,
    binding_dirty_ranges = opts.binding_dirty_ranges,
  }
end

local function page_ready_event(overlay, opts)
  opts = opts or {}
  return {
    type = "overlay_page_ready",
    request_id = opts.request_id or overlay.request_id,
    request_page_index = opts.request_page_index or overlay.page_index,
    overlay_id = overlay.overlay_id,
    owner_node_id = opts.owner_node_id or overlay.owner_node_id,
    owner_bufnr = opts.owner_bufnr or overlay.owner_bufnr,
    owner_project_scope_id = opts.owner_project_scope_id or overlay.owner_project_scope_id,
    render_epoch = opts.render_epoch or overlay.render_epoch,
    buffer_version = opts.buffer_version or overlay.buffer_version,
    layout_version = opts.layout_version or overlay.layout_version,
    page_path = opts.page_path or "/tmp/page.png",
    page_stamp = opts.page_stamp or "stamp",
    natural_cols = opts.natural_cols or 4,
    natural_rows = opts.natural_rows or 1,
    source_rows = opts.source_rows or 1,
  }
end

local function count_effects(effects, kind)
  local count = 0
  for _, effect in ipairs(effects or {}) do
    if effect.kind == kind then
      count = count + 1
    end
  end
  return count
end

local function first_effect(effects, kind)
  for _, effect in ipairs(effects or {}) do
    if effect.kind == kind then
      return effect
    end
  end
end

local function first_overlay_job(request_effect)
  for _, job in ipairs((request_effect and request_effect.request and request_effect.request.jobs) or {}) do
    if job.overlay_id ~= nil then
      return job
    end
  end
end

local function commit_overlay_jobs(reducer, state, request_effect)
  for _, job in ipairs((request_effect and request_effect.request and request_effect.request.jobs) or {}) do
    if job.overlay_id ~= nil then
      local overlay = state.overlays[job.overlay_id]
      state = reducer.reduce(state, page_ready_event(overlay))
      state = reducer.reduce(state, {
        type = "overlay_commit_succeeded",
        overlay_id = overlay.overlay_id,
        node_id = overlay.owner_node_id,
      })
    end
  end
  return state
end

local function make_temp_tree(name)
  local base = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.tempname() .. "-" .. name, ":p")):gsub("/$", "")
  assert(vim.fn.mkdir(base, "p") == 1)
  return base
end

local function test_root_prefers_cwd_fallback()
  local root_base = make_temp_tree("root-base")
  local project = vim.fs.joinpath(root_base, "dif-geo", "hw6")
  local template_dir = vim.fs.joinpath(root_base, "typ", "templates")
  assert(vim.fn.mkdir(project, "p") == 1)
  assert(vim.fn.mkdir(template_dir, "p") == 1)
  write_file(vim.fs.joinpath(project, "typst.toml"), "")
  local main_path = vim.fs.joinpath(project, "main.typ")
  local template_path = vim.fs.joinpath(template_dir, "blog-preview.typ")
  write_file(main_path, '#import "' .. template_path .. '": foo\n')
  write_file(template_path, "#let foo = 1\n")
  main_path = real_path(main_path)
  template_path = real_path(template_path)

  vim.api.nvim_set_current_dir(root_base)
  local cwd_root = real_path(vim.fn.getcwd())
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, main_path)

  local state = fresh_state()
  local session = with_stubbed_uv(function(spawned)
    package.loaded["typst-concealer"] = {
      config = {
        typst_location = "typst",
        ppi = 300,
        compiler_args = {},
        get_root = nil,
        get_inputs = nil,
        get_preamble_file = nil,
        do_diagnostics = false,
        header = "",
      },
      _styling_prelude = "",
    }
    local session_mod = require("typst-concealer.session")
    local s = session_mod.ensure_watch_session(bufnr)
    assert_eq(#spawned, 1, "expected exactly one typst watch spawn")
    local root_arg = spawned[1].args[5]
    assert_eq(root_arg, "--root=" .. cwd_root, "ensure_watch_session should pass cwd as --root fallback")
    return s
  end)

  assert_eq(session.source_root, cwd_root, "session.source_root should match cwd fallback root base")
  assert_eq(session.effective_root, cwd_root, "session.effective_root should match root base")
  assert_startswith(
    session.input_path,
    cwd_root .. "/.typst-concealer/",
    "input path should live under root base cache dir"
  )

  local path_rewrite = require("typst-concealer.path-rewrite")
  local rewritten = path_rewrite.rewrite_paths('#import "' .. template_path .. '": foo', {
    bufnr = bufnr,
    buf_dir = project,
    source_root = session.source_root,
    effective_root = session.effective_root,
  })
  assert_eq(
    rewritten,
    '#import "/typ/templates/blog-preview.typ": foo',
    "absolute import should rewrite relative to cwd root base"
  )

  require("typst-concealer.session").stop_watch_session(bufnr, "full")
  vim.api.nvim_buf_delete(bufnr, { force = true })
  state.watch_sessions = {}
end

local function test_get_root_overrides_fallback()
  local root_base = make_temp_tree("explicit-root")
  local alt_root = vim.fs.joinpath(root_base, "workspace")
  local project = vim.fs.joinpath(alt_root, "notes")
  assert(vim.fn.mkdir(project, "p") == 1)
  write_file(vim.fs.joinpath(project, "main.typ"), "$x$")
  alt_root = real_path(alt_root)
  vim.api.nvim_set_current_dir(root_base)

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, vim.fs.joinpath(project, "main.typ"))

  with_stubbed_uv(function(spawned)
    package.loaded["typst-concealer"] = {
      config = {
        typst_location = "typst",
        ppi = 300,
        compiler_args = {},
        get_root = function()
          return alt_root
        end,
        get_inputs = nil,
        get_preamble_file = nil,
        do_diagnostics = false,
        header = "",
      },
      _styling_prelude = "",
    }
    local session_mod = require("typst-concealer.session")
    local session = session_mod.ensure_watch_session(bufnr)
    assert_eq(spawned[1].args[5], "--root=" .. alt_root, "get_root should override cwd/project fallback")
    assert_startswith(session.input_path, alt_root .. "/.typst-concealer/", "cache dir should use explicit root base")
    session_mod.stop_watch_session(bufnr, "full")
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_session_render_request_tracks_current_request()
  local root = make_temp_tree("watch-request")
  local main_path = vim.fs.joinpath(root, "main.typ")
  write_file(main_path, "$x$")
  main_path = real_path(main_path)

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, main_path)
  local state = fresh_state()
  state.buffer_render_state[bufnr] = { runtime_preludes = {} }

  with_stubbed_uv(function()
    package.loaded["typst-concealer"] = {
      config = {
        typst_location = "typst",
        ppi = 300,
        compiler_args = {},
        get_root = function()
          return root
        end,
        get_inputs = nil,
        get_preamble_file = nil,
        do_diagnostics = false,
        header = "",
      },
      _styling_prelude = "",
    }

    local session_mod = require("typst-concealer.session")
    local request = {
      request_id = "request:1",
      bufnr = bufnr,
      project_scope_id = "project:1",
      render_epoch = 1,
      buffer_version = 1,
      layout_version = 1,
      jobs = {
        {
          request_id = "request:1",
          request_page_index = 1,
          overlay_id = "overlay:1",
          node_id = "node:1",
          bufnr = bufnr,
          project_scope_id = "project:1",
          render_epoch = 1,
          buffer_version = 1,
          layout_version = 1,
          item_idx = 1,
          range = { 0, 0, 0, 3 },
          display_range = { 0, 0, 0, 3 },
          source_text = "$x$",
          str = "$x$",
          prelude_count = 0,
          semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
          image_id = 101,
        },
      },
    }

    session_mod.render_request_via_watch(bufnr, request)
    local session = state.watch_sessions[bufnr].full
    assert_eq(session.current_request.request_id, "request:1", "session should track current request id")
    assert_eq(session.current_request.status, "active", "new request should be active")
    assert_eq(session.current_request.page_to_overlay[1], "overlay:1", "page should map to overlay")
    assert_eq(session.current_request.overlay_to_page["overlay:1"], 1, "overlay should map back to page")
    assert_eq(session.base_items[1].overlay_id, "overlay:1", "request jobs should become watch base items")
    assert_eq(next(session.page_state), nil, "new request should reset page state")
    assert_truthy(session.last_input_text ~= nil, "new request should write watch input")
    local first_input_write_count = session.last_input_write_count

    local stale_page_1 = session.output_prefix .. "-1.png"
    local stale_page_2 = session.output_prefix .. "-2.png"
    write_file(stale_page_1, "old-page-1")
    write_file(stale_page_2, "old-page-2")
    session.page_state = {
      [1] = { rendered = "old-stamp", last_seen = "old-stamp" },
      [2] = { rendered = "old-stamp", last_seen = "old-stamp" },
    }
    session.last_page_count = 2

    local old_request = session.current_request
    local request2 = vim.deepcopy(request)
    request2.request_id = "request:2"
    request2.jobs[1].request_id = "request:2"
    session_mod.render_request_via_watch(bufnr, request2)
    assert_eq(old_request.status, "abandoned", "replaced request should be abandoned")
    assert_eq(session.current_request.request_id, "request:2", "session should install replacement request")
    assert_eq(vim.uv.fs_stat(stale_page_1), nil, "replacement request should clear stale page 1")
    assert_eq(vim.uv.fs_stat(stale_page_2), nil, "replacement request should clear stale page 2")
    assert_eq(next(session.page_state), nil, "replacement request should reset page state before polling")
    assert_eq(
      session.last_input_write_count,
      first_input_write_count + 1,
      "replacement request should force a watch input write"
    )

    session_mod.stop_watch_session(bufnr, "full")
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_session_render_request_via_service_writes_json()
  local root = make_temp_tree("service-request")
  local main_path = vim.fs.joinpath(root, "main.typ")
  write_file(main_path, "$x$")

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, main_path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$" })
  local state = fresh_state()
  state.buffer_render_state[bufnr] = { runtime_preludes = { "#let warm-color = red\n" } }

  with_stubbed_uv(function(spawned)
    package.loaded["typst-concealer"] = {
      config = {
        typst_location = "typst",
        use_compiler_service = true,
        service_binary = "typst-concealer-service-test",
        ppi = 300,
        compiler_args = {},
        get_root = function()
          return root
        end,
        get_inputs = function()
          return { "concealed=true" }
        end,
        get_preamble_file = nil,
        do_diagnostics = false,
        header = "",
      },
      _styling_prelude = "",
    }

    local session_mod = require("typst-concealer.session")
    local request = {
      request_id = "request:service:1",
      bufnr = bufnr,
      project_scope_id = "project:service",
      render_epoch = 1,
      buffer_version = 1,
      layout_version = 1,
      jobs = {
        {
          request_page_index = 1,
          overlay_id = "overlay:service",
          node_id = "node:service",
          bufnr = bufnr,
          project_scope_id = "project:service",
          render_epoch = 1,
          buffer_version = 1,
          layout_version = 1,
          item_idx = 1,
          range = { 0, 0, 0, 3 },
          display_range = { 0, 0, 0, 3 },
          source_text = "$x$",
          str = "$x$",
          prelude_count = 1,
          semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
          image_id = 101,
        },
      },
    }

    session_mod.render_request_via_service(bufnr, request)
    assert_eq(#spawned, 2, "expected separate full and preview compiler service spawns")
    assert_eq(spawned[1].cmd, "typst-concealer-service-test", "full service_binary should be spawned")
    assert_eq(spawned[2].cmd, "typst-concealer-service-test", "preview service_binary should be spawned")
    local stdin = spawned[1].stdio[1]
    local preview_stdin = spawned[2].stdio[1]
    assert_eq(#stdin.writes, 1, "service request should be written to stdin")
    assert_eq(#preview_stdin.writes, 1, "preview backend should prewarm during full render startup")
    local msg = vim.json.decode(vim.trim(stdin.writes[1]))
    local prewarm_msg = vim.json.decode(vim.trim(preview_stdin.writes[1]))
    assert_eq(msg.type, "compile", "service message should be a compile request")
    assert_eq(msg.request_id, "request:service:1", "service message should carry request_id")
    assert_truthy(msg.cache_key:find("^full:", 1, false) ~= nil, "service message should isolate full cache")
    assert_eq(msg.root, root, "service message should carry effective root")
    assert_eq(msg.inputs.concealed, "true", "service message should include project inputs")
    assert_truthy(
      msg.output_dir:find("/%.typst%-concealer/", 1, false) ~= nil,
      "service output_dir should use cache dir"
    )
    local full_slot_include = msg.source_text:match('#include%s+"([^"]*/full/slots/slot%-000001%.typ)"')
    assert_truthy(full_slot_include ~= nil, "service main source should include a stable slot sidecar")
    assert_truthy(msg.source_text:find("$x$", 1, true) == nil, "service main source should not inline formula text")
    local full_slot_path = full_slot_include:sub(1, 1) == "/" and (root .. full_slot_include)
      or vim.fs.joinpath(root, full_slot_include)
    local full_slot_text = table.concat(vim.fn.readfile(full_slot_path), "\n")
    assert_truthy(full_slot_text:find("$x$", 1, true) ~= nil, "dirty full slot sidecar should contain formula text")
    assert_startswith(prewarm_msg.request_id, "preview-prewarm:", "preview prewarm should carry a prewarm id")
    assert_truthy(prewarm_msg.cache_key:find("^preview:", 1, false) ~= nil, "preview prewarm should use preview cache")
    assert_truthy(
      prewarm_msg.source_text:find("#let warm-color = red", 1, true) == nil,
      "preview prewarm main source should not inline runtime prelude"
    )
    assert_truthy(
      prewarm_msg.source_text:find('#include "', 1, true) ~= nil,
      "preview prewarm should use a stable sidecar include"
    )
    assert_truthy(
      prewarm_msg.source_text:find("$x$", 1, true) == nil,
      "preview prewarm main source should not inline formula text"
    )
    local prewarm_include_path = prewarm_msg.source_text:match('#include%s+"([^"]+)"')
    assert_truthy(prewarm_include_path ~= nil, "preview prewarm should include a sidecar")
    local prewarm_sidecar_path = prewarm_include_path:sub(1, 1) == "/" and (root .. prewarm_include_path)
      or vim.fs.joinpath(root, prewarm_include_path)
    local prewarm_sidecar_text = table.concat(vim.fn.readfile(prewarm_sidecar_path), "\n")
    assert_truthy(
      prewarm_sidecar_text:find("#let warm-color = red", 1, true) ~= nil,
      "preview prewarm sidecar should include the full prelude snapshot"
    )
    assert_truthy(
      prewarm_sidecar_text:find("$x$", 1, true) ~= nil,
      "preview prewarm sidecar should contain formula text"
    )
    assert_eq(state.active_service_requests[bufnr].request_id, "request:service:1", "service request should be active")

    local old = state.active_service_requests[bufnr]
    local request2 = vim.deepcopy(request)
    request2.request_id = "request:service:2"
    session_mod.render_request_via_service(bufnr, request2)
    assert_eq(old.status, "abandoned", "replacement service request should abandon old metadata")
    assert_eq(
      state.active_service_requests[bufnr].request_id,
      "request:service:2",
      "replacement service request should become active"
    )
    assert_eq(#stdin.writes, 1, "in-flight service request should coalesce newer full requests")
    assert_truthy(
      state.compiler_services[bufnr].full.pending_full_request ~= nil,
      "newer full request should wait in the pending slot"
    )

    local old_pending = state.active_service_requests[bufnr]
    local request3 = vim.deepcopy(request)
    request3.request_id = "request:service:3"
    session_mod.render_request_via_service(bufnr, request3)
    assert_eq(old_pending.status, "superseded", "replaced pending service request should be marked superseded")
    assert_eq(
      state.active_service_requests[bufnr].request_id,
      "request:service:3",
      "latest coalesced service request should become active"
    )
    assert_eq(#stdin.writes, 1, "coalescing pending full requests should not write while in-flight")

    local preview_item = vim.deepcopy(request.jobs[1])
    preview_item.request_id = nil
    preview_item.preview_request_id = "preview:service:1"
    preview_item.str = "$#text(red)[$x$]$"
    preview_item.source_str = "$x$"
    session_mod.render_preview_tail_via_service(bufnr, preview_item)
    assert_eq(#stdin.writes, 1, "preview request should not queue behind the full backend")
    assert_eq(#preview_stdin.writes, 1, "preview request should wait only for preview prewarm")
    assert_truthy(
      state.compiler_services[bufnr].preview.pending_preview_request ~= nil,
      "preview request should be queued behind preview prewarm"
    )
    local preview_msg = vim.json.decode(state.compiler_services[bufnr].preview.pending_preview_request.message)
    assert_eq(preview_msg.request_id, "preview:service:1", "preview service message should carry preview id")
    assert_truthy(
      preview_msg.cache_key:find("^preview:", 1, false) ~= nil,
      "preview message should isolate preview cache"
    )
    assert_eq(
      preview_msg.source_text,
      prewarm_msg.source_text,
      "preview should keep the warmed main source stable for the same context"
    )
    assert_truthy(
      preview_msg.source_text:find("$#text(red)[$x$]$", 1, true) == nil,
      "preview main source should not inline highlighted source"
    )
    local preview_stdout = spawned[2].stdio[2]
    preview_stdout:feed(vim.json.encode({
      type = "compile_result",
      request_id = prewarm_msg.request_id,
      status = "ok",
      pages = {},
      diagnostics = {},
      compile_us = 1,
      render_us = 1,
      rendered_pages = 0,
    }) .. "\n")
    vim.wait(50, function()
      return #preview_stdin.writes == 2
    end)
    assert_eq(#preview_stdin.writes, 2, "queued preview should send after prewarm response")
    local sent_preview_msg = vim.json.decode(vim.trim(preview_stdin.writes[2]))
    assert_eq(sent_preview_msg.request_id, "preview:service:1", "sent preview should carry preview id")
    assert_eq(
      sent_preview_msg.source_text,
      prewarm_msg.source_text,
      "sent preview should still use the warmed main source"
    )
    local include_path = sent_preview_msg.source_text:match('#include%s+"([^"]+)"')
    assert_truthy(include_path ~= nil, "sent preview should include a preview sidecar")
    local sidecar_path = include_path:sub(1, 1) == "/" and (root .. include_path) or vim.fs.joinpath(root, include_path)
    local sidecar_text = table.concat(vim.fn.readfile(sidecar_path), "\n")
    assert_truthy(
      sidecar_text:find("#let warm-color = red", 1, true) ~= nil,
      "sent preview sidecar should keep the full prelude snapshot"
    )
    assert_truthy(
      sidecar_text:find("$#text(red)[$x$]$", 1, true) ~= nil,
      "sent preview should write highlighted source to the sidecar"
    )

    session_mod.stop_compiler_service(bufnr)
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function make_service_response_harness(name, opts, fn)
  opts = opts or {}
  local root = make_temp_tree(name)
  local main_path = vim.fs.joinpath(root, "main.typ")
  write_file(main_path, "$x$")
  main_path = real_path(main_path)

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, main_path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$" })
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local state = fresh_state()
  state.pid = 8000
  state.buffer_render_state[bufnr] = { runtime_preludes = opts.runtime_preludes or {} }

  with_stubbed_uv(function(spawned)
    package.loaded["typst-concealer"] = {
      config = {
        typst_location = "typst",
        use_compiler_service = true,
        service_binary = "typst-concealer-service-test",
        ppi = 300,
        compiler_args = {},
        get_root = function()
          return root
        end,
        get_inputs = nil,
        get_preamble_file = nil,
        do_diagnostics = opts.do_diagnostics == true,
        header = opts.header or "",
        math_baseline_pt = 11,
      },
      _styling_prelude = opts.styling_prelude or "",
    }

    local jobs = vim.deepcopy(opts.jobs or {})
    if opts.jobs == nil then
      for i = 1, opts.job_count or 1 do
        jobs[#jobs + 1] = {
          request_page_index = i,
          overlay_id = ("overlay:%s:%d"):format(name, i),
          node_id = ("node:%s:%d"):format(name, i),
          slot_id = "slot:" .. tostring(i),
          bufnr = bufnr,
          project_scope_id = opts.project_scope_id or "project:service",
          render_epoch = 1,
          buffer_version = tick,
          layout_version = opts.layout_version or 1,
          item_idx = i,
          range = { 0, 0, 0, 3 },
          display_range = { 0, 0, 0, 3 },
          source_text = "$x$",
          str = "$x$",
          prelude_count = 0,
          semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
          image_id = 100 + i,
        }
      end
    else
      for i, job in ipairs(jobs) do
        job.request_page_index = job.request_page_index or i
        job.slot_id = job.slot_id or ("slot:" .. tostring(i))
        job.node_id = job.node_id or ("node:%s:%d"):format(name, i)
        job.bufnr = job.bufnr or bufnr
        job.project_scope_id = job.project_scope_id or opts.project_scope_id or "project:service"
        job.render_epoch = job.render_epoch or 1
        job.buffer_version = job.buffer_version or tick
        job.layout_version = job.layout_version or opts.layout_version or 1
        job.item_idx = job.item_idx or i
        job.range = job.range or { 0, 0, 0, 3 }
        job.display_range = job.display_range or { 0, 0, 0, 3 }
        job.source_text = job.source_text or "$x$"
        job.str = job.str or job.source_text
        job.prelude_count = job.prelude_count or 0
        job.semantics = job.semantics or { display_kind = "inline", constraint_kind = "intrinsic" }
        job.image_id = job.image_id or (100 + i)
      end
    end

    local request = {
      request_id = opts.request_id or ("request:" .. name),
      bufnr = bufnr,
      project_scope_id = opts.project_scope_id or "project:service",
      render_epoch = 1,
      buffer_version = tick,
      layout_version = opts.layout_version or 1,
      jobs = jobs,
    }

    local nodes = {}
    local node_order = {}
    for _, job in ipairs(request.jobs) do
      nodes[job.node_id] = {
        node_id = job.node_id,
        slot_id = job.slot_id,
        bufnr = bufnr,
        project_scope_id = request.project_scope_id,
        item_idx = job.item_idx,
        node_type = "math",
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = job.source_text,
        source_text_hash = "hash:" .. tostring(job.source_text),
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        status = job.overlay_id and "pending" or "stable",
        candidate_overlay_id = job.overlay_id,
      }
      node_order[#node_order + 1] = job.node_id
      if job.overlay_id ~= nil then
        state.machine_state.overlays[job.overlay_id] = {
          overlay_id = job.overlay_id,
          slot_id = job.slot_id,
          owner_node_id = job.node_id,
          owner_bufnr = bufnr,
          owner_project_scope_id = request.project_scope_id,
          request_id = request.request_id,
          page_index = job.request_page_index,
          render_epoch = request.render_epoch,
          buffer_version = request.buffer_version,
          layout_version = request.layout_version,
          status = "rendering",
        }
      end
    end

    state.machine_state.buffers[bufnr] = {
      bufnr = bufnr,
      project_scope_id = request.project_scope_id,
      buffer_version = tick,
      layout_version = request.layout_version,
      render_epoch = request.render_epoch,
      active_request_id = request.request_id,
      nodes = nodes,
      node_order = node_order,
    }

    local session_mod = require("typst-concealer.session")
    session_mod.render_request_via_service(bufnr, request)
    if state.active_service_requests[bufnr] ~= nil then
      state.machine_state.buffers[bufnr].project_scope_id = state.active_service_requests[bufnr].project_scope_id
    end
    fn({
      root = root,
      main_path = main_path,
      bufnr = bufnr,
      state = state,
      request = request,
      session = session_mod,
      spawned = spawned,
      full_stdout = spawned[1].stdio[2],
      preview_stdout = spawned[2].stdio[2],
    })
    session_mod.stop_compiler_service(bufnr)
  end, opts.uv_opts)

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

local function feed_service_response(stdout, response)
  stdout:feed(vim.json.encode(response) .. "\n")
end

local function wait_until_service_request_cleared(state, bufnr)
  vim.wait(100, function()
    return state.active_service_requests[bufnr] == nil
  end)
end

local function test_service_validates_page_contract()
  local cases = {
    {
      name = "missing-page",
      pages = {},
    },
    {
      name = "non-contiguous-page-index",
      pages = {
        { page_index = 1, path = vim.fn.tempname() .. ".png", width_px = 20, height_px = 10 },
      },
    },
    {
      name = "duplicate-page",
      opts = { job_count = 2 },
      pages = {
        { page_index = 0, path = vim.fn.tempname() .. ".png", width_px = 20, height_px = 10 },
        { page_index = 0, path = vim.fn.tempname() .. ".png", width_px = 20, height_px = 10 },
      },
    },
    {
      name = "out-of-range-page",
      pages = {
        { page_index = 2, path = vim.fn.tempname() .. ".png", width_px = 20, height_px = 10 },
      },
    },
    {
      name = "invalid-path",
      pages = {
        { page_index = 0, path = "", width_px = 20, height_px = 10 },
      },
    },
  }

  for _, case in ipairs(cases) do
    make_service_response_harness("contract-" .. case.name, case.opts or {}, function(ctx)
      for _, page in ipairs(case.pages) do
        if type(page.path) == "string" and page.path ~= "" then
          write_file(page.path, "png")
        end
      end
      feed_service_response(ctx.full_stdout, {
        type = "compile_result",
        request_id = ctx.request.request_id,
        status = "ok",
        pages = case.pages,
        diagnostics = {},
      })
      wait_until_service_request_cleared(ctx.state, ctx.bufnr)
      assert_eq(ctx.state.active_service_requests[ctx.bufnr], nil, case.name .. " should clear active meta")
      for _, job in ipairs(ctx.request.jobs) do
        assert_eq(
          ctx.state.machine_state.overlays[job.overlay_id],
          nil,
          case.name .. " should retire and GC candidate overlay"
        )
      end
      for _, page in ipairs(case.pages) do
        if type(page.path) == "string" and page.path ~= "" then
          assert_eq(vim.uv.fs_stat(page.path), nil, case.name .. " should clean response artifact")
        end
      end
    end)
  end
end

local function test_service_success_clears_active_meta()
  make_service_response_harness("success-clears-active", {}, function(ctx)
    local page_path = vim.fn.tempname() .. ".png"
    write_file(page_path, "png")
    with_stubbed_extmark(function()
      feed_service_response(ctx.full_stdout, {
        type = "compile_result",
        request_id = ctx.request.request_id,
        status = "ok",
        pages = {
          { page_index = 0, path = page_path, width_px = 20, height_px = 10 },
        },
        diagnostics = {},
        compile_us = 10,
        render_us = 20,
        rendered_pages = 1,
      })
      wait_until_service_request_cleared(ctx.state, ctx.bufnr)
    end)
    assert_eq(ctx.state.active_service_requests[ctx.bufnr], nil, "successful response should clear active meta")
    assert_eq(ctx.state._last_service_bench.request_id, ctx.request.request_id, "success should record bench data")
  end)
end

local function test_service_one_dirty_slot_keeps_full_shape_and_commits_once()
  make_service_response_harness("one-dirty-slot", {
    jobs = {
      {
        request_page_index = 1,
        slot_id = "slot:1",
        node_id = "node:clean:1",
        is_stub = true,
        slot_dirty = false,
      },
      {
        request_page_index = 2,
        slot_id = "slot:2",
        overlay_id = "overlay:dirty:2",
        node_id = "node:dirty:2",
        slot_dirty = true,
      },
      {
        request_page_index = 3,
        slot_id = "slot:3",
        node_id = "node:clean:3",
        is_stub = true,
        slot_dirty = false,
      },
    },
  }, function(ctx)
    local msg = vim.json.decode(vim.trim(ctx.spawned[1].stdio[1].writes[1]))
    assert_truthy(msg.source_text:find("slot%-000001%.typ") ~= nil, "full main should include clean slot 1")
    assert_truthy(msg.source_text:find("slot%-000002%.typ") ~= nil, "full main should include dirty slot 2")
    assert_truthy(msg.source_text:find("slot%-000003%.typ") ~= nil, "full main should include clean slot 3")

    local paths = {
      vim.fn.tempname() .. "-1.png",
      vim.fn.tempname() .. "-2.png",
      vim.fn.tempname() .. "-3.png",
    }
    for _, path in ipairs(paths) do
      write_file(path, "png")
    end

    with_stubbed_extmark(function(calls)
      feed_service_response(ctx.full_stdout, {
        type = "compile_result",
        request_id = ctx.request.request_id,
        status = "ok",
        pages = {
          { page_index = 0, path = paths[1], width_px = 20, height_px = 10, cached = true },
          { page_index = 1, path = paths[2], width_px = 20, height_px = 10 },
          { page_index = 2, path = paths[3], width_px = 20, height_px = 10, cached = true },
        },
        diagnostics = {},
        rendered_pages = 1,
      })
      wait_until_service_request_cleared(ctx.state, ctx.bufnr)
      assert_eq(#calls.created, 1, "response containing all pages should upload only the dirty overlay")
    end)

    assert_eq(ctx.state._last_service_bench.dispatched, 1, "only dirty slot should dispatch")
    assert_eq(ctx.state._last_service_bench.skipped_cached, 2, "clean slots should be skipped")
  end)
end

local function test_service_ignores_context_leading_pages()
  make_service_response_harness("leading-context-pages", { job_count = 2 }, function(ctx)
    local paths = {
      context = vim.fn.tempname() .. "-context.png",
      slot1 = vim.fn.tempname() .. "-slot1.png",
      slot2 = vim.fn.tempname() .. "-slot2.png",
    }
    for _, path in pairs(paths) do
      write_file(path, "png")
    end

    with_stubbed_extmark(function(calls)
      feed_service_response(ctx.full_stdout, {
        type = "compile_result",
        request_id = ctx.request.request_id,
        status = "ok",
        pages = {
          { page_index = 0, path = paths.context, width_px = 2000, height_px = 2000 },
          { page_index = 1, path = paths.slot1, width_px = 20, height_px = 10 },
          { page_index = 2, path = paths.slot2, width_px = 30, height_px = 10 },
        },
        diagnostics = {},
        rendered_pages = 3,
      })
      wait_until_service_request_cleared(ctx.state, ctx.bufnr)

      assert_eq(#calls.created, 2, "leading context page should not be uploaded as an overlay")
      assert_eq(calls.created[1].path, paths.slot1, "first job should use first slot page after context")
      assert_eq(calls.created[2].path, paths.slot2, "second job should use second slot page after context")
    end)

    assert_eq(vim.uv.fs_stat(paths.context), nil, "leading context artifact should be cleaned")
    assert_eq(ctx.state._last_service_bench.leading_pages, 1, "bench should record ignored leading pages")
    assert_eq(ctx.state._last_service_bench.total_pages, 3, "bench should keep service page count")
  end)
end

local function test_service_stale_response_cleans_candidates()
  make_service_response_harness("stale-changedtick", {}, function(ctx)
    vim.api.nvim_buf_set_lines(ctx.bufnr, 0, -1, false, { "$y$" })
    local page_path = vim.fn.tempname() .. ".png"
    write_file(page_path, "png")
    feed_service_response(ctx.full_stdout, {
      type = "compile_result",
      request_id = ctx.request.request_id,
      status = "ok",
      pages = {
        { page_index = 0, path = page_path, width_px = 20, height_px = 10 },
      },
      diagnostics = {},
    })
    wait_until_service_request_cleared(ctx.state, ctx.bufnr)
    assert_eq(ctx.state.active_service_requests[ctx.bufnr], nil, "stale response should clear active meta")
    assert_eq(
      ctx.state.machine_state.overlays[ctx.request.jobs[1].overlay_id],
      nil,
      "stale response should GC candidate"
    )
    assert_eq(vim.uv.fs_stat(page_path), nil, "stale response should clean artifact")
  end)

  make_service_response_harness("stale-layout", {}, function(ctx)
    ctx.state.machine_state.buffers[ctx.bufnr].layout_version = 2
    local page_path = vim.fn.tempname() .. ".png"
    write_file(page_path, "png")
    feed_service_response(ctx.full_stdout, {
      type = "compile_result",
      request_id = ctx.request.request_id,
      status = "ok",
      pages = {
        { page_index = 0, path = page_path, width_px = 20, height_px = 10 },
      },
      diagnostics = {},
    })
    wait_until_service_request_cleared(ctx.state, ctx.bufnr)
    assert_eq(
      ctx.state.machine_state.overlays[ctx.request.jobs[1].overlay_id],
      nil,
      "layout-stale response should GC candidate"
    )
  end)

  make_service_response_harness("stale-active-request", {}, function(ctx)
    ctx.state.machine_state.buffers[ctx.bufnr].active_request_id = "request:newer"
    local page_path = vim.fn.tempname() .. ".png"
    write_file(page_path, "png")
    feed_service_response(ctx.full_stdout, {
      type = "compile_result",
      request_id = ctx.request.request_id,
      status = "ok",
      pages = {
        { page_index = 0, path = page_path, width_px = 20, height_px = 10 },
      },
      diagnostics = {},
    })
    wait_until_service_request_cleared(ctx.state, ctx.bufnr)
    assert_eq(
      ctx.state.machine_state.overlays[ctx.request.jobs[1].overlay_id],
      nil,
      "active-request mismatch should GC candidate"
    )
  end)
end

local function test_service_write_failure_cleans_active_request()
  make_service_response_harness("stdin-write-failure", { uv_opts = { write_error = "boom" } }, function(ctx)
    vim.wait(100, function()
      return ctx.state.active_service_requests[ctx.bufnr] == nil
    end)
    assert_eq(ctx.state.active_service_requests[ctx.bufnr], nil, "stdin write failure should clear active meta")
    assert_eq(
      ctx.state.machine_state.overlays[ctx.request.jobs[1].overlay_id],
      nil,
      "stdin write failure should GC candidate overlay"
    )
  end)
end

local function test_service_spawn_failure_cleans_candidate()
  local root = make_temp_tree("spawn-failure")
  local main_path = vim.fs.joinpath(root, "main.typ")
  write_file(main_path, "$x$")
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, main_path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$" })
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local state = fresh_state()
  state.machine_state.buffers[bufnr] = {
    bufnr = bufnr,
    project_scope_id = "project:spawn",
    buffer_version = tick,
    layout_version = 1,
    render_epoch = 1,
    active_request_id = "request:spawn",
    nodes = {
      ["node:spawn"] = {
        node_id = "node:spawn",
        bufnr = bufnr,
        project_scope_id = "project:spawn",
        item_idx = 1,
        node_type = "math",
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        status = "pending",
        candidate_overlay_id = "overlay:spawn",
      },
    },
    node_order = { "node:spawn" },
  }
  state.machine_state.overlays["overlay:spawn"] = {
    overlay_id = "overlay:spawn",
    owner_node_id = "node:spawn",
    owner_bufnr = bufnr,
    owner_project_scope_id = "project:spawn",
    request_id = "request:spawn",
    page_index = 1,
    render_epoch = 1,
    buffer_version = tick,
    layout_version = 1,
    status = "rendering",
  }

  with_stubbed_uv(function()
    package.loaded["typst-concealer"] = {
      config = {
        typst_location = "typst",
        use_compiler_service = true,
        service_binary = "typst-concealer-service-test",
        ppi = 300,
        compiler_args = {},
        get_root = function()
          return root
        end,
        get_inputs = nil,
        get_preamble_file = nil,
        do_diagnostics = false,
        header = "",
      },
      _styling_prelude = "",
    }
    require("typst-concealer.session").render_request_via_service(bufnr, {
      request_id = "request:spawn",
      bufnr = bufnr,
      project_scope_id = "project:spawn",
      render_epoch = 1,
      buffer_version = tick,
      layout_version = 1,
      jobs = {
        {
          request_page_index = 1,
          overlay_id = "overlay:spawn",
          node_id = "node:spawn",
          bufnr = bufnr,
          project_scope_id = "project:spawn",
          render_epoch = 1,
          buffer_version = tick,
          layout_version = 1,
          item_idx = 1,
          range = { 0, 0, 0, 3 },
          display_range = { 0, 0, 0, 3 },
          source_text = "$x$",
          str = "$x$",
          prelude_count = 0,
          semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        },
      },
    })
  end, { spawn_fails = true })

  assert_eq(state.active_service_requests[bufnr], nil, "spawn failure should not leave active meta")
  assert_eq(state.machine_state.overlays["overlay:spawn"], nil, "spawn failure should GC candidate overlay")
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

local function test_service_diagnostics_mapping()
  make_service_response_harness("diagnostics-exact", { do_diagnostics = true }, function(ctx)
    local meta = ctx.state.active_service_requests[ctx.bufnr]
    local slot_path, seg = next(meta.slot_line_maps or {})
    assert_truthy(slot_path ~= nil and seg ~= nil, "service diagnostics should record slot sidecar maps")
    feed_service_response(ctx.full_stdout, {
      type = "compile_result",
      request_id = ctx.request.request_id,
      status = "error",
      pages = {},
      diagnostics = {
        { file = slot_path, line = seg.gen_start, column = seg.gen_start_col, message = "body failed" },
      },
    })
    wait_until_service_request_cleared(ctx.state, ctx.bufnr)
    local item = ctx.state.watch_diagnostics[ctx.bufnr].full[1]
    assert_eq(real_path(item.filename), real_path(ctx.main_path), "exact body diagnostic should map to source file")
    assert_eq(item.lnum, 1, "exact body diagnostic should map to source line")
    assert_truthy(item.text:find("%[service%] body failed") ~= nil, "exact diagnostic should use service prefix")
  end)

  make_service_response_harness(
    "diagnostics-generated",
    { do_diagnostics = true, header = "#let broken = )\n" },
    function(ctx)
      local meta = ctx.state.active_service_requests[ctx.bufnr]
      feed_service_response(ctx.full_stdout, {
        type = "compile_result",
        request_id = ctx.request.request_id,
        status = "error",
        pages = {},
        diagnostics = {
          { line = 1, column = 1, message = "wrapper failed" },
        },
      })
      wait_until_service_request_cleared(ctx.state, ctx.bufnr)
      local item = ctx.state.watch_diagnostics[ctx.bufnr].full[1]
      assert_eq(item.filename, meta.generated_input_path, "generated diagnostic should point to generated input")
      assert_truthy(
        item.text:find("%[service/generated%] wrapper failed") ~= nil,
        "generated diagnostic should use generated prefix"
      )
    end
  )

  make_service_response_harness("diagnostics-slot-generated", {
    do_diagnostics = true,
    runtime_preludes = { "#let broken = )\n" },
    jobs = {
      {
        request_page_index = 1,
        slot_id = "slot:1",
        overlay_id = "overlay:slot-generated",
        node_id = "node:slot-generated",
        prelude_count = 1,
      },
    },
  }, function(ctx)
    local meta = ctx.state.active_service_requests[ctx.bufnr]
    local slot_path = next(meta.slot_line_maps or {})
    feed_service_response(ctx.full_stdout, {
      type = "compile_result",
      request_id = ctx.request.request_id,
      status = "error",
      pages = {},
      diagnostics = {
        { file = slot_path, line = 1, column = 1, message = "slot wrapper failed" },
      },
    })
    wait_until_service_request_cleared(ctx.state, ctx.bufnr)
    local item = ctx.state.watch_diagnostics[ctx.bufnr].full[1]
    assert_eq(item.filename, slot_path, "slot wrapper diagnostic should point to generated sidecar")
    assert_truthy(
      item.text:find("%[service/generated%] slot wrapper failed") ~= nil,
      "slot wrapper diagnostic should use generated prefix"
    )
  end)

  make_service_response_harness("diagnostics-external", { do_diagnostics = true }, function(ctx)
    local external = vim.fs.joinpath(ctx.root, "external.typ")
    write_file(external, "#let bad = )\n")
    external = real_path(external)
    feed_service_response(ctx.full_stdout, {
      type = "compile_result",
      request_id = ctx.request.request_id,
      status = "error",
      pages = {},
      diagnostics = {
        { file = external, line = 1, column = 2, message = "external failed" },
      },
    })
    wait_until_service_request_cleared(ctx.state, ctx.bufnr)
    local item = ctx.state.watch_diagnostics[ctx.bufnr].full[1]
    assert_eq(real_path(item.filename), real_path(external), "external diagnostic should keep external file")
    assert_truthy(
      item.text:find("%[service/external%] external failed") ~= nil,
      "external diagnostic should use external prefix"
    )
  end)
end

local function test_preview_service_routing_and_stale_cleanup()
  make_service_response_harness("preview-routing", {}, function(ctx)
    ctx.state.active_preview_service_requests[ctx.bufnr] = {
      request_id = "preview:same-id",
      item = { bufnr = ctx.bufnr, range = { 0, 0, 0, 3 }, preview_request_id = "preview:same-id" },
    }
    feed_service_response(ctx.full_stdout, {
      type = "compile_result",
      request_id = "preview:same-id",
      status = "ok",
      pages = {},
      diagnostics = {},
    })
    vim.wait(50, function()
      return true
    end)
    assert_truthy(
      ctx.state.active_preview_service_requests[ctx.bufnr] ~= nil,
      "full backend response must not consume active preview request"
    )

    local page_path = vim.fn.tempname() .. ".png"
    write_file(page_path, "png")
    feed_service_response(ctx.preview_stdout, {
      type = "compile_result",
      request_id = "preview:same-id",
      status = "ok",
      pages = {
        { page_index = 0, path = page_path, width_px = 20, height_px = 10 },
      },
      diagnostics = {},
    })
    vim.wait(100, function()
      return ctx.state.active_preview_service_requests[ctx.bufnr] == nil
    end)
    assert_eq(vim.uv.fs_stat(page_path), nil, "stale preview response should safe-unlink artifact")
  end)
end

local function test_preview_service_uses_last_page_after_context()
  make_service_response_harness("preview-leading-context", {}, function(ctx)
    local state = ctx.state
    local runtime = require("typst-concealer.machine.runtime")
    local preview_request_id = "preview:leading-context"
    runtime.get_ui_buffer(ctx.bufnr).preview.active_request_id = preview_request_id

    local extmark_id = vim.api.nvim_buf_set_extmark(ctx.bufnr, state.ns_id, 0, 0, {
      end_row = 0,
      end_col = 3,
    })
    local item = {
      bufnr = ctx.bufnr,
      image_id = 701,
      extmark_id = extmark_id,
      range = { 0, 0, 0, 3 },
      str = "$x$",
      source_str = "$x$",
      preview_request_id = preview_request_id,
      semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
    }
    state.item_by_image_id[item.image_id] = item
    state.image_id_to_extmark[item.image_id] = extmark_id
    state.active_preview_service_requests[ctx.bufnr] = {
      request_id = preview_request_id,
      item = item,
      sent_at = vim.uv.hrtime(),
    }

    local context_path = vim.fn.tempname() .. "-preview-context.png"
    local preview_path = vim.fn.tempname() .. "-preview-slot.png"
    write_file(context_path, "png")
    write_file(preview_path, "png")

    local old_png = package.loaded["typst-concealer.png-lua"]
    package.loaded["typst-concealer.png-lua"] = function()
      return { width = 20, height = 10 }
    end

    local ok_run, err = pcall(function()
      with_stubbed_extmark(function(calls)
        feed_service_response(ctx.preview_stdout, {
          type = "compile_result",
          request_id = preview_request_id,
          status = "ok",
          pages = {
            { page_index = 0, path = context_path, width_px = 2000, height_px = 2000 },
            { page_index = 1, path = preview_path, width_px = 20, height_px = 10 },
          },
          diagnostics = {},
          rendered_pages = 2,
        })
        vim.wait(100, function()
          return state.active_preview_service_requests[ctx.bufnr] == nil
        end)

        assert_eq(#calls.created, 1, "preview should upload only the last page")
        assert_eq(calls.created[1].path, preview_path, "preview should use the slot page after context")
      end)
    end)

    package.loaded["typst-concealer.png-lua"] = old_png
    if not ok_run then
      error(err)
    end

    assert_eq(vim.uv.fs_stat(context_path), nil, "preview context artifact should be cleaned")
    assert_truthy(vim.uv.fs_stat(preview_path) ~= nil, "accepted preview artifact should stay live")
  end)
end

local function test_live_preview_keeps_old_highlight_until_replacement_commits()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x+y$" })
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, 2 })

  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    _enabled_buffers = { [bufnr] = true },
    _styling_prelude = "",
    is_render_allowed = function()
      return true
    end,
    config = {
      live_preview_enabled = true,
      use_compiler_service = false,
      ppi = 300,
      header = "",
      compiler_args = {},
      conceal_in_normal = false,
      cursor_hover_throttle_ms = 0,
    },
  }

  local preview_requests = {}
  package.loaded["typst-concealer.session"] = {
    render_preview_tail = function(_, item)
      preview_requests[#preview_requests + 1] = item
    end,
    clear_preview_tail = function() end,
  }

  local source_item = make_render_item({
    bufnr = bufnr,
    range = { 0, 0, 0, 5 },
    display_range = { 0, 0, 0, 5 },
    str = "$x+y$",
    image_id = 101,
    extmark_id = 201,
    page_path = "/tmp/source.png",
    page_stamp = "source",
    natural_cols = 5,
    natural_rows = 1,
    source_rows = 1,
  })
  state.buffer_render_state[bufnr] = {
    full_items = { source_item },
    lingering_items = {},
    line_to_items = { [0] = { source_item } },
    runtime_preludes = {},
  }
  state.item_by_image_id[source_item.image_id] = source_item
  state.image_id_to_extmark[source_item.image_id] = source_item.extmark_id
  state.image_ids_in_use[source_item.image_id] = bufnr

  local old_preview = make_render_item({
    bufnr = bufnr,
    range = { 0, 0, 0, 5 },
    display_range = { 0, 0, 0, 5 },
    str = "$#text(red)[$x$]+y$",
    source_str = "$x+y$",
    image_id = 301,
    extmark_id = 401,
    page_path = "/tmp/old-highlight.png",
    page_stamp = "old-highlight",
    natural_cols = 6,
    natural_rows = 1,
    source_rows = 1,
    render_target = "preview_float",
    source_image_id = source_item.image_id,
  })
  state.item_by_image_id[old_preview.image_id] = old_preview
  state.image_id_to_extmark[old_preview.image_id] = old_preview.extmark_id
  state.image_ids_in_use[old_preview.image_id] = bufnr

  local bs = state.get_buf_state(bufnr)
  bs.preview_item = old_preview
  bs.preview_last_rendered_item = old_preview
  bs.preview_render_key = "old-key"
  bs.preview_image = {
    extmark_id = old_preview.extmark_id,
    target_bufnr = bufnr,
    natural_cols = old_preview.natural_cols,
    natural_rows = old_preview.natural_rows,
    image_id = old_preview.image_id,
  }
  bs.preview_source_image_id = source_item.image_id
  bs.preview_source_page_stamp = old_preview.page_stamp
  bs.preview_source_range = vim.deepcopy(source_item.range)

  local runtime = require("typst-concealer.machine.runtime")
  runtime.set_preview_render_key(bufnr, "old-key")
  runtime.mark_preview_rendered(bufnr)

  local original_get_parser = vim.treesitter.get_parser
  vim.treesitter.get_parser = function()
    return {
      parse = function()
        return {
          {
            root = function()
              return {
                named_descendant_for_range = function()
                  return nil
                end,
              }
            end,
          },
        }
      end,
    }
  end

  local ok_run, err = pcall(function()
    with_stubbed_extmark(function(calls)
      require("typst-concealer.plan").render_live_typst_preview(bufnr)
      require("typst-concealer.plan").render_live_typst_preview(bufnr)

      assert_eq(#calls.virtual, 0, "replacement preview should not show the unhighlighted source image first")
      assert_eq(#calls.cleared, 0, "old highlighted preview image should remain allocated while replacement renders")
      assert_eq(bs.preview_image.image_id, old_preview.image_id, "old highlighted preview should stay visible")
      assert_eq(state.item_by_image_id[old_preview.image_id], old_preview, "old preview image should remain indexed")
      assert_eq(#preview_requests, 1, "replacement preview request should be dispatched")
      assert_truthy(preview_requests[1].preview_request_id ~= nil, "replacement preview request should carry identity")
      assert_eq(preview_requests[1].extmark_id, old_preview.extmark_id, "replacement should reuse the visible extmark")
      assert_truthy(preview_requests[1].image_id ~= old_preview.image_id, "replacement should allocate a new image id")
    end)
  end)

  vim.treesitter.get_parser = original_get_parser
  vim.api.nvim_buf_delete(bufnr, { force = true })
  if not ok_run then
    error(err)
  end
end

local function test_service_artifact_cleanup_preserves_live_paths()
  local state = fresh_state()
  local session_mod = require("typst-concealer.session")
  local path = vim.fn.tempname() .. ".png"
  write_file(path, "png")

  state.machine_state.overlays["overlay:live"] = {
    overlay_id = "overlay:live",
    owner_bufnr = 1,
    page_path = path,
    status = "visible",
  }

  session_mod._safe_unlink_service_artifact(path)
  assert_truthy(vim.uv.fs_stat(path) ~= nil, "live service PNGs must not be unlinked")

  state.machine_state.overlays["overlay:live"].status = "retired"
  session_mod._safe_unlink_service_artifact(path)
  assert_eq(vim.uv.fs_stat(path), nil, "unreferenced service PNGs should be unlinked")
end

local function test_wrapper_cache_tracks_root_signature()
  reset_modules()
  local wrapper = require("typst-concealer.wrapper")
  local base = make_temp_tree("wrapper-cache")
  local outside_root = vim.fs.joinpath(base, "outside")
  local outside_theme_dir = vim.fs.joinpath(outside_root, "root")
  local project_root = vim.fs.joinpath(base, "project")
  local project_doc = vim.fs.joinpath(project_root, "doc")
  assert(vim.fn.mkdir(outside_theme_dir, "p") == 1)
  assert(vim.fn.mkdir(project_doc, "p") == 1)
  local theme_path = vim.fs.joinpath(outside_theme_dir, "theme.typ")
  write_file(theme_path, "#let theme = 1\n")
  theme_path = real_path(theme_path)
  outside_root = real_path(outside_root)
  project_root = real_path(project_root)
  project_doc = real_path(project_doc)
  package.loaded["typst-concealer"] = {
    config = {
      header = '#import "' .. theme_path .. '": (theme)\n',
    },
    _styling_prelude = "",
  }

  local item = {
    bufnr = 1,
    range = { 0, 0, 0, 0 },
    str = "[]",
    prelude_count = 0,
    semantics = { constraint_kind = "inline" },
  }
  local cache = { item_fragments = {} }
  local doc1 = wrapper.build_batch_document(
    { item },
    project_doc,
    project_doc,
    outside_root,
    "full",
    {},
    "",
    false,
    cache
  )
  local doc2 = wrapper.build_batch_document(
    { item },
    project_doc,
    project_doc,
    project_root,
    "full",
    {},
    "",
    false,
    cache
  )

  assert_truthy(
    doc1:find('#import "/root/theme.typ": %(theme%)', 1, false) ~= nil,
    "first root should rewrite header against outside root"
  )
  assert_truthy(
    doc2:find('#import "' .. theme_path .. '": (theme)', 1, true) ~= nil,
    "second root should not reuse cached rewritten header"
  )
end

local function test_inline_wrapper_keeps_single_row_width_intrinsic()
  reset_modules()
  local state = require("typst-concealer.state")
  state._cell_px_w = 20
  state._cell_px_h = 40
  package.loaded["typst-concealer"] = {
    config = {
      math_baseline_pt = 10,
    },
  }

  local wrapper = require("typst-concealer.wrapper")
  local _, single_suffix = wrapper.make_inline_sizing_wrap(1)
  assert_truthy(
    single_suffix:find("block(width: __d.width, height: __mh", 1, true) ~= nil,
    "single-row intrinsic wrapper should use measured content width"
  )
  assert_truthy(
    single_suffix:find("let __tw", 1, true) == nil,
    "single-row intrinsic wrapper should not add full-cell right padding"
  )

  local _, multi_suffix = wrapper.make_inline_sizing_wrap(2)
  assert_truthy(
    multi_suffix:find("let __tw = __cols * __mw", 1, true) ~= nil,
    "multi-row intrinsic wrapper should keep terminal-cell snapping"
  )
end

local function test_remote_urls_do_not_rewrite_against_root()
  reset_modules()
  local path_rewrite = require("typst-concealer.path-rewrite")
  local base = make_temp_tree("remote-url")
  local project = vim.fs.joinpath(base, "project")
  local effective_root = vim.fs.joinpath(base, "root")
  assert(vim.fn.mkdir(project, "p") == 1)
  assert(vim.fn.mkdir(effective_root, "p") == 1)
  project = real_path(project)
  effective_root = real_path(effective_root)

  local rewritten = path_rewrite.rewrite_paths('#import "https://example.com/theme.typ": theme', {
    bufnr = 1,
    buf_dir = project,
    source_root = project,
    effective_root = effective_root,
  })

  assert_eq(
    rewritten,
    '#import "https://example.com/theme.typ": theme',
    "remote URLs should bypass root-relative path rewriting"
  )
end

local function test_named_path_args_rewrite_local_paths()
  reset_modules()
  local path_rewrite = require("typst-concealer.path-rewrite")
  local base = make_temp_tree("named-path")
  local project = vim.fs.joinpath(base, "project")
  local assets = vim.fs.joinpath(project, "assets")
  local effective_root = base
  assert(vim.fn.mkdir(assets, "p") == 1)
  write_file(vim.fs.joinpath(assets, "figure.png"), "png")
  project = real_path(project)
  effective_root = real_path(effective_root)

  local rewritten = path_rewrite.rewrite_paths('#image_viewer(path: "assets/figure.png")', {
    bufnr = 1,
    buf_dir = project,
    source_root = project,
    effective_root = effective_root,
  })

  assert_eq(
    rewritten,
    '#image_viewer(path: "/project/assets/figure.png")',
    "named path args should rewrite local asset paths against the effective root"
  )
end

local function test_named_path_args_preserve_remote_urls()
  reset_modules()
  local path_rewrite = require("typst-concealer.path-rewrite")
  local base = make_temp_tree("named-path-url")
  local project = vim.fs.joinpath(base, "project")
  local effective_root = vim.fs.joinpath(base, "root")
  assert(vim.fn.mkdir(project, "p") == 1)
  assert(vim.fn.mkdir(effective_root, "p") == 1)
  project = real_path(project)
  effective_root = real_path(effective_root)

  local rewritten = path_rewrite.rewrite_paths('#image_viewer(path: "https://example.com/figure.png")', {
    bufnr = 1,
    buf_dir = project,
    source_root = project,
    effective_root = effective_root,
  })

  assert_eq(
    rewritten,
    '#image_viewer(path: "https://example.com/figure.png")',
    "named path args should preserve remote URLs"
  )
end

local function test_machine_reducer_enforces_request_identity_and_delayed_retire()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state, effects = reducer.reduce(state, scan_event({ make_scanned_node() }))
  assert_eq(#effects, 0, "scan should not produce side effects")

  local buf = state.buffers[1]
  local node = buf.nodes[buf.node_order[1]]
  assert_eq(node.status, "pending", "new scanned node should await render")

  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  assert_eq(count_effects(effects, "ensure_overlay_placeholder"), 1, "new node should get a placeholder")
  local request = first_effect(effects, "request_full_render")
  assert_truthy(request, "full render should request watch rendering")
  local overlay = state.overlays[request.request.jobs[1].overlay_id]
  assert_eq(overlay.request_id, request.request.request_id, "overlay request id should be immutable candidate identity")
  assert_eq(overlay.page_index, 1, "overlay should record request page index")

  local wrong_ready = page_ready_event(overlay, { request_id = "request:wrong" })
  local rejected_state
  rejected_state, effects = reducer.reduce(state, wrong_ready)
  assert_eq(#effects, 0, "wrong request id should be rejected")
  assert_eq(
    rejected_state.overlays[overlay.overlay_id].status,
    "placeholder",
    "rejected page should not update overlay"
  )

  state, effects = reducer.reduce(state, page_ready_event(overlay))
  assert_eq(effects[1].kind, "commit_overlay", "accepted page should request commit")
  state, effects = reducer.reduce(state, {
    type = "overlay_commit_succeeded",
    overlay_id = overlay.overlay_id,
    node_id = overlay.owner_node_id,
  })
  assert_eq(#effects, 0, "first commit has no old overlay to retire")

  node = state.buffers[1].nodes[overlay.owner_node_id]
  assert_eq(node.status, "stable", "committed node should become stable")
  assert_eq(node.visible_overlay_id, overlay.overlay_id, "candidate should become visible")
  assert_eq(state.buffers[1].active_request_id, nil, "completed request should no longer be active")

  state, effects = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        source_text = "$y$",
        source_text_hash = "hash:y",
      }),
    }, { buffer_version = 2 })
  )
  node = state.buffers[1].nodes[overlay.owner_node_id]
  assert_eq(node.status, "stale", "changed visible node should become stale")
  assert_eq(node.visible_overlay_id, overlay.overlay_id, "old overlay should stay visible while stale")

  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  assert_eq(count_effects(effects, "ensure_overlay_placeholder"), 0, "stale visible node must not be blanked")
  assert_eq(count_effects(effects, "abandon_request"), 0, "new request should not abandon a completed request")
  request = first_effect(effects, "request_full_render")
  assert_truthy(request, "changed node should request a new render")
  local next_overlay = state.overlays[request.request.jobs[1].overlay_id]
  assert_eq(next_overlay.status, "rendering", "visible stale node should render candidate off-screen")
  assert_truthy(next_overlay.request_id ~= overlay.request_id, "new candidate must not reuse old request identity")

  state, effects = reducer.reduce(state, page_ready_event(next_overlay))
  assert_eq(effects[1].kind, "commit_overlay", "new candidate should commit after page ready")
  state, effects = reducer.reduce(state, {
    type = "overlay_commit_succeeded",
    overlay_id = next_overlay.overlay_id,
    node_id = next_overlay.owner_node_id,
  })
  assert_eq(effects[1].kind, "retire_overlay", "old visible overlay should retire only after new commit")
  assert_eq(effects[1].overlay_id, overlay.overlay_id, "retire effect should target the previous visible overlay")
end

local function test_machine_reducer_rebinds_stable_visible_overlay_on_precise_dirty_range()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state = reducer.reduce(state, scan_event({ make_scanned_node() }))
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  local request = first_effect(effects, "request_full_render")
  local overlay = state.overlays[request.request.jobs[1].overlay_id]
  state = reducer.reduce(state, {
    type = "overlay_resources_allocated",
    overlay_id = overlay.overlay_id,
    image_id = 31,
    extmark_id = 41,
    binding_buffer_version = 1,
    binding_layout_version = 1,
    binding_display_range = { 0, 0, 0, 3 },
  })
  overlay = state.overlays[overlay.overlay_id]
  state = reducer.reduce(state, page_ready_event(overlay))
  state = reducer.reduce(state, {
    type = "overlay_commit_succeeded",
    overlay_id = overlay.overlay_id,
    node_id = overlay.owner_node_id,
  })

  state, effects = reducer.reduce(
    state,
    scan_event({ make_scanned_node() }, {
      buffer_version = 2,
      binding_dirty_ranges = {
        { 0, 1, 0, 2 },
      },
    })
  )

  assert_eq(count_effects(effects, "request_full_render"), 0, "unchanged render input should not recompile")
  local bind = first_effect(effects, "bind_overlay")
  assert_truthy(bind ~= nil, "dirty stable node should request display rebind")
  assert_eq(bind.overlay_id, overlay.overlay_id, "rebind should target the visible overlay identity")
  assert_eq(bind.request_id, overlay.request_id, "rebind should keep the visible render request identity")
  assert_eq(bind.buffer_version, 2, "rebind should bind the current scan version")

  state = reducer.reduce(state, {
    type = "overlay_bindings_batch_succeeded",
    entries = {
      {
        overlay_id = overlay.overlay_id,
        request_id = overlay.request_id,
        node_id = overlay.owner_node_id,
        bufnr = 1,
        extmark_id = 41,
        buffer_version = 2,
        layout_version = 1,
        display_range = { 0, 0, 0, 3 },
      },
    },
  })
  assert_eq(
    state.overlays[overlay.overlay_id].binding_buffer_version,
    2,
    "successful rebind should update overlay binding epoch"
  )
end

local function test_machine_reducer_does_not_rebind_stable_overlay_for_disjoint_dirty_range()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state = reducer.reduce(state, scan_event({ make_scanned_node() }))
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  local request = first_effect(effects, "request_full_render")
  local overlay = state.overlays[request.request.jobs[1].overlay_id]
  state = reducer.reduce(state, {
    type = "overlay_resources_allocated",
    overlay_id = overlay.overlay_id,
    image_id = 31,
    extmark_id = 41,
    binding_buffer_version = 1,
    binding_layout_version = 1,
    binding_display_range = { 0, 0, 0, 3 },
  })
  overlay = state.overlays[overlay.overlay_id]
  state = reducer.reduce(state, page_ready_event(overlay))
  state = reducer.reduce(state, {
    type = "overlay_commit_succeeded",
    overlay_id = overlay.overlay_id,
    node_id = overlay.owner_node_id,
  })

  state, effects = reducer.reduce(
    state,
    scan_event({ make_scanned_node() }, {
      buffer_version = 2,
      binding_dirty_ranges = {
        { 0, 10, 0, 11 },
      },
    })
  )

  assert_eq(count_effects(effects, "bind_overlay"), 0, "disjoint dirty ranges should not rebind visible overlays")
  assert_eq(count_effects(effects, "request_full_render"), 0, "disjoint dirty ranges should not recompile")
end

local function test_machine_reducer_retires_deleted_only_formula_on_render_boundary()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state = reducer.reduce(state, scan_event({ make_scanned_node() }))
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  local request = first_effect(effects, "request_full_render")
  local overlay = state.overlays[request.request.jobs[1].overlay_id]
  state = reducer.reduce(state, page_ready_event(overlay))
  state = reducer.reduce(state, {
    type = "overlay_commit_succeeded",
    overlay_id = overlay.overlay_id,
    node_id = overlay.owner_node_id,
  })

  state, effects = reducer.reduce(state, scan_event({}))
  local node = state.buffers[1].nodes[overlay.owner_node_id]
  assert_eq(node.status, "orphaned", "missing visible node should become an orphan")
  assert_eq(node.visible_overlay_id, overlay.overlay_id, "orphaned node keeps visible overlay until confirmation")

  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  assert_eq(count_effects(effects, "request_full_render"), 1, "orphan-only buffer should refresh the tombstone slot")
  assert_eq(count_effects(effects, "retire_overlay"), 1, "orphan-only buffer should retire the stale overlay")
  node = state.buffers[1].nodes[overlay.owner_node_id]
  assert_eq(node.status, "deleted_confirmed", "render boundary should finalize deleted node")
  assert_eq(node.visible_overlay_id, nil, "retired orphan should detach visible overlay")
  assert_eq(effects[1].overlay_id, overlay.overlay_id, "render boundary should retire the orphan overlay")
  request = first_effect(effects, "request_full_render")
  assert_eq(#request.request.jobs, 1, "deleted-only render should keep the old slot in the service document")
  assert_eq(request.request.jobs[1].is_tombstone, true, "deleted slot should be rendered as a tombstone")
  state = reducer.reduce(state, {
    type = "render_request_completed",
    bufnr = 1,
    request_id = request.request.request_id,
  })
  assert_eq(state.buffers[1].slots[request.request.jobs[1].slot_id].dirty, false, "completed tombstone should be clean")
end

local function test_machine_reducer_keeps_overlapping_orphan_until_replacement_commit()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state =
    reducer.reduce(state, scan_event({ make_scanned_node({ source_text = "$old$", source_text_hash = "hash:old" }) }))
  local effects
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  local request = first_effect(effects, "request_full_render")
  local old_overlay = state.overlays[request.request.jobs[1].overlay_id]
  state = reducer.reduce(state, page_ready_event(old_overlay))
  state = reducer.reduce(state, {
    type = "overlay_commit_succeeded",
    overlay_id = old_overlay.overlay_id,
    node_id = old_overlay.owner_node_id,
  })

  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        source_text = "$new$",
        source_text_hash = "hash:new",
        context_hash = "ctx:new",
        source_range = { 0, 0, 0, 5 },
        display_range = { 0, 0, 0, 5 },
      }),
    }, { buffer_version = 2 })
  )
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  assert_eq(count_effects(effects, "retire_overlay"), 0, "overlapping orphan should stay until replacement is ready")
  request = first_effect(effects, "request_full_render")
  local new_overlay = state.overlays[first_overlay_job(request).overlay_id]
  state = reducer.reduce(state, page_ready_event(new_overlay))
  state, effects = reducer.reduce(state, {
    type = "overlay_commit_succeeded",
    overlay_id = new_overlay.overlay_id,
    node_id = new_overlay.owner_node_id,
  })
  local retire = first_effect(effects, "retire_overlay")
  assert_truthy(retire ~= nil, "replacement commit should retire overlapping orphan")
  assert_eq(retire.overlay_id, old_overlay.overlay_id, "replacement commit should retire old overlay")
end

local function test_machine_reducer_reuses_range_identity_without_stable_key()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state, effects = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        source_range = { 5, 0, 7, 1 },
        display_range = { 5, 0, 7, 1 },
        source_text = "$\n  alpha beta\n$",
        source_text_hash = "hash:alpha-beta",
      }),
    })
  )
  local node_id = state.buffers[1].node_order[1]
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  local request = first_effect(effects, "request_full_render")
  local overlay = state.overlays[request.request.jobs[1].overlay_id]
  state = reducer.reduce(state, page_ready_event(overlay))
  state = reducer.reduce(state, {
    type = "overlay_commit_succeeded",
    overlay_id = overlay.overlay_id,
    node_id = overlay.owner_node_id,
  })

  state, effects = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        source_range = { 5, 0, 7, 1 },
        display_range = { 5, 0, 7, 1 },
        source_text = "$\n  alpha beta gamma\n$",
        source_text_hash = "hash:alpha-beta-gamma",
      }),
    }, { buffer_version = 2 })
  )
  local buf = state.buffers[1]
  assert_eq(buf.node_order[1], node_id, "range fallback should keep node identity when source changes")
  assert_eq(buf.nodes[node_id].status, "stale", "changed range-matched node should become stale")
  assert_eq(
    buf.nodes[node_id].visible_overlay_id,
    overlay.overlay_id,
    "old overlay should remain until replacement commits"
  )
  assert_eq(#buf.node_order, 1, "range-matched edits should not create orphan nodes")
end

local function test_machine_reducer_identity_adjacent_formula_edit()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        stable_key = nil,
        item_idx = 2,
        source_range = { 0, 4, 0, 7 },
        display_range = { 0, 4, 0, 7 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
    })
  )
  local first_id = state.buffers[1].node_order[1]
  local second_id = state.buffers[1].node_order[2]

  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        stable_key = nil,
        item_idx = 2,
        source_range = { 0, 4, 0, 8 },
        display_range = { 0, 4, 0, 8 },
        source_text = "$bb$",
        source_text_hash = "hash:bb",
      }),
    }, { buffer_version = 2 })
  )

  assert_eq(state.buffers[1].node_order[1], first_id, "editing second adjacent formula should keep first identity")
  assert_eq(state.buffers[1].node_order[2], second_id, "editing second adjacent formula should reuse second identity")
  assert_eq(state.buffers[1].nodes[second_id].status, "pending", "edited second formula should rerender")
end

local function test_machine_reducer_identity_deletion_with_upward_shift()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        stable_key = nil,
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
    })
  )
  local first_id = state.buffers[1].node_order[1]
  local second_id = state.buffers[1].node_order[2]

  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
    }, { buffer_version = 2 })
  )

  assert_eq(
    state.buffers[1].node_order[1],
    second_id,
    "remaining formula should keep its old identity after shifting up"
  )
  assert_eq(
    state.buffers[1].nodes[first_id].status,
    "deleted_confirmed",
    "deleted formula without visible overlay is confirmed"
  )
end

local function test_machine_reducer_identity_insertion_between_formulas()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        stable_key = nil,
        item_idx = 2,
        source_range = { 2, 0, 2, 3 },
        display_range = { 2, 0, 2, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
    })
  )
  local first_id = state.buffers[1].node_order[1]
  local second_id = state.buffers[1].node_order[2]

  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        stable_key = nil,
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$c$",
        source_text_hash = "hash:c",
      }),
      make_scanned_node({
        stable_key = nil,
        item_idx = 3,
        source_range = { 3, 0, 3, 3 },
        display_range = { 3, 0, 3, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
    }, { buffer_version = 2 })
  )

  assert_eq(state.buffers[1].node_order[1], first_id, "first formula should keep identity after insertion")
  assert_eq(state.buffers[1].node_order[3], second_id, "second old formula should keep identity after insertion")
  assert_truthy(state.buffers[1].node_order[2] ~= first_id, "inserted formula should get a fresh identity")
  assert_truthy(state.buffers[1].node_order[2] ~= second_id, "inserted formula should not steal an old identity")
end

local function test_machine_reducer_identity_repeated_identical_formulas()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
      }),
      make_scanned_node({
        stable_key = nil,
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
      }),
    })
  )
  local first_id = state.buffers[1].node_order[1]
  local second_id = state.buffers[1].node_order[2]

  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
      }),
      make_scanned_node({
        stable_key = nil,
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
      }),
    }, { buffer_version = 2 })
  )

  assert_eq(state.buffers[1].node_order[1], first_id, "first repeated formula should keep identity")
  assert_eq(state.buffers[1].node_order[2], second_id, "second repeated formula should keep identity")
end

local function test_machine_reducer_stable_slots_include_clean_pages_for_one_dirty_node()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
      make_scanned_node({
        item_idx = 3,
        source_range = { 2, 0, 2, 3 },
        display_range = { 2, 0, 2, 3 },
        source_text = "$c$",
        source_text_hash = "hash:c",
      }),
    })
  )
  local effects
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  state = commit_overlay_jobs(reducer, state, first_effect(effects, "request_full_render"))

  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        item_idx = 2,
        source_range = { 1, 0, 1, 4 },
        display_range = { 1, 0, 1, 4 },
        source_text = "$bb$",
        source_text_hash = "hash:bb",
      }),
      make_scanned_node({
        item_idx = 3,
        source_range = { 2, 0, 2, 3 },
        display_range = { 2, 0, 2, 3 },
        source_text = "$c$",
        source_text_hash = "hash:c",
      }),
    }, { buffer_version = 2 })
  )
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  local request = first_effect(effects, "request_full_render")
  assert_eq(#request.request.jobs, 3, "one dirty slot should still send every active slot")
  assert_eq(request.request.jobs[1].is_stub, true, "clean first slot should be a service stub")
  assert_truthy(request.request.jobs[2].overlay_id ~= nil, "dirty middle slot should have a candidate overlay")
  assert_eq(request.request.jobs[2].request_page_index, 2, "dirty middle slot should keep page index 2")
  assert_eq(request.request.jobs[3].is_stub, true, "clean last slot should be a service stub")
end

local function test_machine_reducer_stable_slots_append_insertions_without_shifting_pages()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        item_idx = 2,
        source_range = { 2, 0, 2, 3 },
        display_range = { 2, 0, 2, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
    })
  )
  local first_id = state.buffers[1].node_order[1]
  local second_id = state.buffers[1].node_order[2]
  local first_slot = state.buffers[1].nodes[first_id].slot_id
  local second_slot = state.buffers[1].nodes[second_id].slot_id
  local effects
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  state = commit_overlay_jobs(reducer, state, first_effect(effects, "request_full_render"))

  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$c$",
        source_text_hash = "hash:c",
      }),
      make_scanned_node({
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        item_idx = 3,
        source_range = { 3, 0, 3, 3 },
        display_range = { 3, 0, 3, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
    }, { buffer_version = 2 })
  )

  local buf = state.buffers[1]
  assert_eq(buf.slots[first_slot].page_index, 1, "first old slot should keep page index")
  assert_eq(buf.slots[second_slot].page_index, 2, "second old slot should keep page index after insertion")
  local inserted_id = buf.node_order[1]
  local inserted_slot = buf.nodes[inserted_id].slot_id
  assert_eq(buf.slots[inserted_slot].page_index, 3, "inserted node should get an appended slot page")

  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  local request = first_effect(effects, "request_full_render")
  assert_eq(request.request.jobs[1].slot_id, first_slot, "old page 1 should stay in request position 1")
  assert_eq(request.request.jobs[2].slot_id, second_slot, "old page 2 should stay in request position 2")
  assert_eq(request.request.jobs[3].slot_id, inserted_slot, "inserted page should be appended")
end

local function test_machine_reducer_stable_slots_tombstone_deletions_without_shifting_pages()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
      make_scanned_node({
        item_idx = 3,
        source_range = { 2, 0, 2, 3 },
        display_range = { 2, 0, 2, 3 },
        source_text = "$c$",
        source_text_hash = "hash:c",
      }),
    })
  )
  local first_slot = state.buffers[1].nodes[state.buffers[1].node_order[1]].slot_id
  local middle_slot = state.buffers[1].nodes[state.buffers[1].node_order[2]].slot_id
  local last_slot = state.buffers[1].nodes[state.buffers[1].node_order[3]].slot_id
  local effects
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  state = commit_overlay_jobs(reducer, state, first_effect(effects, "request_full_render"))

  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        item_idx = 1,
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
      }),
      make_scanned_node({
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$c$",
        source_text_hash = "hash:c",
      }),
    }, { buffer_version = 2 })
  )
  local buf = state.buffers[1]
  assert_eq(buf.slots[first_slot].page_index, 1, "first slot should keep page index after deletion")
  assert_eq(buf.slots[middle_slot].status, "tombstone", "deleted node should leave a tombstone slot")
  assert_eq(buf.slots[middle_slot].page_index, 2, "tombstone should keep the deleted page index")
  assert_eq(buf.slots[last_slot].page_index, 3, "later slot should not shift after deletion")

  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  local request = first_effect(effects, "request_full_render")
  assert_eq(request.request.jobs[1].slot_id, first_slot, "request should keep page 1")
  assert_eq(request.request.jobs[2].is_tombstone, true, "request should keep tombstone page 2")
  assert_eq(request.request.jobs[3].slot_id, last_slot, "request should keep later page 3")
end

local function test_machine_reducer_retires_overlapping_orphans_after_commit()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = nil,
        source_range = { 5, 0, 7, 1 },
        display_range = { 5, 0, 7, 1 },
      }),
    })
  )
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })
  local request = first_effect(effects, "request_full_render")
  local overlay = state.overlays[request.request.jobs[1].overlay_id]
  state = reducer.reduce(state, page_ready_event(overlay))

  local buf = state.buffers[1]
  buf.nodes["node:orphan"] = {
    node_id = "node:orphan",
    bufnr = 1,
    project_scope_id = "project:1",
    node_type = "math",
    source_range = { 5, 0, 7, 1 },
    display_range = { 5, 0, 7, 1 },
    source_text = "$old$",
    source_text_hash = "hash:old",
    context_hash = "ctx:0",
    prelude_count = 0,
    semantics = { display_kind = "block", constraint_kind = "flow" },
    status = "orphaned",
    visible_overlay_id = "overlay:orphan",
  }
  buf.node_order[#buf.node_order + 1] = "node:orphan"
  state.overlays["overlay:orphan"] = {
    overlay_id = "overlay:orphan",
    owner_node_id = "node:orphan",
    owner_bufnr = 1,
    owner_project_scope_id = "project:1",
    request_id = "request:old",
    page_index = 1,
    render_epoch = 1,
    buffer_version = 1,
    layout_version = 1,
    image_id = 99,
    extmark_id = 199,
    status = "visible",
  }

  state, effects = reducer.reduce(state, {
    type = "overlay_commit_succeeded",
    overlay_id = overlay.overlay_id,
    node_id = overlay.owner_node_id,
  })

  local retire = first_effect(effects, "retire_overlay")
  buf = state.buffers[1]
  assert_truthy(retire ~= nil, "committing replacement should retire overlapping orphan overlays")
  assert_eq(retire.overlay_id, "overlay:orphan", "retire effect should target the overlapping orphan")
  assert_eq(buf.nodes["node:orphan"].status, "deleted_confirmed", "retired orphan should become confirmed deleted")
  assert_eq(buf.nodes["node:orphan"].visible_overlay_id, nil, "retired orphan should detach visible overlay")
end

local function test_machine_reducer_cleans_orphans_covered_by_visible_nodes()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state.buffers[1] = {
    bufnr = 1,
    project_scope_id = "project:1",
    buffer_version = 3,
    layout_version = 1,
    render_epoch = 2,
    nodes = {
      ["node:current"] = {
        node_id = "node:current",
        bufnr = 1,
        project_scope_id = "project:1",
        node_type = "math",
        source_range = { 5, 0, 7, 1 },
        display_range = { 5, 0, 7, 1 },
        source_text = "$current$",
        source_text_hash = "hash:current",
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "block", constraint_kind = "flow" },
        status = "stable",
        visible_overlay_id = "overlay:current",
      },
      ["node:orphan"] = {
        node_id = "node:orphan",
        bufnr = 1,
        project_scope_id = "project:1",
        node_type = "math",
        source_range = { 5, 0, 7, 1 },
        display_range = { 5, 0, 7, 1 },
        source_text = "$old$",
        source_text_hash = "hash:old",
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "block", constraint_kind = "flow" },
        status = "orphaned",
        visible_overlay_id = "overlay:orphan",
      },
    },
    node_order = { "node:current", "node:orphan" },
  }
  state.overlays["overlay:current"] = {
    overlay_id = "overlay:current",
    owner_node_id = "node:current",
    owner_bufnr = 1,
    owner_project_scope_id = "project:1",
    status = "visible",
  }
  state.overlays["overlay:orphan"] = {
    overlay_id = "overlay:orphan",
    owner_node_id = "node:orphan",
    owner_bufnr = 1,
    owner_project_scope_id = "project:1",
    status = "visible",
  }

  local effects
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })

  assert_eq(count_effects(effects, "request_full_render"), 0, "covered orphan cleanup should not force rerender")
  local retire = first_effect(effects, "retire_overlay")
  assert_truthy(retire ~= nil, "covered orphan should retire on render request cleanup")
  assert_eq(retire.overlay_id, "overlay:orphan", "cleanup should retire covered orphan overlay")
  assert_eq(
    state.buffers[1].nodes["node:orphan"].status,
    "deleted_confirmed",
    "covered orphan should become confirmed deleted"
  )
end

local function test_machine_reducer_abandons_idle_request_candidates()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state.buffers[1] = {
    bufnr = 1,
    project_scope_id = "project:1",
    buffer_version = 3,
    layout_version = 1,
    render_epoch = 2,
    active_request_id = "request:stale",
    nodes = {
      ["node:current"] = {
        node_id = "node:current",
        bufnr = 1,
        project_scope_id = "project:1",
        node_type = "math",
        source_range = { 5, 0, 7, 1 },
        display_range = { 5, 0, 7, 1 },
        source_text = "$current$",
        source_text_hash = "hash:current",
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "block", constraint_kind = "flow" },
        status = "stable",
        visible_overlay_id = "overlay:current",
      },
    },
    node_order = { "node:current" },
  }
  state.overlays["overlay:current"] = {
    overlay_id = "overlay:current",
    owner_node_id = "node:current",
    owner_bufnr = 1,
    owner_project_scope_id = "project:1",
    request_id = "request:old-visible",
    status = "visible",
  }
  state.overlays["overlay:candidate"] = {
    overlay_id = "overlay:candidate",
    owner_node_id = "node:deleted",
    owner_bufnr = 1,
    owner_project_scope_id = "project:1",
    request_id = "request:stale",
    status = "rendering",
  }

  local effects
  state, effects = reducer.reduce(state, { type = "full_render_requested", bufnr = 1 })

  assert_eq(state.buffers[1].active_request_id, nil, "idle render request should clear active request")
  assert_eq(count_effects(effects, "request_full_render"), 0, "idle cleanup should not request rendering")
  assert_eq(count_effects(effects, "abandon_request"), 1, "idle cleanup should abandon stale render request")
  local retire = first_effect(effects, "retire_overlay")
  assert_truthy(retire ~= nil, "idle cleanup should retire stale request candidates")
  assert_eq(retire.overlay_id, "overlay:candidate", "idle cleanup should retire non-visible candidate only")
  assert_eq(state.overlays["overlay:current"].status, "visible", "idle cleanup should keep visible overlays")
end

local function test_machine_reducer_failed_request_cleans_candidates_and_active_id()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state.buffers[1] = {
    bufnr = 1,
    project_scope_id = "project:1",
    buffer_version = 3,
    layout_version = 1,
    render_epoch = 2,
    active_request_id = "request:failed",
    nodes = {
      ["node:visible"] = {
        node_id = "node:visible",
        bufnr = 1,
        project_scope_id = "project:1",
        node_type = "math",
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        status = "pending",
        visible_overlay_id = "overlay:visible",
        candidate_overlay_id = "overlay:candidate-visible",
      },
      ["node:new"] = {
        node_id = "node:new",
        bufnr = 1,
        project_scope_id = "project:1",
        node_type = "math",
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$y$",
        source_text_hash = "hash:y",
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        status = "pending",
        candidate_overlay_id = "overlay:candidate-new",
      },
    },
    node_order = { "node:visible", "node:new" },
  }
  state.overlays["overlay:visible"] = {
    overlay_id = "overlay:visible",
    owner_node_id = "node:visible",
    owner_bufnr = 1,
    request_id = "request:old",
    status = "visible",
  }
  state.overlays["overlay:candidate-visible"] = {
    overlay_id = "overlay:candidate-visible",
    owner_node_id = "node:visible",
    owner_bufnr = 1,
    request_id = "request:failed",
    status = "rendering",
  }
  state.overlays["overlay:candidate-new"] = {
    overlay_id = "overlay:candidate-new",
    owner_node_id = "node:new",
    owner_bufnr = 1,
    request_id = "request:failed",
    status = "placeholder",
  }

  local effects
  state, effects = reducer.reduce(state, {
    type = "render_request_failed",
    bufnr = 1,
    request_id = "request:failed",
  })

  assert_eq(state.buffers[1].active_request_id, nil, "failed request should clear active_request_id")
  assert_eq(state.buffers[1].nodes["node:visible"].candidate_overlay_id, nil, "visible node candidate should detach")
  assert_eq(state.buffers[1].nodes["node:visible"].status, "stale", "visible node should become stale")
  assert_eq(state.buffers[1].nodes["node:new"].candidate_overlay_id, nil, "new node candidate should detach")
  assert_eq(state.buffers[1].nodes["node:new"].status, "pending", "new node should return to pending")
  assert_eq(count_effects(effects, "retire_overlay"), 2, "failed request should retire non-visible candidates")
end

local function test_machine_runtime_rebuilds_compat_read_model()
  local state = fresh_state()
  local types = require("typst-concealer.machine.types")
  local runtime = require("typst-concealer.machine.runtime")
  local machine = types.initial_state()

  local old_item = make_render_item({
    image_id = 11,
    extmark_id = 21,
  })
  state.buffer_render_state[1] = {
    full_items = { old_item },
    lingering_items = {},
    full_units = { "keep-units" },
    runtime_preludes = { "keep-prelude" },
  }
  state.item_by_image_id[old_item.image_id] = old_item
  state.image_id_to_extmark[old_item.image_id] = old_item.extmark_id

  machine.buffers[1] = {
    bufnr = 1,
    project_scope_id = "project:1",
    buffer_version = 1,
    layout_version = 1,
    render_epoch = 1,
    nodes = {
      ["node:1"] = {
        node_id = "node:1",
        bufnr = 1,
        project_scope_id = "project:1",
        item_idx = 1,
        node_type = "math",
        source_range = { 2, 0, 2, 3 },
        display_range = { 2, 0, 2, 3 },
        source_text = "$z$",
        source_text_hash = "hash:z",
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        status = "stable",
        visible_overlay_id = "overlay:1",
      },
    },
    node_order = { "node:1" },
  }
  machine.overlays["overlay:1"] = {
    overlay_id = "overlay:1",
    owner_node_id = "node:1",
    owner_bufnr = 1,
    owner_project_scope_id = "project:1",
    request_id = "request:1",
    page_index = 1,
    render_epoch = 1,
    buffer_version = 1,
    layout_version = 1,
    image_id = 31,
    extmark_id = 41,
    page_path = "/tmp/page.png",
    page_stamp = "stamp",
    natural_cols = 4,
    natural_rows = 1,
    source_rows = 1,
    status = "visible",
  }

  runtime.rebuild_buffer_read_model(machine, 1)

  local bstate = state.buffer_render_state[1]
  assert_eq(state.item_by_image_id[old_item.image_id], nil, "old full item index should be removed")
  assert_eq(state.image_id_to_extmark[old_item.image_id], nil, "old full extmark index should be removed")
  assert_eq(#bstate.full_items, 1, "visible machine overlay should become one compat full item")
  assert_eq(bstate.full_items[1].image_id, 31, "compat item should use overlay image id")
  assert_eq(bstate.full_items[1].str, "$z$", "compat item should preserve source text as str")
  assert_eq(state.item_by_image_id[31], bstate.full_items[1], "compat item should be indexed by image id")
  assert_eq(state.image_id_to_extmark[31], 41, "compat extmark index should be rebuilt")
  assert_eq(bstate.line_to_items[2][1], bstate.full_items[1], "line index should include visible item")
  assert_eq(bstate.extmark_to_item[41], bstate.full_items[1], "extmark index should include visible item")
  assert_eq(bstate.full_units[1], "keep-units", "runtime rebuild should preserve full_units")
  assert_eq(bstate.runtime_preludes[1], "keep-prelude", "runtime rebuild should preserve runtime preludes")
end

local function test_machine_runtime_rebinds_overlay_without_reuploading_image()
  local state = fresh_state()
  state.machine_state.buffers[1] = {
    bufnr = 1,
    project_scope_id = "project:1",
    buffer_version = 2,
    layout_version = 1,
    render_epoch = 1,
    active_request_id = nil,
    nodes = {
      ["node:1"] = {
        node_id = "node:1",
        bufnr = 1,
        project_scope_id = "project:1",
        item_idx = 1,
        node_type = "math",
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        status = "stable",
        visible_overlay_id = "overlay:1",
        candidate_overlay_id = nil,
        last_buffer_version = 1,
        last_layout_version = 1,
      },
    },
    node_order = { "node:1" },
  }
  state.machine_state.overlays["overlay:1"] = {
    overlay_id = "overlay:1",
    owner_node_id = "node:1",
    owner_bufnr = 1,
    owner_project_scope_id = "project:1",
    request_id = "request:1",
    page_index = 1,
    session_id = "full:1",
    render_epoch = 1,
    buffer_version = 1,
    layout_version = 1,
    extmark_id = 41,
    image_id = 31,
    page_path = "/tmp/page.png",
    page_stamp = "stamp",
    natural_cols = 4,
    natural_rows = 1,
    source_rows = 1,
    binding_buffer_version = 1,
    binding_layout_version = 1,
    binding_display_range = { 0, 0, 0, 3 },
    status = "visible",
  }

  with_stubbed_extmark(function(calls)
    local runtime = require("typst-concealer.machine.runtime")
    runtime.run_effects({
      {
        kind = "bind_overlay",
        overlay_id = "overlay:1",
        request_id = "request:1",
        node_id = "node:1",
        bufnr = 1,
        buffer_version = 2,
        layout_version = 1,
        display_range = { 0, 0, 0, 3 },
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
      },
    })

    assert_eq(#calls.created, 0, "rebind should reuse the uploaded terminal image")
    assert_eq(#calls.swapped, 1, "rebind should move the existing extmark")
    assert_eq(#calls.concealed, 1, "rebind should rewrite placeholders for the existing image")
    assert_eq(
      state.machine_state.overlays["overlay:1"].binding_buffer_version,
      2,
      "runtime rebind should update the machine binding epoch"
    )
  end)
end

local function test_machine_runtime_places_cursor_overlay_unconcealed()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$ tail" })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  state.pid = 1200
  state.machine_state.buffers[bufnr] = {
    bufnr = bufnr,
    project_scope_id = "project:cursor",
    buffer_version = 1,
    layout_version = 1,
    render_epoch = 1,
    nodes = {
      ["node:cursor"] = {
        node_id = "node:cursor",
        bufnr = bufnr,
        project_scope_id = "project:cursor",
        item_idx = 1,
        node_type = "math",
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        status = "pending",
        candidate_overlay_id = "overlay:cursor",
      },
    },
    node_order = { "node:cursor" },
  }
  state.machine_state.overlays["overlay:cursor"] = {
    overlay_id = "overlay:cursor",
    owner_node_id = "node:cursor",
    owner_bufnr = bufnr,
    owner_project_scope_id = "project:cursor",
    request_id = "request:cursor",
    page_index = 1,
    render_epoch = 1,
    buffer_version = 1,
    layout_version = 1,
    status = "placeholder",
  }

  with_stubbed_extmark(function(calls)
    local runtime = require("typst-concealer.machine.runtime")
    runtime.run_effects({
      {
        kind = "ensure_overlay_placeholder",
        overlay_id = "overlay:cursor",
        bufnr = bufnr,
        node_id = "node:cursor",
        display_range = { 0, 0, 0, 3 },
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
      },
    })

    assert_eq(#calls.placed, 1, "cursor-owned placeholder should still allocate an extmark")
    assert_eq(calls.placed[1].concealing, false, "placeholder under cursor should keep source visible")
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_conceal_preserves_source_under_cursor()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$ tail" })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })

  local extmark = require("typst-concealer.extmark")
  local image_id = 1300
  local semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" }
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, { 0, 0, 0, 3 }, nil, false, semantics)
  local item = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = { 0, 0, 0, 3 },
    display_range = { 0, 0, 0, 3 },
    node_type = "math",
    semantics = semantics,
  }
  state.image_id_to_extmark[image_id] = extmark_id
  state.item_by_image_id[image_id] = item

  extmark.conceal_for_image_id(bufnr, image_id, 2, 1, 1)
  local bs = state.get_buf_state(bufnr)
  assert_eq(bs.currently_hidden_extmark_ids[extmark_id], true, "image ready under cursor should stay hidden")
  local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
  assert_eq(mark[3].conceal, nil, "image ready under cursor should not conceal source")

  bs.currently_hidden_extmark_ids[extmark_id] = nil
  vim.api.nvim_win_set_cursor(0, { 1, 5 })
  extmark.conceal_for_image_id(bufnr, image_id, 2, 1, 1)
  mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
  assert_truthy(
    mark[3].virt_text ~= nil and mark[3].virt_text[1] ~= nil and mark[3].virt_text[1][1] ~= "",
    "image away from cursor should restore rendered placeholders"
  )

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_machine_runtime_builds_watch_render_job()
  local state = fresh_state()
  local reducer = require("typst-concealer.machine.reducer")
  local runtime = require("typst-concealer.machine.runtime")

  local machine, effects = reducer.reduce(state.machine_state, scan_event({ make_scanned_node() }))
  machine, effects = reducer.reduce(machine, { type = "full_render_requested", bufnr = 1 })
  local request = first_effect(effects, "request_full_render")
  local overlay_id = request.request.jobs[1].overlay_id
  state.machine_state = machine

  runtime.dispatch({
    type = "overlay_resources_allocated",
    overlay_id = overlay_id,
    image_id = 51,
    extmark_id = 61,
  }, { run_effects = false })

  local job = runtime.build_render_job(state.machine_state, overlay_id)
  assert_eq(job.request_id, state.machine_state.overlays[overlay_id].request_id, "job should carry request id")
  assert_eq(job.request_page_index, 1, "job should carry page index")
  assert_eq(job.overlay_id, overlay_id, "job should carry overlay id")
  assert_eq(job.image_id, 51, "job should carry allocated image id")
  assert_eq(job.extmark_id, 61, "job should carry allocated extmark id")
  assert_eq(job.str, "$x$", "job should remain wrapper-compatible")
end

local function test_machine_runtime_resets_buffer_snapshot()
  local state = fresh_state()
  local runtime = require("typst-concealer.machine.runtime")

  state.machine_state.buffers[1] = { bufnr = 1, nodes = {}, node_order = {} }
  state.machine_state.buffers[2] = { bufnr = 2, nodes = {}, node_order = {} }
  state.machine_state.overlays["overlay:1"] = { overlay_id = "overlay:1", owner_bufnr = 1 }
  state.machine_state.overlays["overlay:2"] = { overlay_id = "overlay:2", owner_bufnr = 2 }

  runtime.reset_buffer(1)

  assert_eq(state.machine_state.buffers[1], nil, "reset should remove the target buffer snapshot")
  assert_truthy(state.machine_state.buffers[2] ~= nil, "reset should keep other buffer snapshots")
  assert_eq(state.machine_state.overlays["overlay:1"], nil, "reset should remove target buffer overlays")
  assert_truthy(state.machine_state.overlays["overlay:2"] ~= nil, "reset should keep other buffer overlays")
end

local function test_machine_runtime_retire_removes_overlay_entry()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      use_compiler_service = true,
    },
  }
  local runtime = require("typst-concealer.machine.runtime")
  state.machine_state.buffers[1] = { bufnr = 1, nodes = {}, node_order = {} }
  state.machine_state.overlays["overlay:retire"] = {
    overlay_id = "overlay:retire",
    owner_bufnr = 1,
    status = "retiring",
  }

  runtime.run_effects({
    { kind = "retire_overlay", overlay_id = "overlay:retire" },
  })

  assert_eq(state.machine_state.overlays["overlay:retire"], nil, "retire effect should remove overlay entry")
end

local function test_machine_runtime_reset_buffer_releases_candidate_resources()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      use_compiler_service = true,
    },
  }
  local page_path = vim.fn.tempname() .. ".png"
  write_file(page_path, "png")
  local runtime = require("typst-concealer.machine.runtime")
  state.machine_state.buffers[1] = { bufnr = 1, nodes = {}, node_order = {} }
  state.machine_state.overlays["overlay:candidate"] = {
    overlay_id = "overlay:candidate",
    owner_bufnr = 1,
    image_id = 501,
    extmark_id = 601,
    page_path = page_path,
    status = "rendering",
  }
  state.image_ids_in_use[501] = 1
  state.image_id_to_extmark[501] = 601

  with_stubbed_extmark(function(calls)
    runtime.reset_buffer(1)
    assert_eq(calls.cleared[1], 501, "reset should clear candidate image")
  end)
  assert_eq(state.image_ids_in_use[501], nil, "reset should release candidate image id")
  assert_eq(state.machine_state.overlays["overlay:candidate"], nil, "reset should remove candidate overlay")
  assert_eq(vim.uv.fs_stat(page_path), nil, "reset should safe-unlink service PNG")
end

local function test_machine_runtime_tracks_ui_state()
  local state = fresh_state()
  local runtime = require("typst-concealer.machine.runtime")

  runtime.invalidate_hover(1)
  local ui = runtime.get_ui_buffer(1)
  assert_eq(ui.hover.invalidated, true, "hover invalidation should be stored in machine ui state")

  runtime.set_preview_render_key(1, "preview-key")
  runtime.mark_preview_rendered(1)
  assert_eq(ui.preview.render_key, "preview-key", "preview render key should be stored in machine ui state")
  assert_eq(ui.preview.last_render_key, "preview-key", "rendered preview key should be tracked in machine ui state")

  local preview_item = { bufnr = 1 }
  runtime.prepare_preview_request(1, preview_item)
  assert_eq(preview_item.preview_request_id, ui.preview.active_request_id, "preview item should carry request identity")
  assert_eq(ui.preview.status, "rendering", "preview request should mark preview rendering")
  assert_eq(
    runtime.accept_preview_page_update({
      bufnr = 1,
      preview_request_id = "stale-preview",
    }, { apply = false }),
    false,
    "stale preview page should be rejected"
  )
  assert_eq(
    runtime.accept_preview_page_update({
      bufnr = 1,
      preview_request_id = preview_item.preview_request_id,
    }, { apply = false }),
    true,
    "active preview page should be accepted"
  )
  assert_eq(ui.preview.status, "ready", "accepted preview page should mark preview ready")

  state.machine_state.buffers[1] = { bufnr = 1, nodes = {}, node_order = {} }
  runtime.reset_buffer(1)
  assert_eq(state.machine_state.ui.buffers[1], nil, "buffer reset should clear machine ui state")
end

local function test_machine_resources_share_legacy_allocation_pool()
  local state = fresh_state()
  state.pid = 700
  local resources = require("typst-concealer.machine.resources")
  local image_id = resources.allocate_image_id(1)
  assert_eq(image_id, 700, "machine resources should allocate from state pid")
  assert_eq(state.image_ids_in_use[image_id], 1, "machine allocation should reserve the image id")

  local apply = require("typst-concealer.apply")
  local legacy_image_id = apply._new_image_id(2)
  assert_eq(legacy_image_id, 701, "legacy apply allocation should share the machine resource pool")
  assert_eq(state.image_ids_in_use[legacy_image_id], 2, "legacy allocation should reserve through resources")

  state.image_id_to_extmark[image_id] = 901
  state.item_by_image_id[image_id] = { image_id = image_id }
  with_stubbed_extmark(function(calls)
    resources.release_overlay_resources(1, image_id, nil)
    assert_eq(calls.cleared[1], image_id, "resource release should clear the terminal image")
  end)
  assert_eq(state.image_ids_in_use[image_id], nil, "resource release should free the image id")
  assert_eq(state.image_id_to_extmark[image_id], nil, "resource release should unindex extmark mapping")
  assert_eq(state.item_by_image_id[image_id], nil, "resource release should unindex item mapping")
end

local function test_commit_plan_reuses_stable_render_for_same_source()
  local state = fresh_state()
  local bufnr = 1
  local prev = make_render_item({
    image_id = 101,
    extmark_id = 201,
    page_path = "/tmp/old.png",
    page_stamp = "old-stamp",
    natural_cols = 2,
    natural_rows = 1,
    source_rows = 1,
  })
  state.buffer_render_state[bufnr] = { full_items = { prev }, lingering_items = {} }
  state.image_ids_in_use[prev.image_id] = bufnr
  state.image_id_to_extmark[prev.image_id] = prev.extmark_id
  state.item_by_image_id[prev.image_id] = prev

  with_stubbed_extmark(function(calls)
    local apply = require("typst-concealer.apply")
    local planned = make_render_item({
      range = { 0, 1, 0, 4 },
    })
    local items = apply.commit_plan(bufnr, { planned })

    assert_eq(#items, 1, "same source should stay visible as one committed item")
    assert_eq(items[1].image_id, prev.image_id, "same source should reuse image id")
    assert_eq(items[1].extmark_id, prev.extmark_id, "same source should reuse extmark")
    assert_eq(items[1].page_stamp, prev.page_stamp, "same source should carry stable render metadata")
    assert_eq(#calls.cleared, 0, "same source should not clear the existing image")
  end)
end

local function test_commit_plan_does_not_reuse_render_for_changed_source()
  local state = fresh_state()
  local bufnr = 1
  state.pid = 1000
  local prev = make_render_item({
    image_id = 101,
    extmark_id = 201,
    page_path = "/tmp/old.png",
    page_stamp = "old-stamp",
    natural_cols = 2,
    natural_rows = 1,
    source_rows = 1,
  })
  state.buffer_render_state[bufnr] = { full_items = { prev }, lingering_items = {} }
  state.image_ids_in_use[prev.image_id] = bufnr
  state.image_id_to_extmark[prev.image_id] = prev.extmark_id
  state.item_by_image_id[prev.image_id] = prev

  with_stubbed_extmark(function(calls)
    local apply = require("typst-concealer.apply")
    local planned = make_render_item({
      str = "$y$",
    })
    local items = apply.commit_plan(bufnr, { planned })

    assert_eq(#items, 1, "changed source should still commit the new item")
    assert_truthy(items[1].image_id ~= prev.image_id, "changed source should allocate a new image id")
    assert_eq(items[1].page_stamp, nil, "changed source should not carry stale page metadata")
    assert_eq(calls.cleared[1], prev.image_id, "changed source should clear the stale image immediately")
    assert_eq(state.item_by_image_id[prev.image_id], nil, "changed source should unindex stale item")
    assert_eq(state.image_id_to_extmark[prev.image_id], nil, "changed source should unindex stale extmark")
  end)
end

local function test_commit_plan_cleans_removed_items_immediately()
  local state = fresh_state()
  local bufnr = 1
  local prev = make_render_item({
    image_id = 101,
    extmark_id = 201,
    page_path = "/tmp/old.png",
    page_stamp = "old-stamp",
    natural_cols = 2,
    natural_rows = 1,
    source_rows = 1,
  })
  state.buffer_render_state[bufnr] = { full_items = { prev }, lingering_items = {} }
  state.image_ids_in_use[prev.image_id] = bufnr
  state.image_id_to_extmark[prev.image_id] = prev.extmark_id
  state.item_by_image_id[prev.image_id] = prev

  with_stubbed_extmark(function(calls)
    local apply = require("typst-concealer.apply")
    local items = apply.commit_plan(bufnr, {})

    assert_eq(#items, 0, "removed items should not remain visible")
    assert_eq(#state.buffer_render_state[bufnr].lingering_items, 0, "removed items should not linger")
    assert_eq(calls.cleared[1], prev.image_id, "removed items should clear their image immediately")
    assert_eq(state.item_by_image_id[prev.image_id], nil, "removed items should be removed from image index")
    assert_eq(state.image_ids_in_use[prev.image_id], nil, "removed items should release image ids")
  end)
end

local function main()
  test_root_prefers_cwd_fallback()
  ok("ok root fallback uses cwd")
  test_get_root_overrides_fallback()
  ok("ok get_root overrides root base")
  test_session_render_request_tracks_current_request()
  ok("ok session tracks machine render requests")
  test_session_render_request_via_service_writes_json()
  ok("ok session writes compiler service requests")
  test_service_validates_page_contract()
  ok("ok service validates page contract")
  test_service_success_clears_active_meta()
  ok("ok service success clears active meta")
  test_service_one_dirty_slot_keeps_full_shape_and_commits_once()
  ok("ok service one dirty slot keeps full shape and commits once")
  test_service_ignores_context_leading_pages()
  ok("ok service ignores context leading pages")
  test_service_stale_response_cleans_candidates()
  ok("ok service stale responses clean candidates")
  test_service_write_failure_cleans_active_request()
  ok("ok service write failure cleans active request")
  test_service_spawn_failure_cleans_candidate()
  ok("ok service spawn failure cleans candidate")
  test_service_diagnostics_mapping()
  ok("ok service diagnostics mapping")
  test_preview_service_routing_and_stale_cleanup()
  ok("ok preview service routing and stale cleanup")
  test_preview_service_uses_last_page_after_context()
  ok("ok preview service uses last page after context")
  test_live_preview_keeps_old_highlight_until_replacement_commits()
  ok("ok live preview keeps old highlight until replacement commits")
  test_service_artifact_cleanup_preserves_live_paths()
  ok("ok service artifact cleanup preserves live paths")
  test_wrapper_cache_tracks_root_signature()
  ok("ok wrapper cache keys include root signature")
  test_inline_wrapper_keeps_single_row_width_intrinsic()
  ok("ok inline wrapper keeps single-row width intrinsic")
  test_remote_urls_do_not_rewrite_against_root()
  ok("ok remote urls bypass root rewrite")
  test_named_path_args_rewrite_local_paths()
  ok("ok named path args rewrite local paths")
  test_named_path_args_preserve_remote_urls()
  ok("ok named path args preserve remote urls")
  test_machine_reducer_enforces_request_identity_and_delayed_retire()
  ok("ok machine reducer enforces request identity and delayed retire")
  test_machine_reducer_rebinds_stable_visible_overlay_on_precise_dirty_range()
  ok("ok machine reducer rebinds stable visible overlays on precise dirty ranges")
  test_machine_reducer_does_not_rebind_stable_overlay_for_disjoint_dirty_range()
  ok("ok machine reducer skips disjoint display binding changes")
  test_machine_reducer_retires_deleted_only_formula_on_render_boundary()
  ok("ok machine reducer retires deleted only formula on render boundary")
  test_machine_reducer_keeps_overlapping_orphan_until_replacement_commit()
  ok("ok machine reducer keeps overlapping orphan until replacement commit")
  test_machine_reducer_reuses_range_identity_without_stable_key()
  ok("ok machine reducer reuses range identity without stable key")
  test_machine_reducer_identity_adjacent_formula_edit()
  ok("ok machine reducer identity adjacent formula edit")
  test_machine_reducer_identity_deletion_with_upward_shift()
  ok("ok machine reducer identity deletion with upward shift")
  test_machine_reducer_identity_insertion_between_formulas()
  ok("ok machine reducer identity insertion between formulas")
  test_machine_reducer_identity_repeated_identical_formulas()
  ok("ok machine reducer identity repeated identical formulas")
  test_machine_reducer_stable_slots_include_clean_pages_for_one_dirty_node()
  ok("ok machine reducer stable slots include clean pages for one dirty node")
  test_machine_reducer_stable_slots_append_insertions_without_shifting_pages()
  ok("ok machine reducer stable slots append insertions without shifting pages")
  test_machine_reducer_stable_slots_tombstone_deletions_without_shifting_pages()
  ok("ok machine reducer stable slots tombstone deletions without shifting pages")
  test_machine_reducer_retires_overlapping_orphans_after_commit()
  ok("ok machine reducer retires overlapping orphans after commit")
  test_machine_reducer_cleans_orphans_covered_by_visible_nodes()
  ok("ok machine reducer cleans orphans covered by visible nodes")
  test_machine_reducer_abandons_idle_request_candidates()
  ok("ok machine reducer abandons idle request candidates")
  test_machine_reducer_failed_request_cleans_candidates_and_active_id()
  ok("ok machine reducer failed request cleans candidates")
  test_machine_runtime_rebuilds_compat_read_model()
  ok("ok machine runtime rebuilds compat read model")
  test_machine_runtime_rebinds_overlay_without_reuploading_image()
  ok("ok machine runtime rebinds overlays without image upload")
  test_machine_runtime_places_cursor_overlay_unconcealed()
  ok("ok machine runtime keeps cursor overlay placeholders unconcealed")
  test_extmark_conceal_preserves_source_under_cursor()
  ok("ok extmark conceal keeps cursor source visible")
  test_machine_runtime_builds_watch_render_job()
  ok("ok machine runtime builds watch render job")
  test_machine_runtime_resets_buffer_snapshot()
  ok("ok machine runtime resets buffer snapshot")
  test_machine_runtime_retire_removes_overlay_entry()
  ok("ok machine runtime retire removes overlay entry")
  test_machine_runtime_reset_buffer_releases_candidate_resources()
  ok("ok machine runtime reset releases candidate resources")
  test_machine_runtime_tracks_ui_state()
  ok("ok machine runtime tracks ui state")
  test_machine_resources_share_legacy_allocation_pool()
  ok("ok machine resources share legacy allocation pool")
  test_commit_plan_reuses_stable_render_for_same_source()
  ok("ok commit_plan reuses same-source stable renders")
  test_commit_plan_does_not_reuse_render_for_changed_source()
  ok("ok commit_plan rejects changed-source stale renders")
  test_commit_plan_cleans_removed_items_immediately()
  ok("ok commit_plan cleans removed items immediately")
  vim.cmd("qa!")
end

main()
