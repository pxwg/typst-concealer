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
  package.loaded["typst-concealer.extmark"] = nil
  package.loaded["typst-concealer.session"] = nil
  package.loaded["typst-concealer.project-scope"] = nil
  package.loaded["typst-concealer.machine.types"] = nil
  package.loaded["typst-concealer.machine.reducer"] = nil
  package.loaded["typst-concealer.machine.effects"] = nil
  package.loaded["typst-concealer.machine.runtime"] = nil
  package.loaded["typst-concealer.wrapper"] = nil
  package.loaded["typst-concealer.path-rewrite"] = nil
end

local function with_stubbed_uv(fn)
  local uv = vim.uv
  local original = {
    new_pipe = uv.new_pipe,
    new_timer = uv.new_timer,
    spawn = uv.spawn,
  }

  local spawned = {}
  uv.new_pipe = function()
    return {
      read_start = function() end,
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
      args = vim.deepcopy(opts.args),
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
    cleared = {},
  }

  package.loaded["typst-concealer.extmark"] = {
    place_render_extmark = function(bufnr, image_id, range, extmark_id)
      local id = extmark_id or (image_id + 10000)
      local state = require("typst-concealer.state")
      state.image_id_to_extmark[image_id] = id
      calls.placed[#calls.placed + 1] = {
        bufnr = bufnr,
        image_id = image_id,
        range = range,
        extmark_id = id,
      }
      return id
    end,
    clear_image = function(image_id)
      local state = require("typst-concealer.state")
      calls.cleared[#calls.cleared + 1] = image_id
      state.image_ids_in_use[image_id] = nil
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
    stable_key = "stable:1",
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
    assert_truthy(session.last_input_text ~= nil, "replacement request should force a watch input write")

    session_mod.stop_watch_session(bufnr, "full")
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
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
  assert_eq(count_effects(effects, "abandon_request"), 1, "new request should abandon previous active request")
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

local function test_machine_reducer_orphans_deleted_visible_nodes_until_confirmed()
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
  assert_eq(#effects, 0, "orphan-only buffer should not request a new render")
  assert_eq(
    state.overlays[overlay.overlay_id].status,
    "visible",
    "orphaned node should not retire during scan/render request"
  )

  state, effects = reducer.reduce(state, {
    type = "node_deleted_confirmed",
    bufnr = 1,
    node_id = overlay.owner_node_id,
  })
  node = state.buffers[1].nodes[overlay.owner_node_id]
  assert_eq(node.status, "deleted_confirmed", "confirmation should finalize deleted node")
  assert_eq(node.visible_overlay_id, nil, "confirmed delete should detach visible overlay")
  assert_eq(effects[1].kind, "retire_overlay", "confirmed delete should retire old overlay")
  assert_eq(effects[1].overlay_id, overlay.overlay_id, "confirmed delete should retire the orphan overlay")
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

  state.machine_state.buffers[1] = { bufnr = 1, nodes = {}, node_order = {} }
  runtime.reset_buffer(1)
  assert_eq(state.machine_state.ui.buffers[1], nil, "buffer reset should clear machine ui state")
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
  ok("ok session tracks machine watch requests")
  test_wrapper_cache_tracks_root_signature()
  ok("ok wrapper cache keys include root signature")
  test_remote_urls_do_not_rewrite_against_root()
  ok("ok remote urls bypass root rewrite")
  test_named_path_args_rewrite_local_paths()
  ok("ok named path args rewrite local paths")
  test_named_path_args_preserve_remote_urls()
  ok("ok named path args preserve remote urls")
  test_machine_reducer_enforces_request_identity_and_delayed_retire()
  ok("ok machine reducer enforces request identity and delayed retire")
  test_machine_reducer_orphans_deleted_visible_nodes_until_confirmed()
  ok("ok machine reducer orphans deleted visible nodes until confirmed")
  test_machine_runtime_rebuilds_compat_read_model()
  ok("ok machine runtime rebuilds compat read model")
  test_machine_runtime_builds_watch_render_job()
  ok("ok machine runtime builds watch render job")
  test_machine_runtime_resets_buffer_snapshot()
  ok("ok machine runtime resets buffer snapshot")
  test_machine_runtime_tracks_ui_state()
  ok("ok machine runtime tracks ui state")
  test_commit_plan_reuses_stable_render_for_same_source()
  ok("ok commit_plan reuses same-source stable renders")
  test_commit_plan_does_not_reuse_render_for_changed_source()
  ok("ok commit_plan rejects changed-source stale renders")
  test_commit_plan_cleans_removed_items_immediately()
  ok("ok commit_plan cleans removed items immediately")
  vim.cmd("qa!")
end

main()
