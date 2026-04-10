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
  package.loaded["typst-concealer.session"] = nil
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

local function main()
  test_root_prefers_cwd_fallback()
  ok("ok root fallback uses cwd")
  test_get_root_overrides_fallback()
  ok("ok get_root overrides root base")
  test_wrapper_cache_tracks_root_signature()
  ok("ok wrapper cache keys include root signature")
  test_remote_urls_do_not_rewrite_against_root()
  ok("ok remote urls bypass root rewrite")
  test_named_path_args_rewrite_local_paths()
  ok("ok named path args rewrite local paths")
  test_named_path_args_preserve_remote_urls()
  ok("ok named path args preserve remote urls")
  vim.cmd("qa!")
end

main()
