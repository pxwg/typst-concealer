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
  package.loaded["typst-concealer.display"] = nil
  package.loaded["typst-concealer.extmark"] = nil
  package.loaded["typst-concealer.line-run"] = nil
  package.loaded["typst-concealer.session"] = nil
  package.loaded["typst-concealer.project-scope"] = nil
  package.loaded["typst-concealer.machine.types"] = nil
  package.loaded["typst-concealer.machine.reducer"] = nil
  package.loaded["typst-concealer.machine.effects"] = nil
  package.loaded["typst-concealer.machine.resources"] = nil
  package.loaded["typst-concealer.machine.runtime"] = nil
  package.loaded["typst-concealer.formula.image"] = nil
  package.loaded["typst-concealer.formula.manager"] = nil
  package.loaded["typst-concealer.formula.placement"] = nil
  package.loaded["typst-concealer.wrapper"] = nil
  package.loaded["typst-concealer.latex-wrapper"] = nil
  package.loaded["typst-concealer.path-rewrite"] = nil
  package.loaded["typst-concealer.viewport"] = nil
  package.loaded["typst-concealer.source-adapters.typst"] = nil
  package.loaded["typst-concealer.source-adapters.markdown"] = nil
  package.loaded["typst-concealer.source-adapters.latex"] = nil
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
      on_exit = _on_exit,
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
  state.render_diagnostics = {}
  state.buffer_render_state = {}
  state.path_rewrite_cache = {}
  state.runtime_preludes = {}
  state.machine_state = require("typst-concealer.machine.types").initial_state()
  state.formula_managers = {}
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
    syncs = {},
    flushed = 0,
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
    clear_image_only = function(image_id)
      calls.cleared[#calls.cleared + 1] = image_id
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
    reconcile_cursor_line_runs = function(bufnr, lo, hi)
      local state = require("typst-concealer.state")
      local hidden = {}
      for extmark_id in pairs(state.get_buf_state(bufnr).currently_hidden_extmark_ids or {}) do
        hidden[#hidden + 1] = extmark_id
      end
      table.sort(hidden)
      calls.syncs[#calls.syncs + 1] = {
        bufnr = bufnr,
        lo = lo,
        hi = hi,
        hidden = hidden,
      }
    end,
    sync_inline_line_carriers = function(bufnr, lo, hi)
      package.loaded["typst-concealer.extmark"].reconcile_cursor_line_runs(bufnr, lo, hi)
    end,
    flush_terminal_data = function()
      calls.flushed = calls.flushed + 1
    end,
  }

  local ok_run, result = pcall(fn, calls)
  package.loaded["typst-concealer.extmark"] = original
  if not ok_run then
    error(result)
  end
  return result
end

local function test_extmark_flushes_kitty_graphics_through_ui_send()
  reset_modules()
  local original_new_tty = vim.loop.new_tty
  local original_ui_send = vim.api.nvim_ui_send
  local stdout_writes = {}
  local ui_writes = {}

  vim.loop.new_tty = function()
    return {
      write = function(_, data)
        stdout_writes[#stdout_writes + 1] = data
      end,
    }
  end
  vim.api.nvim_ui_send = function(data)
    ui_writes[#ui_writes + 1] = data
  end

  local ok_run, err = pcall(function()
    local extmark = require("typst-concealer.extmark")
    extmark.create_image("/tmp/kitty-placeholder.png", 42, 3, 2)
    extmark.flush_terminal_data()
  end)

  package.loaded["typst-concealer.extmark"] = nil
  vim.loop.new_tty = original_new_tty
  vim.api.nvim_ui_send = original_ui_send

  if not ok_run then
    error(err)
  end
  assert_eq(#ui_writes, 1, "kitty graphics payload should flush through nvim_ui_send")
  assert_eq(#stdout_writes, 0, "kitty graphics payload should not write directly to stdout when nvim_ui_send works")
  assert_truthy(ui_writes[1]:find("\27_G", 1, true) ~= nil, "kitty graphics payload should contain an escape sequence")
end

local function test_extmark_flushes_kitty_graphics_to_stdout_when_ui_send_fails()
  reset_modules()
  local original_new_tty = vim.loop.new_tty
  local original_ui_send = vim.api.nvim_ui_send
  local stdout_writes = {}

  vim.loop.new_tty = function()
    return {
      write = function(_, data)
        stdout_writes[#stdout_writes + 1] = data
      end,
    }
  end
  vim.api.nvim_ui_send = function()
    error("no attached UI")
  end

  local ok_run, err = pcall(function()
    local extmark = require("typst-concealer.extmark")
    extmark.create_image("/tmp/kitty-placeholder.png", 42, 3, 2)
    extmark.flush_terminal_data()
  end)

  package.loaded["typst-concealer.extmark"] = nil
  vim.loop.new_tty = original_new_tty
  vim.api.nvim_ui_send = original_ui_send

  if not ok_run then
    error(err)
  end
  assert_eq(#stdout_writes, 1, "kitty graphics payload should fall back to stdout when nvim_ui_send fails")
  assert_truthy(
    stdout_writes[1]:find("\27_G", 1, true) ~= nil,
    "fallback kitty graphics payload should contain an escape sequence"
  )
end

local function test_render_buf_suppresses_stale_parser_warning()
  fresh_state()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, "parser-delay.typ")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$" })
  vim.bo[bufnr].filetype = "typst"

  local render_calls = 0
  package.loaded["typst-concealer"] = {
    _enabled_buffers = { [bufnr] = true },
    is_render_allowed = function()
      return true
    end,
    config = {
      conceal_in_normal = false,
    },
  }
  package.loaded["typst-concealer.machine.runtime"] = {
    reconcile_visible_overlay_bindings = function()
      return 0
    end,
    render_buf = function()
      render_calls = render_calls + 1
    end,
  }

  local original_get_parser = vim.treesitter.get_parser
  local original_defer_fn = vim.defer_fn
  local original_schedule = vim.schedule
  local original_notify = vim.notify
  local parser_ready = false
  local scheduled = {}
  local notifications = {}

  vim.treesitter.get_parser = function(_, lang)
    if lang == "typst" and parser_ready then
      return {
        parse = function()
          return {}
        end,
      }
    end
    return nil, "parser delayed"
  end
  vim.defer_fn = function() end
  vim.schedule = function(cb)
    scheduled[#scheduled + 1] = cb
  end
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message = message, level = level }
  end

  local ok_run, err = pcall(function()
    local plan = require("typst-concealer.plan")
    for _ = 1, 21 do
      plan.render_buf(bufnr)
    end
    parser_ready = true
    for _, cb in ipairs(scheduled) do
      cb()
    end
    assert_eq(#notifications, 0, "parser retry should not warn after the parser becomes available")
    assert_eq(render_calls, 1, "parser retry should kick a render once the parser becomes available")
  end)

  vim.treesitter.get_parser = original_get_parser
  vim.defer_fn = original_defer_fn
  vim.schedule = original_schedule
  vim.notify = original_notify
  vim.api.nvim_buf_delete(bufnr, { force = true })

  if not ok_run then
    error(err)
  end
end

local function test_supports_typst_and_markdown_buffers()
  reset_modules()
  local concealer = require("typst-concealer")
  concealer.config = {
    markdown_filetypes = { "markdown" },
  }

  local typst_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(typst_bufnr, "only-typst.typ")
  vim.bo[typst_bufnr].filetype = "typst"
  assert_eq(concealer.source_kind_for_bufnr(typst_bufnr), "typst", "typst buffers should use typst source rules")
  assert_eq(concealer.is_supported_bufnr(typst_bufnr), true, "typst buffers should be supported")

  local markdown_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(markdown_bufnr, "owned.md")
  vim.bo[markdown_bufnr].filetype = "markdown"
  assert_eq(
    concealer.source_kind_for_bufnr(markdown_bufnr),
    "markdown",
    "markdown buffers should use markdown source rules"
  )
  assert_eq(concealer.is_supported_bufnr(markdown_bufnr), true, "markdown buffers should be supported")

  local alma_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(alma_bufnr, "alma://thread/test")
  vim.bo[alma_bufnr].buftype = "nofile"
  vim.bo[alma_bufnr].filetype = "alma"
  assert_eq(concealer.source_kind_for_bufnr(alma_bufnr), nil, "alma buffers should not use markdown rules")
  assert_eq(concealer.is_supported_bufnr(alma_bufnr), false, "alma buffers should not be supported")

  vim.api.nvim_buf_delete(typst_bufnr, { force = true })
  vim.api.nvim_buf_delete(markdown_bufnr, { force = true })
  vim.api.nvim_buf_delete(alma_bufnr, { force = true })
end

local function test_custom_markdown_filetypes_are_supported()
  reset_modules()
  local concealer = require("typst-concealer")
  concealer.config = {
    markdown_filetypes = { "markdown", "copilot-chat" },
  }

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "copilot-chat")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].filetype = "copilot-chat"
  assert_eq(
    concealer.source_kind_for_bufnr(bufnr),
    "markdown",
    "custom markdown filetypes should use markdown source rules"
  )
  assert_eq(concealer.is_supported_bufnr(bufnr), true, "custom markdown filetypes should be supported")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_latex_buffers_require_enabled_backend()
  reset_modules()
  local concealer = require("typst-concealer")
  concealer.config = {
    markdown_filetypes = { "markdown" },
    backends = {
      latex = { enabled = false },
    },
  }

  local disabled_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(disabled_bufnr, "disabled.tex")
  vim.bo[disabled_bufnr].filetype = "tex"
  assert_eq(concealer.source_kind_for_bufnr(disabled_bufnr), nil, "latex buffers should be ignored when disabled")

  concealer.config.backends.latex.enabled = true
  assert_eq(concealer.source_kind_for_bufnr(disabled_bufnr), "latex", "tex buffers should use latex source rules")

  local plaintex_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(plaintex_bufnr, "plain")
  vim.bo[plaintex_bufnr].filetype = "plaintex"
  assert_eq(concealer.source_kind_for_bufnr(plaintex_bufnr), "latex", "plaintex buffers should use latex rules")

  local latex_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(latex_bufnr, "latex")
  vim.bo[latex_bufnr].filetype = "latex"
  assert_eq(concealer.source_kind_for_bufnr(latex_bufnr), "latex", "latex filetype buffers should use latex rules")

  vim.api.nvim_buf_delete(disabled_bufnr, { force = true })
  vim.api.nvim_buf_delete(plaintex_bufnr, { force = true })
  vim.api.nvim_buf_delete(latex_bufnr, { force = true })
end

local function test_latex_wrapper_applies_configured_color_to_math_modes()
  reset_modules()
  local wrapper = require("typst-concealer.latex-wrapper")
  local context = wrapper.build_context_document({ preamble_source = "" }, { color = "#a1b2c3" })

  assert_truthy(
    context:find("\\color[HTML]{A1B2C3}", 1, true) ~= nil,
    "latex context should apply the configured foreground color"
  )
  assert_truthy(
    context:find("\\everymath\\expandafter{\\the\\everymath\\color[HTML]{A1B2C3}}", 1, true) ~= nil,
    "latex context should apply the configured foreground color to inline math"
  )
  assert_truthy(
    context:find("\\everydisplay\\expandafter{\\the\\everydisplay\\color[HTML]{A1B2C3}}", 1, true) ~= nil,
    "latex context should apply the configured foreground color to display math"
  )
end

local function test_latex_scope_uses_empty_preamble_without_document_boundary()
  local root =
    vim.fs.normalize(vim.fn.fnamemodify(vim.fn.tempname() .. "-latex-body-only-preamble", ":p")):gsub("/$", "")
  assert(vim.fn.mkdir(root, "p") == 1)
  local main_path = vim.fs.joinpath(root, "body.tex")
  write_file(main_path, "$x$\n")
  main_path = real_path(main_path)

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, main_path)
  vim.bo[bufnr].filetype = "plaintex"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$" })

  fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      ppi = 300,
      compiler_args = {},
      do_diagnostics = false,
      header = "",
      backends = {
        latex = {
          enabled = true,
          compiler_args = {},
          get_root = function()
            return root
          end,
        },
      },
    },
    _styling_prelude = "",
    source_kind_for_bufnr = function()
      return "latex"
    end,
  }

  local scope = require("typst-concealer.project-scope").resolve(bufnr, "full")
  assert_eq(scope.preamble_source, "", "body-only LaTeX buffers should not become their own preamble")
  local context = require("typst-concealer.latex-wrapper").build_context_document(scope, {})
  assert_truthy(context:find("$x$", 1, true) == nil, "body-only formula source should not be injected before document")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function fake_ts_node(id, node_type, range, children)
  children = children or {}
  return {
    id = function()
      return id
    end,
    type = function()
      return node_type
    end,
    range = function()
      return range[1], range[2], range[3], range[4]
    end,
    named = function()
      return true
    end,
    iter_children = function()
      local idx = 0
      return function()
        idx = idx + 1
        return children[idx]
      end
    end,
  }
end

local function with_fake_latex_query(matches, fn)
  local original_parse = vim.treesitter.query.parse
  vim.treesitter.query.parse = function(lang)
    assert_eq(lang, "latex", "latex adapter should parse a latex query")
    return {
      iter_matches = function()
        local idx = 0
        return function()
          idx = idx + 1
          local node = matches[idx]
          if node == nil then
            return nil
          end
          return idx, { [1] = { node } }, nil
        end
      end,
    }
  end

  local ok_run, err = pcall(fn)
  vim.treesitter.query.parse = original_parse
  if not ok_run then
    error(err)
  end
end

local function test_markdown_adapter_collects_inline_and_block_math()
  reset_modules()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "Inline $x + y$ text.",
    "",
    "$$",
    "\\frac{1}{2}",
    "$$",
    "```",
    "$ignored$",
    "```",
  })

  local entries = require("typst-concealer.source-adapters.markdown").collect(bufnr)
  assert_eq(#entries, 2, "markdown adapter should collect inline and block math outside fences")
  assert_truthy(vim.deep_equal(entries[1].range, { 0, 7, 0, 14 }), "inline math range should include dollar delimiters")
  assert_eq(entries[1].source_text, "$x + y$", "inline source text should preserve markdown delimiters")
  assert_eq(entries[1].render_text, '#mi("x + y")', "inline math should render through MiTeX mi")
  assert_eq(entries[1].semantics.display_kind, "inline", "inline math should keep inline display semantics")
  assert_truthy(vim.deep_equal(entries[2].range, { 2, 0, 4, 2 }), "block math range should include display delimiters")
  assert_eq(entries[2].source_text, "$$\n\\frac{1}{2}\n$$", "block source text should preserve markdown delimiters")
  assert_eq(entries[2].render_text, '#mitex("\\\\frac{1}{2}")', "block math should render through MiTeX mitex")
  assert_eq(entries[2].semantics.display_kind, "block", "block math should use block display semantics")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_latex_adapter_collects_top_level_math()
  reset_modules()
  local env_line = "\\begin{equation} z $nested$ \\end{equation}"
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "Inline $x$ text.",
    "\\[",
    "y^2",
    "\\]",
    env_line,
  })

  local inline = fake_ts_node(2, "inline_formula", { 0, 7, 0, 10 })
  local display = fake_ts_node(3, "displayed_equation", { 1, 0, 3, 2 })
  local nested = fake_ts_node(5, "inline_formula", { 4, 19, 4, 27 })
  local env = fake_ts_node(4, "math_environment", { 4, 0, 4, #env_line }, { nested })
  local root = fake_ts_node(1, "source_file", { 0, 0, 4, #env_line }, { inline, display, env })
  local parser = {
    parse = function()
      return {
        {
          root = function()
            return root
          end,
        },
      }
    end,
  }

  with_fake_latex_query({ inline, display, env, nested }, function()
    local entries = require("typst-concealer.source-adapters.latex").collect(bufnr, { parser = parser })
    assert_eq(#entries, 3, "latex adapter should collect only top-level math nodes")
    assert_eq(entries[1].source_text, "$x$", "inline source should preserve delimiters")
    assert_eq(entries[1].backend_node_type, "inline_formula", "inline backend node type should be preserved")
    assert_eq(entries[1].semantics.source_kind, "latex", "latex semantics should route as latex")
    assert_eq(entries[1].semantics.display_kind, "inline", "inline formula should use inline semantics")
    assert_eq(entries[2].source_text, "\\[\ny^2\n\\]", "display source should preserve delimiters")
    assert_eq(entries[2].semantics.display_kind, "block", "display formula should use block semantics")
    assert_eq(entries[3].backend_node_type, "math_environment", "math environments should be preserved")

    local stable_key = entries[1].stable_key
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "Inline $z$ text." })
    local next_entries = require("typst-concealer.source-adapters.latex").collect(bufnr, {
      parser = parser,
      prev_units = select(2, require("typst-concealer.source-adapters.latex").collect(bufnr, { parser = parser })),
      pending_change = {
        start_row = 0,
        old_end_row = 0,
        new_end_row = 0,
        line_delta = 0,
        requires_full = false,
      },
    })
    assert_eq(next_entries[1].stable_key, stable_key, "same-range latex edits should keep stable keys")
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_latex_adapter_collects_buffer_independent_of_viewport()
  reset_modules()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "Hidden $a$.",
    "",
    "Visible $b$.",
    "\\[",
    "c",
    "\\]",
  })

  local hidden = fake_ts_node(2, "inline_formula", { 0, 7, 0, 10 })
  local visible = fake_ts_node(3, "inline_formula", { 2, 8, 2, 11 })
  local spanning = fake_ts_node(4, "displayed_equation", { 3, 0, 5, 2 })
  local root = fake_ts_node(1, "source_file", { 0, 0, 5, 2 }, { hidden, visible, spanning })
  local parser = {
    parse = function()
      return {
        {
          root = function()
            return root
          end,
        },
      }
    end,
  }

  with_fake_latex_query({ hidden, visible, spanning }, function()
    local entries = require("typst-concealer.source-adapters.latex").collect(bufnr, {
      parser = parser,
      viewport = {
        kind = "visible",
        ranges = {
          { top = 2, bottom = 4 },
        },
      },
    })
    assert_eq(#entries, 3, "latex adapter should collect all math; render coverage is planner-owned")
    assert_eq(entries[1].source_text, "$a$", "hidden inline math should remain in the scan model")
    assert_eq(entries[2].source_text, "$b$", "visible inline math should be included")
    assert_eq(entries[3].source_text, "\\[\nc\n\\]", "math spanning the viewport should be included")
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_viewport_change_tracking_is_adapter_scoped()
  local state = fresh_state()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, "viewport.tex")
  vim.bo[bufnr].filetype = "tex"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$" })

  package.loaded["typst-concealer"] = {
    config = {
      markdown_filetypes = { "markdown" },
      backends = {
        latex = { enabled = true, viewport_margin = 0 },
      },
    },
    source_kind_for_bufnr = function()
      return "latex"
    end,
  }

  local viewport = require("typst-concealer.viewport")
  local changed, resolved, key = viewport.changed_since_last_render(bufnr)
  assert_eq(changed, true, "latex progressive policy should request an initial viewport render")
  assert_eq(resolved.kind, "visible", "latex adapter should choose a visible render viewport")
  state.buffer_render_state[bufnr] = { render_viewport_key = key, render_coverage_complete = true }
  changed = viewport.changed_since_last_render(bufnr)
  assert_eq(changed, false, "unchanged latex viewport should not schedule another scroll render")

  package.loaded["typst-concealer"].source_kind_for_bufnr = function()
    return "typst"
  end
  changed, resolved = viewport.changed_since_last_render(bufnr)
  assert_eq(changed, false, "whole-buffer adapters should not schedule viewport-change renders")
  assert_eq(resolved.kind, "buffer", "typst adapter should use the whole buffer viewport")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_render_buf_scans_markdown_math_nodes()
  reset_modules()
  local state = require("typst-concealer.state")
  state.machine_state = require("typst-concealer.machine.types").initial_state()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "render-markdown.md")
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "Inline $x + y$.",
    "$$",
    "z^2",
    "$$",
  })

  local dispatched = {}
  package.loaded["typst-concealer"] = {
    _enabled_buffers = { [bufnr] = true },
    config = {
      do_diagnostics = false,
      live_preview_enabled = false,
      use_formula_service = false,
      header = "",
      ppi = 300,
    },
    _styling_prelude = "",
    is_render_allowed = function()
      return true
    end,
    source_kind_for_bufnr = function()
      return "markdown"
    end,
  }
  package.loaded["typst-concealer.machine.runtime"] = {
    reconcile_visible_overlay_bindings = function()
      return 0
    end,
    dispatch = function(event)
      dispatched[#dispatched + 1] = event
    end,
    invalidate_hover = function() end,
    get_ui_buffer = function()
      return {
        hover = {},
        preview = {},
      }
    end,
  }

  require("typst-concealer.plan").render_buf(bufnr)
  local scanned = dispatched[1]
  assert_eq(scanned.type, "nodes_scanned", "markdown render should dispatch scanned nodes")
  assert_eq(#scanned.scanned_nodes, 2, "markdown render should scan inline and block math")
  assert_eq(scanned.scanned_nodes[1].source_text, '#mi("x + y")', "inline node should carry MiTeX render text")
  assert_eq(scanned.scanned_nodes[1].source_str, "$x + y$", "inline node should keep original markdown source")
  assert_eq(scanned.scanned_nodes[1].semantics.display_kind, "inline", "inline node should keep inline semantics")
  assert_eq(scanned.scanned_nodes[1].requires_mitex, true, "inline node should request MiTeX import")
  assert_eq(scanned.scanned_nodes[2].source_text, '#mitex("z^2")', "block node should carry MiTeX render text")
  assert_eq(scanned.scanned_nodes[2].semantics.display_kind, "block", "block node should keep block semantics")

  vim.wait(10)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_render_buf_scans_latex_math_nodes()
  reset_modules()
  local state = require("typst-concealer.state")
  state.machine_state = require("typst-concealer.machine.types").initial_state()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, "render-latex.tex")
  vim.bo[bufnr].filetype = "tex"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Inline $x$." })

  local inline = fake_ts_node(2, "inline_formula", { 0, 7, 0, 10 })
  local root = fake_ts_node(1, "source_file", { 0, 0, 0, 11 }, { inline })
  local parser = {
    parse = function()
      return {
        {
          root = function()
            return root
          end,
        },
      }
    end,
  }

  local original_get_parser = vim.treesitter.get_parser
  local manager_event = nil
  local cursor_conceal_calls = 0
  package.loaded["typst-concealer"] = {
    _enabled_buffers = { [bufnr] = true },
    config = {
      do_diagnostics = false,
      live_preview_enabled = false,
      use_formula_service = false,
      header = "",
      ppi = 300,
      compiler_args = {},
      backends = {
        latex = { enabled = true, compiler_args = {} },
      },
    },
    _styling_prelude = "",
    is_render_allowed = function()
      return true
    end,
    source_kind_for_bufnr = function()
      return "latex"
    end,
  }
  package.loaded["typst-concealer.formula.manager"] = {
    update_from_scan = function(event)
      manager_event = event
    end,
    sync_cursor_conceal = function()
      cursor_conceal_calls = cursor_conceal_calls + 1
    end,
  }
  package.loaded["typst-concealer.machine.runtime"] = {
    reconcile_visible_overlay_bindings = function()
      return 0
    end,
    dispatch = function() end,
    invalidate_hover = function() end,
    get_ui_buffer = function()
      return {
        hover = {},
        preview = {},
      }
    end,
  }

  with_fake_latex_query({ inline }, function()
    vim.treesitter.get_parser = function(_, lang)
      assert_eq(lang, "latex", "latex render should request the latex parser")
      return parser
    end
    require("typst-concealer.plan").render_buf(bufnr)
  end)
  vim.treesitter.get_parser = original_get_parser

  local scanned = manager_event
  assert_truthy(scanned ~= nil, "latex scan should use the formula manager even when formula service is disabled")
  assert_eq(scanned.type, "nodes_scanned", "latex render should dispatch scanned nodes")
  assert_eq(#scanned.scanned_nodes, 1, "latex render should scan inline math")
  assert_eq(scanned.scanned_nodes[1].source_text, "$x$", "latex node should carry raw source")
  assert_eq(scanned.scanned_nodes[1].source_str, "$x$", "latex node should keep original source")
  assert_eq(scanned.scanned_nodes[1].backend_node_type, "inline_formula", "latex node should keep backend type")
  assert_eq(scanned.scanned_nodes[1].semantics.source_kind, "latex", "latex node should keep latex semantics")
  assert_eq(cursor_conceal_calls, 1, "latex cursor sync should use formula-manager hover routing")

  vim.wait(10)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_render_buf_routes_latex_scan_through_formula_manager()
  reset_modules()
  local state = require("typst-concealer.state")
  state.machine_state = require("typst-concealer.machine.types").initial_state()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, "render-latex-manager.tex")
  vim.bo[bufnr].filetype = "tex"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Inline $x$." })

  local inline = fake_ts_node(2, "inline_formula", { 0, 7, 0, 10 })
  local root = fake_ts_node(1, "source_file", { 0, 0, 0, 11 }, { inline })
  local parser = {
    parse = function()
      return {
        {
          root = function()
            return root
          end,
        },
      }
    end,
  }

  local original_get_parser = vim.treesitter.get_parser
  local manager_event = nil
  package.loaded["typst-concealer"] = {
    _enabled_buffers = { [bufnr] = true },
    config = {
      do_diagnostics = false,
      live_preview_enabled = false,
      use_formula_service = false,
      header = "",
      ppi = 300,
      compiler_args = {},
      backends = {
        latex = { enabled = true, compiler_args = {} },
      },
    },
    _styling_prelude = "",
    is_render_allowed = function()
      return true
    end,
    source_kind_for_bufnr = function()
      return "latex"
    end,
  }
  package.loaded["typst-concealer.formula.manager"] = {
    update_from_scan = function(event)
      manager_event = event
    end,
    sync_cursor_conceal = function() end,
  }
  package.loaded["typst-concealer.machine.runtime"] = {
    reconcile_visible_overlay_bindings = function()
      return 0
    end,
    dispatch = function() end,
    invalidate_hover = function() end,
    get_ui_buffer = function()
      return {
        hover = {},
        preview = {},
      }
    end,
  }

  with_fake_latex_query({ inline }, function()
    vim.treesitter.get_parser = function(_, lang)
      assert_eq(lang, "latex", "latex render should request the latex parser")
      return parser
    end
    require("typst-concealer.plan").render_buf(bufnr)
  end)
  vim.treesitter.get_parser = original_get_parser

  assert_truthy(manager_event ~= nil, "latex scans should be handed to formula manager")
  assert_eq(manager_event.type, "nodes_scanned", "formula manager should receive nodes_scanned")
  assert_eq(#manager_event.scanned_nodes, 1, "formula manager should receive latex node")
  assert_eq(
    manager_event.scanned_nodes[1].semantics.source_kind,
    "latex",
    "manager event should preserve latex semantics"
  )

  vim.wait(10)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_vim_resized_renders_on_column_change()
  local state = fresh_state()
  local main = require("typst-concealer")
  main.config = {
    markdown_filetypes = { "markdown" },
    render_paths = {},
    math_baseline_pt = 11,
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, "resize-columns.typ")
  vim.bo[bufnr].filetype = "typst"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "#rect(width: 100%)" })
  main._enabled_buffers[bufnr] = true

  local calls = { render = 0, refresh = 0 }
  package.loaded["typst-concealer.machine.runtime"] = {
    render_buf = function(target)
      if target == bufnr then
        calls.render = calls.render + 1
      end
    end,
    refresh_visible_overlays = function(target)
      if target == bufnr then
        calls.refresh = calls.refresh + 1
      end
    end,
  }

  local original_columns = vim.o.columns
  main._handle_vim_resized()
  calls.render = 0
  calls.refresh = 0
  vim.o.columns = original_columns + 1
  main._handle_vim_resized()
  vim.o.columns = original_columns

  assert_eq(calls.render, 1, "column-only resize should schedule a render pass")
  assert_eq(calls.refresh, 0, "column-only resize should not only reupload existing images")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  state.buffer_render_state = {}
end

_G.__typst_concealer_regression_tests = function()
  test_extmark_flushes_kitty_graphics_through_ui_send()
  ok("ok extmark flushes kitty graphics through nvim_ui_send")
  test_extmark_flushes_kitty_graphics_to_stdout_when_ui_send_fails()
  ok("ok extmark falls back to stdout when nvim_ui_send fails")
  test_render_buf_suppresses_stale_parser_warning()
  ok("ok render_buf suppresses stale parser warnings")
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

  fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
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

  local scope = require("typst-concealer.project-scope").resolve(bufnr, "full")
  assert_eq(scope.source_root, cwd_root, "project scope should match cwd fallback root base")
  assert_eq(scope.effective_root, cwd_root, "effective root should match root base")

  local path_rewrite = require("typst-concealer.path-rewrite")
  local rewritten = path_rewrite.rewrite_paths('#import "' .. template_path .. '": foo', {
    bufnr = bufnr,
    buf_dir = project,
    source_root = scope.source_root,
    effective_root = scope.effective_root,
  })
  assert_eq(
    rewritten,
    '#import "/typ/templates/blog-preview.typ": foo',
    "absolute import should rewrite relative to cwd root base"
  )

  vim.api.nvim_buf_delete(bufnr, { force = true })
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

  fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
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
  local scope = require("typst-concealer.project-scope").resolve(bufnr, "full")
  assert_eq(scope.source_root, alt_root, "get_root should override cwd/project fallback")
  assert_eq(scope.effective_root, alt_root, "effective root should use get_root")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_service_cleanup_removes_latex_work_directories()
  local root = make_temp_tree("latex-work-cleanup")
  local workspace = vim.fs.joinpath(root, "workspace")
  local output_dir = vim.fs.joinpath(workspace, "out")
  local work_dir = vim.fs.joinpath(output_dir, "latex-work-node-abc123")
  local nested_dir = vim.fs.joinpath(work_dir, "nested")
  assert(vim.fn.mkdir(nested_dir, "p") == 1)
  write_file(vim.fs.joinpath(work_dir, "node.tex"), "$x$\n")
  write_file(vim.fs.joinpath(work_dir, "node.pdf"), "pdf")
  write_file(vim.fs.joinpath(work_dir, "node.log"), "log")
  write_file(vim.fs.joinpath(nested_dir, "node.aux"), "aux")

  local state = fresh_state()
  local bufnr = 12345
  state.service_cache_dirs[bufnr] = output_dir
  state.service_workspace_dirs[bufnr] = workspace

  require("typst-concealer.session").stop_compiler_service(bufnr)
  assert_eq(vim.uv.fs_stat(work_dir), nil, "LaTeX work directories should be removed during service cleanup")
  assert_eq(state.service_cache_dirs[bufnr], nil, "service cleanup should clear cache dir tracking")
  assert_eq(state.service_workspace_dirs[bufnr], nil, "service cleanup should clear workspace dir tracking")
end

local function test_session_render_request_tracks_active_service_request()
  local root = make_temp_tree("service-request-meta")
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
        service_binary = "typst-concealer-service-test",
        use_formula_service = false,
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

    session_mod.render_request_via_service(bufnr, request)
    local meta = state.active_service_requests[bufnr]
    assert_eq(meta.request_id, "request:1", "service should track current request id")
    assert_eq(meta.status, "active", "new request should be active")
    assert_eq(meta.page_to_slot[1], "slot:1", "page should map to a stable slot")
    assert_eq(meta.slot_to_overlay["slot:1"], "overlay:1", "slot should map to overlay")
    assert_eq(meta.jobs[1].overlay_id, "overlay:1", "request jobs should be retained in service metadata")

    local old_request = meta
    local request2 = vim.deepcopy(request)
    request2.request_id = "request:2"
    request2.jobs[1].request_id = "request:2"
    session_mod.render_request_via_service(bufnr, request2)
    assert_eq(old_request.status, "abandoned", "replaced request should be abandoned")
    assert_eq(
      state.active_service_requests[bufnr].request_id,
      "request:2",
      "service should install replacement request"
    )
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
        use_formula_service = true,
        formula_worker_count = 2,
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
          node_rev = 1,
          context_id = "project:service",
          context_rev = 1,
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
    assert_eq(msg.type, "render_formulas", "service message should be a formula render request")
    assert_eq(msg.request_id, "request:service:1", "service message should carry request_id")
    assert_truthy(msg.cache_key:find("^formula:", 1, false) ~= nil, "service message should isolate formula cache")
    assert_eq(msg.context_id, "project:service", "formula request should carry context_id")
    assert_eq(msg.context_rev, 1, "formula request should carry context_rev")
    assert_eq(msg.worker_count, 2, "formula request should carry configured worker count")
    assert_eq(msg.root, root, "service message should carry effective root")
    assert_eq(msg.inputs.concealed, "true", "service message should include project inputs")
    assert_truthy(
      msg.output_dir:find("/%.typst%-concealer/", 1, false) ~= nil,
      "service output_dir should use cache dir"
    )
    assert_truthy(msg.context_source:find("$x$", 1, true) == nil, "formula context should not inline formula text")
    assert_eq(#msg.nodes, 1, "formula request should include one dirty formula")
    assert_eq(msg.nodes[1].node_id, "node:service", "formula node should carry node_id")
    assert_eq(msg.nodes[1].node_rev, 1, "formula node should carry node_rev")
    assert_truthy(msg.nodes[1].source:find("$x$", 1, true) ~= nil, "formula node source should contain formula text")
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

local function test_latex_service_request_writes_backend_json()
  local root = make_temp_tree("latex-service-request")
  local main_path = vim.fs.joinpath(root, "main.tex")
  write_file(main_path, "\\begin{document}\n$x$\n\\end{document}\n")

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, main_path)
  vim.bo[bufnr].filetype = "tex"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "\\begin{document}",
    "$x$",
    "\\end{document}",
  })
  local state = fresh_state()
  state.buffer_render_state[bufnr] = { runtime_preludes = {} }

  with_stubbed_uv(function(spawned)
    package.loaded["typst-concealer"] = {
      config = {
        use_formula_service = false,
        formula_worker_count = 2,
        service_binary = "typst-concealer-service-test",
        ppi = 300,
        compiler_args = {},
        do_diagnostics = false,
        header = "",
        backends = {
          latex = {
            enabled = true,
            compiler = "pdflatex",
            converter = "pdftocairo",
            compiler_args = { "-shell-escape" },
            header = "\\usepackage{bm}",
            get_root = function()
              return root
            end,
          },
        },
      },
      _styling_prelude = "",
      source_kind_for_bufnr = function()
        return "latex"
      end,
    }

    local session_mod = require("typst-concealer.session")
    local scope = require("typst-concealer.project-scope").resolve(bufnr, "full")
    assert_eq(scope.backend_id, "latex", "latex buffers should resolve latex project scope")
    local request = {
      request_id = "request:latex:1",
      bufnr = bufnr,
      project_scope_id = "project:latex",
      render_epoch = 1,
      buffer_version = 1,
      layout_version = 1,
      jobs = {
        {
          request_page_index = 1,
          overlay_id = "overlay:latex",
          node_id = "node:latex",
          bufnr = bufnr,
          project_scope_id = "project:latex",
          render_epoch = 1,
          node_rev = 1,
          context_id = "project:latex",
          context_rev = 1,
          buffer_version = 1,
          layout_version = 1,
          item_idx = 1,
          range = { 1, 0, 1, 3 },
          display_range = { 1, 0, 1, 3 },
          source_text = "$x$",
          source_str = "$x$",
          str = "$x$",
          source_text_hash = "hash:x",
          backend_node_type = "inline_formula",
          prelude_count = 0,
          semantics = {
            backend_id = "latex",
            backend_node_type = "inline_formula",
            display_kind = "inline",
            constraint_kind = "intrinsic",
            source_kind = "latex",
          },
          image_id = 101,
        },
      },
    }

    session_mod.render_request_via_service(bufnr, request)
    assert_eq(#spawned, 1, "latex full render should not prewarm a Typst preview service")
    local stdin = spawned[1].stdio[1]
    assert_eq(#stdin.writes, 1, "latex service request should be written to stdin")
    local msg = vim.json.decode(vim.trim(stdin.writes[1]))
    assert_eq(msg.type, "render_formulas", "latex should still use formula batch transport")
    assert_eq(msg.backend, "latex", "latex service message should carry backend id")
    assert_eq(msg.compiler, "pdflatex", "latex service message should carry compiler")
    assert_eq(msg.converter, "pdftocairo", "latex service message should carry converter")
    assert_eq(msg.compiler_args[1], "-shell-escape", "latex service message should carry compiler args")
    assert_eq(msg.root, root, "latex service message should carry effective root")
    assert_truthy(msg.context_source:find("\\usepackage{bm}", 1, true) ~= nil, "latex context should include header")
    assert_truthy(msg.context_source:find("$x$", 1, true) == nil, "latex context should not inline formula source")
    assert_eq(#msg.nodes, 1, "latex request should include one formula node")
    assert_eq(msg.nodes[1].source, "$x$", "latex node source should stay raw LaTeX")
    assert_eq(msg.nodes[1].kind, "inline_formula", "latex node kind should preserve backend node type")
    assert_eq(state.active_service_requests[bufnr].service_engine, "latex", "latex request meta should record engine")
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_latex_preview_uses_preview_service_and_accepts_formula_response()
  local root = make_temp_tree("latex-preview")
  local main_path = vim.fs.joinpath(root, "main.tex")
  write_file(main_path, "\\begin{document}\n$x$\n\\end{document}\n")

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, main_path)
  vim.bo[bufnr].filetype = "tex"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "\\begin{document}",
    "$x$",
    "\\end{document}",
  })
  local state = fresh_state()
  state.buffer_render_state[bufnr] = { runtime_preludes = {} }

  with_stubbed_uv(function(spawned)
    package.loaded["typst-concealer"] = {
      config = {
        service_binary = "typst-concealer-service-test",
        ppi = 300,
        compiler_args = {},
        do_diagnostics = false,
        header = "",
        backends = {
          latex = {
            enabled = true,
            compiler = "pdflatex",
            converter = "pdftocairo",
            compiler_args = {},
            get_root = function()
              return root
            end,
          },
        },
      },
      _styling_prelude = "",
      source_kind_for_bufnr = function()
        return "latex"
      end,
    }

    package.loaded["typst-concealer.png-lua"] = function()
      return { width = 24, height = 12 }
    end

    local accepted_update = nil
    package.loaded["typst-concealer.machine.runtime"] = {
      accept_preview_page_update = function(update)
        accepted_update = update
        return true
      end,
    }

    local session_mod = require("typst-concealer.session")
    local item = {
      bufnr = bufnr,
      node_id = "node:latex-preview",
      node_rev = 1,
      context_id = "project:latex-preview",
      context_rev = 1,
      preview_request_id = "preview:latex:1",
      range = { 1, 0, 1, 3 },
      source_text = "$x$",
      source_str = "$x$",
      str = "$x$",
      source_text_hash = "hash:x",
      backend_node_type = "inline_formula",
      semantics = {
        backend_id = "latex",
        backend_node_type = "inline_formula",
        display_kind = "inline",
        constraint_kind = "intrinsic",
        source_kind = "latex",
      },
    }

    session_mod.render_preview_tail_via_service(bufnr, item)
    assert_eq(#spawned, 1, "latex preview should use the preview service only")
    local stdin = spawned[1].stdio[1]
    local stdout = spawned[1].stdio[2]
    assert_eq(#stdin.writes, 1, "latex preview request should be written")
    local msg = vim.json.decode(vim.trim(stdin.writes[1]))
    assert_eq(msg.type, "render_formulas", "latex preview should use formula transport")
    assert_eq(msg.backend, "latex", "latex preview request should carry backend id")
    assert_eq(msg.request_id, "preview:latex:1", "latex preview request should carry preview id")
    assert_eq(msg.nodes[1].source, "$x$", "latex preview node should use raw source")

    stdout:feed(vim.json.encode({
      type = "formula_rendered",
      request_id = "preview:latex:1",
      context_id = msg.context_id,
      context_rev = msg.context_rev,
      node_id = msg.nodes[1].node_id,
      node_rev = msg.nodes[1].node_rev,
      status = "ok",
      path = vim.fs.joinpath(root, "preview.png"),
      width_px = 24,
      height_px = 12,
      diagnostics = {},
    }) .. "\n")

    vim.wait(10, function()
      return accepted_update ~= nil
    end)
    assert_truthy(accepted_update ~= nil, "latex preview formula response should update preview")
    assert_eq(accepted_update.preview_request_id, "preview:latex:1", "preview update should keep request id")
    assert_eq(accepted_update.page_path, vim.fs.joinpath(root, "preview.png"), "preview update should use response PNG")
    assert_eq(state.active_preview_service_requests[bufnr], nil, "latex preview response should clear active preview")
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
        use_formula_service = opts.use_formula_service == true,
        formula_worker_count = opts.formula_worker_count or 2,
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
          node_rev = opts.node_rev or 1,
          context_id = opts.context_id or opts.project_scope_id or "project:service",
          context_rev = opts.context_rev or 1,
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
        job.node_rev = job.node_rev or opts.node_rev or 1
        job.context_id = job.context_id or opts.context_id or opts.project_scope_id or "project:service"
        job.context_rev = job.context_rev or opts.context_rev or 1
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
        node_rev = job.node_rev,
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
          node_rev = job.node_rev,
          context_id = job.context_id,
          context_rev = job.context_rev,
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
      context_id = opts.context_id or opts.project_scope_id or "project:service",
      context_rev = opts.context_rev or 1,
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
      preview_stdout = spawned[2] and spawned[2].stdio[2] or nil,
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

local function wait_until_formula_batch_cleared(state, bufnr, request_id)
  vim.wait(100, function()
    local batches = state.active_formula_batches and state.active_formula_batches[bufnr] or nil
    return batches == nil or batches[request_id] == nil
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

local function test_formula_service_success_routes_by_node_revision()
  make_service_response_harness("formula-success", { use_formula_service = true, context_rev = 7 }, function(ctx)
    local msg = vim.json.decode(vim.trim(ctx.spawned[1].stdio[1].writes[1]))
    assert_eq(msg.type, "render_formulas", "formula service should use formula-level request")
    assert_eq(msg.context_rev, 7, "formula request should include context revision")
    assert_eq(#msg.nodes, 1, "formula request should render only dirty formula nodes")
    assert_eq(msg.nodes[1].node_id, ctx.request.jobs[1].node_id, "formula request should identify node")
    assert_eq(msg.nodes[1].node_rev, ctx.request.jobs[1].node_rev, "formula request should identify node revision")

    local page_path = vim.fn.tempname() .. ".png"
    write_file(page_path, "png")
    with_stubbed_extmark(function(calls)
      feed_service_response(ctx.full_stdout, {
        type = "formula_rendered",
        request_id = ctx.request.request_id,
        context_id = ctx.request.jobs[1].context_id,
        context_rev = ctx.request.jobs[1].context_rev,
        node_id = ctx.request.jobs[1].node_id,
        node_rev = ctx.request.jobs[1].node_rev,
        status = "ok",
        path = page_path,
        width_px = 20,
        height_px = 10,
        cached = false,
        diagnostics = {},
      })
      wait_until_service_request_cleared(ctx.state, ctx.bufnr)
      assert_eq(#calls.created, 1, "formula response should upload the matching formula image")
      assert_eq(calls.created[1].path, page_path, "formula response should use formula artifact path")
    end)

    assert_eq(ctx.state.active_service_requests[ctx.bufnr], nil, "formula response should clear active meta")
    assert_eq(
      ctx.state._last_service_bench.service_engine,
      "formula",
      "formula response should record formula bench data"
    )
    assert_eq(ctx.state._last_service_bench.dispatched, 1, "formula bench should count dispatched formulas")
  end)
end

local function test_formula_transport_batch_does_not_install_buffer_active_request()
  local root = make_temp_tree("formula-transport-batch")
  local main_path = vim.fs.joinpath(root, "main.typ")
  write_file(main_path, "$x$")

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, main_path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$" })
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local state = fresh_state()
  state.pid = 8100
  state.buffer_render_state[bufnr] = { runtime_preludes = {} }

  with_stubbed_uv(function(spawned)
    package.loaded["typst-concealer"] = {
      config = {
        use_formula_service = true,
        formula_worker_count = 2,
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
        math_baseline_pt = 11,
      },
      _styling_prelude = "",
    }

    local request = {
      request_id = "formula:transport:1",
      bufnr = bufnr,
      project_scope_id = "project:transport",
      render_epoch = 1,
      buffer_version = tick,
      layout_version = 1,
      jobs = {
        {
          request_page_index = 1,
          overlay_id = "overlay:transport:1",
          node_id = "node:transport:1",
          slot_id = "slot:1",
          bufnr = bufnr,
          project_scope_id = "project:transport",
          render_epoch = 1,
          node_rev = 1,
          context_id = "project:transport",
          context_rev = 1,
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
    }
    state.machine_state.buffers[bufnr] = {
      bufnr = bufnr,
      project_scope_id = "project:transport",
      buffer_version = tick,
      layout_version = 1,
      render_epoch = 1,
      context_id = "project:transport",
      context_rev = 1,
      active_request_id = nil,
      nodes = {
        ["node:transport:1"] = {
          node_id = "node:transport:1",
          slot_id = "slot:1",
          bufnr = bufnr,
          project_scope_id = "project:transport",
          item_idx = 1,
          node_type = "math",
          source_range = { 0, 0, 0, 3 },
          display_range = { 0, 0, 0, 3 },
          source_text = "$x$",
          source_text_hash = "hash:x",
          node_rev = 1,
          context_hash = "ctx:0",
          prelude_count = 0,
          semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
          status = "pending",
          candidate_overlay_id = "overlay:transport:1",
        },
      },
      node_order = { "node:transport:1" },
    }
    state.machine_state.overlays["overlay:transport:1"] = {
      overlay_id = "overlay:transport:1",
      slot_id = "slot:1",
      owner_node_id = "node:transport:1",
      owner_bufnr = bufnr,
      owner_project_scope_id = "project:transport",
      request_id = request.request_id,
      page_index = 1,
      render_epoch = 1,
      node_rev = 1,
      context_id = "project:transport",
      context_rev = 1,
      buffer_version = tick,
      layout_version = 1,
      status = "rendering",
    }

    local session_mod = require("typst-concealer.session")
    session_mod.render_formula_batch_via_service(bufnr, request)
    assert_eq(state.active_service_requests[bufnr], nil, "formula transport must not install buffer active request")
    assert_truthy(
      state.active_formula_batches[bufnr] and state.active_formula_batches[bufnr][request.request_id],
      "formula transport should track only the batch"
    )
    local msg = vim.json.decode(vim.trim(spawned[1].stdio[1].writes[1]))
    assert_eq(msg.type, "render_formulas", "formula transport should use render_formulas")
    assert_eq(#msg.nodes, 1, "formula transport should include the dirty node")

    local page_path = vim.fn.tempname() .. ".png"
    write_file(page_path, "png")
    with_stubbed_extmark(function(calls)
      feed_service_response(spawned[1].stdio[2], {
        type = "formula_rendered",
        request_id = request.request_id,
        context_id = "project:transport",
        context_rev = 1,
        node_id = "node:transport:1",
        node_rev = 1,
        status = "ok",
        path = page_path,
        width_px = 20,
        height_px = 10,
        cached = false,
        diagnostics = {},
      })
      wait_until_formula_batch_cleared(state, bufnr, request.request_id)
      assert_eq(#calls.created, 1, "formula transport response should upload only the matching node")
    end)
    assert_eq(state.active_formula_batches[bufnr], nil, "completed formula batch should be removed")
    session_mod.stop_compiler_service(bufnr)
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_formula_transport_prunes_superseded_queued_batches()
  make_service_response_harness("formula-queue-prune", { use_formula_service = true }, function(ctx)
    local base_job = ctx.request.jobs[1]
    local node = ctx.state.machine_state.buffers[ctx.bufnr].nodes[base_job.node_id]

    local function make_request(request_id, overlay_id, render_epoch)
      node.candidate_overlay_id = overlay_id
      node.status = "pending"
      ctx.state.machine_state.overlays[overlay_id] = {
        overlay_id = overlay_id,
        slot_id = base_job.slot_id,
        owner_node_id = base_job.node_id,
        owner_bufnr = ctx.bufnr,
        owner_project_scope_id = base_job.project_scope_id,
        request_id = request_id,
        page_index = 1,
        render_epoch = render_epoch,
        node_rev = base_job.node_rev,
        context_id = base_job.context_id,
        context_rev = base_job.context_rev,
        source_text_hash = base_job.source_text_hash,
        buffer_version = base_job.buffer_version,
        layout_version = base_job.layout_version,
        status = "placeholder",
      }

      local job = vim.deepcopy(base_job)
      job.overlay_id = overlay_id
      job.request_id = request_id
      job.render_epoch = render_epoch
      job.request_page_index = 1
      return {
        request_id = request_id,
        bufnr = ctx.bufnr,
        project_scope_id = base_job.project_scope_id,
        render_epoch = render_epoch,
        buffer_version = base_job.buffer_version,
        layout_version = base_job.layout_version,
        jobs = { job },
      }
    end

    local queued_request = make_request("formula:queued-stale", "overlay:queued-stale", 2)
    ctx.session.render_formula_batch_via_service(ctx.bufnr, queued_request)
    local service = ctx.state.compiler_services[ctx.bufnr].full
    assert_eq(#service.pending_formula_requests, 1, "busy service should queue the second formula batch")
    assert_truthy(
      ctx.state.active_formula_batches[ctx.bufnr]["formula:queued-stale"] ~= nil,
      "queued formula batch should be tracked until it is pruned"
    )

    ctx.state.machine_state.overlays["overlay:queued-stale"].status = "retiring"
    local current_request = make_request("formula:queued-current", "overlay:queued-current", 3)
    ctx.session.render_formula_batch_via_service(ctx.bufnr, current_request)

    assert_eq(#service.pending_formula_requests, 1, "superseded queued formula batch should be dropped")
    assert_eq(
      service.pending_formula_requests[1].request_id,
      "formula:queued-current",
      "queue should keep only the current formula batch"
    )
    assert_eq(
      ctx.state.active_formula_batches[ctx.bufnr]["formula:queued-stale"],
      nil,
      "pruning should remove stale formula batch bookkeeping"
    )
    assert_truthy(
      ctx.state.active_formula_batches[ctx.bufnr]["formula:queued-current"] ~= nil,
      "current queued formula batch should remain tracked"
    )
  end)
end

local function test_formula_transport_stale_response_reschedules_pending_node()
  local root = make_temp_tree("formula-stale-converges")
  local main_path = vim.fs.joinpath(root, "main.typ")
  write_file(main_path, "$x$")

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, main_path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$" })
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local state = fresh_state()
  state.pid = 8200
  state.buffer_render_state[bufnr] = { runtime_preludes = {} }

  with_stubbed_uv(function(spawned)
    package.loaded["typst-concealer"] = {
      config = {
        use_formula_service = true,
        formula_worker_count = 2,
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
        math_baseline_pt = 11,
      },
      _styling_prelude = "",
    }

    local old_job = {
      request_page_index = 1,
      overlay_id = "overlay:stale:old",
      node_id = "node:stale",
      slot_id = "slot:1",
      bufnr = bufnr,
      project_scope_id = "project:stale",
      render_epoch = 1,
      node_rev = 1,
      context_id = "project:stale",
      context_rev = 1,
      buffer_version = tick,
      layout_version = 1,
      item_idx = 1,
      range = { 0, 0, 0, 3 },
      display_range = { 0, 0, 0, 3 },
      source_text = "$x$",
      source_text_hash = "hash:x",
      str = "$x$",
      prelude_count = 0,
      semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
    }
    local request = {
      request_id = "formula:stale:old",
      bufnr = bufnr,
      project_scope_id = "project:stale",
      render_epoch = 1,
      buffer_version = tick,
      layout_version = 1,
      jobs = { old_job },
    }
    state.machine_state.buffers[bufnr] = {
      bufnr = bufnr,
      project_scope_id = "project:stale",
      buffer_version = tick,
      layout_version = 1,
      render_epoch = 1,
      context_id = "project:stale",
      context_rev = 1,
      nodes = {
        ["node:stale"] = {
          node_id = "node:stale",
          slot_id = "slot:1",
          bufnr = bufnr,
          project_scope_id = "project:stale",
          item_idx = 1,
          node_type = "math",
          source_range = { 0, 0, 0, 3 },
          display_range = { 0, 0, 0, 3 },
          source_text = "$x$",
          source_text_hash = "hash:x",
          node_rev = 1,
          context_hash = "ctx:1",
          prelude_count = 0,
          semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
          status = "pending",
          candidate_overlay_id = "overlay:stale:old",
        },
      },
      node_order = { "node:stale" },
      slots = {
        ["slot:1"] = {
          slot_id = "slot:1",
          node_id = "node:stale",
          page_index = 1,
          source_text = "$x$",
          source_text_hash = "hash:x",
          source_range = { 0, 0, 0, 3 },
          source_rows = 1,
          context_id = "project:stale",
          context_rev = 1,
          context_hash = "ctx:1",
          prelude_count = 0,
          node_type = "math",
          semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
          display_range = { 0, 0, 0, 3 },
          candidate_overlay_id = "overlay:stale:old",
          pending_request_id = "formula:stale:old",
          status = "dirty",
          dirty = true,
        },
      },
      slot_order = { "slot:1" },
      next_slot_id = 2,
    }
    state.machine_state.overlays["overlay:stale:old"] = {
      overlay_id = "overlay:stale:old",
      slot_id = "slot:1",
      owner_node_id = "node:stale",
      owner_bufnr = bufnr,
      owner_project_scope_id = "project:stale",
      request_id = "formula:stale:old",
      page_index = 1,
      render_epoch = 1,
      node_rev = 1,
      context_id = "project:stale",
      context_rev = 1,
      source_text_hash = "hash:x",
      buffer_version = tick,
      layout_version = 1,
      status = "rendering",
    }

    local session_mod = require("typst-concealer.session")
    session_mod.render_formula_batch_via_service(bufnr, request)
    assert_eq(#spawned[1].stdio[1].writes, 1, "old formula batch should be in flight")

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$y$" })
    local new_tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local buf = state.machine_state.buffers[bufnr]
    buf.buffer_version = new_tick
    buf.render_epoch = 2
    local node = buf.nodes["node:stale"]
    node.node_rev = 2
    node.source_text = "$y$"
    node.source_text_hash = "hash:y"
    node.status = "pending"
    node.candidate_overlay_id = nil
    local slot = buf.slots["slot:1"]
    slot.source_text = "$y$"
    slot.source_text_hash = "hash:y"
    slot.source_range = { 0, 0, 0, 3 }
    slot.display_range = { 0, 0, 0, 3 }
    slot.candidate_overlay_id = nil
    slot.pending_request_id = nil
    slot.status = "dirty"
    slot.dirty = true
    state.machine_state.overlays["overlay:stale:old"] = nil

    local stale_path = vim.fn.tempname() .. ".png"
    write_file(stale_path, "old png")
    feed_service_response(spawned[1].stdio[2], {
      type = "formula_rendered",
      request_id = "formula:stale:old",
      context_id = "project:stale",
      context_rev = 1,
      node_id = "node:stale",
      node_rev = 1,
      status = "ok",
      path = stale_path,
      width_px = 20,
      height_px = 10,
      diagnostics = {},
    })

    vim.wait(100, function()
      return #spawned[1].stdio[1].writes >= 2
    end)
    assert_eq(vim.uv.fs_stat(stale_path), nil, "stale formula artifact should be cleaned")
    assert_eq(#spawned[1].stdio[1].writes, 2, "stale response should trigger one converging formula batch")
    local next_msg = vim.json.decode(vim.trim(spawned[1].stdio[1].writes[2]))
    assert_eq(next_msg.type, "render_formulas", "convergence should stay on formula transport")
    assert_eq(#next_msg.nodes, 1, "convergence should target the pending node")
    assert_eq(next_msg.nodes[1].node_id, "node:stale", "convergence should keep node ownership")
    assert_eq(next_msg.nodes[1].node_rev, 2, "convergence should render the current node revision")
    assert_truthy(next_msg.nodes[1].source:find("$y$", 1, true) ~= nil, "convergence should render current source")

    session_mod.stop_compiler_service(bufnr)
  end)

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

local function test_formula_manager_self_check_reschedules_lost_candidate()
  local root = make_temp_tree("formula-self-check")
  local main_path = vim.fs.joinpath(root, "main.typ")
  write_file(main_path, "$x$")

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, main_path)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$" })
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local state = fresh_state()
  state.pid = 8300
  state.buffer_render_state[bufnr] = { runtime_preludes = {} }

  with_stubbed_uv(function(spawned)
    package.loaded["typst-concealer"] = {
      config = {
        use_formula_service = true,
        formula_worker_count = 2,
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
        math_baseline_pt = 11,
      },
      _styling_prelude = "",
    }

    state.machine_state.buffers[bufnr] = {
      bufnr = bufnr,
      project_scope_id = "project:self-check",
      buffer_version = tick,
      layout_version = 1,
      render_epoch = 1,
      context_id = "project:self-check",
      context_rev = 1,
      nodes = {
        ["node:self-check"] = {
          node_id = "node:self-check",
          slot_id = "slot:1",
          bufnr = bufnr,
          project_scope_id = "project:self-check",
          item_idx = 1,
          node_type = "math",
          source_range = { 0, 0, 0, 3 },
          display_range = { 0, 0, 0, 3 },
          source_text = "$x$",
          source_text_hash = "hash:x",
          node_rev = 1,
          context_hash = "ctx:1",
          prelude_count = 0,
          semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
          status = "pending",
          candidate_overlay_id = "overlay:lost",
        },
      },
      node_order = { "node:self-check" },
      slots = {
        ["slot:1"] = {
          slot_id = "slot:1",
          node_id = "node:self-check",
          page_index = 1,
          source_text = "$x$",
          source_text_hash = "hash:x",
          source_range = { 0, 0, 0, 3 },
          source_rows = 1,
          context_id = "project:self-check",
          context_rev = 1,
          context_hash = "ctx:1",
          prelude_count = 0,
          node_type = "math",
          semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
          display_range = { 0, 0, 0, 3 },
          candidate_overlay_id = "overlay:lost",
          pending_request_id = "formula:lost",
          status = "dirty",
          dirty = true,
        },
      },
      slot_order = { "slot:1" },
      next_slot_id = 2,
    }
    state.machine_state.overlays["overlay:lost"] = {
      overlay_id = "overlay:lost",
      slot_id = "slot:1",
      owner_node_id = "node:self-check",
      owner_bufnr = bufnr,
      owner_project_scope_id = "project:self-check",
      request_id = "formula:lost",
      page_index = 1,
      render_epoch = 1,
      node_rev = 1,
      context_id = "project:self-check",
      context_rev = 1,
      source_text_hash = "hash:x",
      buffer_version = tick,
      layout_version = 1,
      status = "rendering",
    }

    local manager = require("typst-concealer.formula.manager").get(bufnr)
    local missing = manager:ensure_pending_nodes_rendering({ node_ids = { "node:self-check" } })

    assert_eq(#missing, 1, "self-check should report the lost pending node")
    assert_eq(missing[1], "node:self-check", "self-check should keep scheduling node-local")
    assert_eq(state.machine_state.overlays["overlay:lost"], nil, "self-check should retire lost candidate overlay")
    assert_truthy(
      state.machine_state.buffers[bufnr].nodes["node:self-check"].candidate_overlay_id ~= nil,
      "self-check should install a replacement candidate"
    )
    assert_eq(#spawned[1].stdio[1].writes, 1, "self-check should start one replacement formula request")
    local msg = vim.json.decode(vim.trim(spawned[1].stdio[1].writes[1]))
    assert_eq(msg.type, "render_formulas", "self-check replacement should stay on formula transport")
    assert_eq(#msg.nodes, 1, "self-check replacement should render one node")
    assert_eq(msg.nodes[1].node_id, "node:self-check", "self-check should render the lost node")

    require("typst-concealer.session").stop_compiler_service(bufnr)
  end)

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

local function test_formula_service_stale_node_revision_is_discarded()
  make_service_response_harness("formula-stale-node-rev", { use_formula_service = true }, function(ctx)
    local page_path = vim.fn.tempname() .. ".png"
    write_file(page_path, "png")
    with_stubbed_extmark(function(calls)
      feed_service_response(ctx.full_stdout, {
        type = "formula_rendered",
        request_id = ctx.request.request_id,
        context_id = ctx.request.jobs[1].context_id,
        context_rev = ctx.request.jobs[1].context_rev,
        node_id = ctx.request.jobs[1].node_id,
        node_rev = ctx.request.jobs[1].node_rev + 1,
        status = "ok",
        path = page_path,
        width_px = 20,
        height_px = 10,
        diagnostics = {},
      })
      wait_until_service_request_cleared(ctx.state, ctx.bufnr)
      assert_eq(#calls.created, 0, "stale formula response should not upload an image")
    end)
    assert_eq(vim.uv.fs_stat(page_path), nil, "stale formula artifact should be cleaned")
    assert_eq(
      ctx.state.machine_state.overlays[ctx.request.jobs[1].overlay_id],
      nil,
      "stale formula response should retire the candidate overlay"
    )
  end)
end

local function test_formula_diagnostics_replace_per_node()
  make_service_response_harness(
    "formula-diagnostics-replace",
    { use_formula_service = true, do_diagnostics = true },
    function(ctx)
      local job = ctx.request.jobs[1]
      feed_service_response(ctx.full_stdout, {
        type = "formula_rendered",
        request_id = ctx.request.request_id,
        context_id = job.context_id,
        context_rev = job.context_rev,
        node_id = job.node_id,
        node_rev = job.node_rev,
        status = "error",
        diagnostics = {
          { line = 1, column = 1, severity = "error", message = "formula failed" },
        },
      })
      wait_until_service_request_cleared(ctx.state, ctx.bufnr)

      local bucket = ctx.state.render_diagnostics[ctx.bufnr]
      assert_eq(#bucket.full, 1, "formula diagnostic should be published in the aggregate full bucket")
      assert_eq(bucket.formula_by_node[job.node_id][1], bucket.full[1], "formula diagnostic should be stored by node")

      local second_request_id = "formula:diagnostics-clean"
      local second_overlay_id = "overlay:diagnostics-clean"
      local node = ctx.state.machine_state.buffers[ctx.bufnr].nodes[job.node_id]
      node.candidate_overlay_id = second_overlay_id
      node.status = "pending"
      ctx.state.machine_state.overlays[second_overlay_id] = {
        overlay_id = second_overlay_id,
        slot_id = job.slot_id,
        owner_node_id = job.node_id,
        owner_bufnr = ctx.bufnr,
        owner_project_scope_id = job.project_scope_id,
        request_id = second_request_id,
        page_index = 1,
        render_epoch = 2,
        node_rev = job.node_rev,
        context_id = job.context_id,
        context_rev = job.context_rev,
        source_text_hash = job.source_text_hash,
        buffer_version = job.buffer_version,
        layout_version = job.layout_version,
        status = "rendering",
      }

      local clean_job = vim.deepcopy(job)
      clean_job.overlay_id = second_overlay_id
      clean_job.request_id = second_request_id
      clean_job.render_epoch = 2
      clean_job.request_page_index = 1
      local clean_request = {
        request_id = second_request_id,
        bufnr = ctx.bufnr,
        project_scope_id = job.project_scope_id,
        render_epoch = 2,
        buffer_version = job.buffer_version,
        layout_version = job.layout_version,
        jobs = { clean_job },
      }
      ctx.session.render_formula_batch_via_service(ctx.bufnr, clean_request)

      local page_path = vim.fn.tempname() .. ".png"
      write_file(page_path, "png")
      with_stubbed_extmark(function()
        feed_service_response(ctx.full_stdout, {
          type = "formula_rendered",
          request_id = second_request_id,
          context_id = job.context_id,
          context_rev = job.context_rev,
          node_id = job.node_id,
          node_rev = job.node_rev,
          status = "ok",
          path = page_path,
          width_px = 20,
          height_px = 10,
          diagnostics = {},
        })
        wait_until_formula_batch_cleared(ctx.state, ctx.bufnr, second_request_id)
      end)

      bucket = ctx.state.render_diagnostics[ctx.bufnr]
      assert_eq(bucket.formula_by_node[job.node_id], nil, "clean formula response should clear that node's diagnostics")
      assert_eq(#bucket.full, 0, "clean formula response should remove stale aggregate diagnostics")

      bucket.formula_by_node[job.node_id] = {
        { filename = ctx.main_path, lnum = 1, col = 1, text = "[service/formula] stale", type = "E" },
      }
      require("typst-concealer.session")
      ctx.state.machine_state.buffers[ctx.bufnr].nodes[job.node_id] = nil
      ctx.session.render_formula_batch_via_service(ctx.bufnr, {
        request_id = "formula:diagnostics-delete",
        bufnr = ctx.bufnr,
        project_scope_id = job.project_scope_id,
        render_epoch = 3,
        buffer_version = job.buffer_version,
        layout_version = job.layout_version,
        jobs = {},
      })
      assert_eq(
        bucket.formula_by_node[job.node_id],
        nil,
        "formula batch scheduling should drop diagnostics for deleted nodes"
      )
    end
  )
end

function _G.test_service_error_diagnostics_clear_candidate_placeholder()
  make_service_response_harness("error-diagnostics-placeholder", { do_diagnostics = true }, function(ctx)
    with_stubbed_extmark(function(calls)
      feed_service_response(ctx.full_stdout, {
        type = "compile_result",
        request_id = ctx.request.request_id,
        status = "ok",
        pages = {},
        diagnostics = {
          { line = 1, column = 1, severity = "error", message = "unknown variable: mathbb" },
        },
        rendered_pages = 0,
      })
      wait_until_service_request_cleared(ctx.state, ctx.bufnr)

      assert_eq(ctx.state.active_service_requests[ctx.bufnr], nil, "error diagnostics should clear active meta")
      assert_eq(
        ctx.state.machine_state.overlays[ctx.request.jobs[1].overlay_id],
        nil,
        "error diagnostics should retire and GC the candidate placeholder"
      )
      assert_eq(#calls.created, 0, "error diagnostics should not upload a placeholder image")
      assert_truthy(
        ctx.state.render_diagnostics[ctx.bufnr].full[1].text:find("unknown variable: mathbb", 1, true) ~= nil,
        "error diagnostics should still be published"
      )
    end)
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

local function test_service_exit_cleans_active_request()
  make_service_response_harness("service-exit", {}, function(ctx)
    assert_truthy(ctx.spawned[1].on_exit ~= nil, "stubbed service should expose exit callback")
    ctx.spawned[1].on_exit(1, 0)
    vim.wait(100, function()
      return ctx.state.active_service_requests[ctx.bufnr] == nil
    end)
    assert_eq(ctx.state.active_service_requests[ctx.bufnr], nil, "service exit should clear active meta")
    assert_eq(
      ctx.state.machine_state.overlays[ctx.request.jobs[1].overlay_id],
      nil,
      "service exit should GC candidate overlay"
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
    local item = ctx.state.render_diagnostics[ctx.bufnr].full[1]
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
      local item = ctx.state.render_diagnostics[ctx.bufnr].full[1]
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
    local item = ctx.state.render_diagnostics[ctx.bufnr].full[1]
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
    local item = ctx.state.render_diagnostics[ctx.bufnr].full[1]
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
      ppi = 300,
      header = "",
      compiler_args = {},
      conceal_in_normal = false,
      cursor_hover_throttle_ms = 0,
    },
  }

  local preview_requests = {}
  package.loaded["typst-concealer.session"] = {
    render_preview_tail_via_service = function(_, item)
      preview_requests[#preview_requests + 1] = item
    end,
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

local function test_preview_cleanup_reattaches_only_source_item()
  local state = fresh_state()
  local apply = require("typst-concealer.apply")
  local runtime = require("typst-concealer.machine.runtime")
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$", "$y$" })

  local source_item = make_render_item({
    bufnr = bufnr,
    range = { 0, 0, 0, 3 },
    display_range = { 0, 0, 0, 3 },
    image_id = 101,
    extmark_id = 201,
    page_path = "/tmp/source-x.png",
    page_stamp = "source-x",
    natural_cols = 2,
    natural_rows = 1,
    source_rows = 1,
  })
  local other_item = make_render_item({
    bufnr = bufnr,
    item_idx = 2,
    range = { 1, 0, 1, 3 },
    display_range = { 1, 0, 1, 3 },
    str = "$y$",
    image_id = 102,
    extmark_id = 202,
    page_path = "/tmp/source-y.png",
    page_stamp = "source-y",
    natural_cols = 2,
    natural_rows = 1,
    source_rows = 1,
  })
  local preview_item = make_render_item({
    bufnr = bufnr,
    range = { 0, 0, 0, 3 },
    display_range = { 0, 0, 0, 3 },
    str = "$#text(red)[$x$]$",
    source_str = "$x$",
    image_id = 301,
    extmark_id = 401,
    page_path = "/tmp/preview-x.png",
    page_stamp = "preview-x",
    natural_cols = 3,
    natural_rows = 1,
    source_rows = 1,
    render_target = "preview_float",
    source_image_id = source_item.image_id,
  })

  state.buffer_render_state[bufnr] = {
    full_items = { source_item, other_item },
    lingering_items = {},
    line_to_items = {
      [0] = { source_item },
      [1] = { other_item },
    },
    extmark_to_item = {
      [source_item.extmark_id] = source_item,
      [other_item.extmark_id] = other_item,
    },
  }
  state.item_by_image_id[source_item.image_id] = source_item
  state.item_by_image_id[other_item.image_id] = other_item
  state.item_by_image_id[preview_item.image_id] = preview_item
  state.image_id_to_extmark[source_item.image_id] = source_item.extmark_id
  state.image_id_to_extmark[other_item.image_id] = other_item.extmark_id
  state.image_id_to_extmark[preview_item.image_id] = preview_item.extmark_id
  state.image_ids_in_use[source_item.image_id] = bufnr
  state.image_ids_in_use[other_item.image_id] = bufnr
  state.image_ids_in_use[preview_item.image_id] = bufnr

  local bs = state.get_buf_state(bufnr)
  bs.preview_image = {
    extmark_id = preview_item.extmark_id,
    target_bufnr = bufnr,
    natural_cols = preview_item.natural_cols,
    natural_rows = preview_item.natural_rows,
    image_id = preview_item.image_id,
  }
  bs.preview_item = preview_item
  bs.preview_last_rendered_item = preview_item
  bs.preview_source_image_id = source_item.image_id
  bs.preview_source_page_stamp = source_item.page_stamp
  bs.preview_source_range = vim.deepcopy(source_item.range)

  local invalidations = 0
  local old_invalidate = runtime.invalidate_terminal_uploads
  runtime.invalidate_terminal_uploads = function()
    invalidations = invalidations + 1
  end

  local ok_run, err = pcall(function()
    with_stubbed_extmark(function(calls)
      apply.cleanup_preview_image(bufnr)

      assert_eq(invalidations, 0, "preview cleanup should not invalidate the whole buffer")
      assert_eq(#calls.created, 1, "preview cleanup should re-upload only the source image")
      assert_eq(calls.created[1].image_id, source_item.image_id, "preview cleanup should reattach source node")
      assert_eq(#calls.concealed, 1, "preview cleanup should rewrite only the source placeholder")
      assert_eq(calls.concealed[1].image_id, source_item.image_id, "conceal repair should target source node")
      assert_eq(calls.flushed, 1, "targeted source reattach should flush once")
      assert_eq(state.item_by_image_id[other_item.image_id], other_item, "other rendered nodes should remain untouched")
    end)
  end)

  runtime.invalidate_terminal_uploads = old_invalidate
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

local function test_wrapper_defaults_missing_semantics_to_inline()
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
  local ok_run, prefix, suffix = pcall(wrapper.build_wrapper, {
    bufnr = 1,
    range = { 0, 0, 0, 0 },
    str = "[]",
  }, 1)

  assert_truthy(ok_run, "wrapper should tolerate internal items without semantics")
  assert_eq(prefix, "#context { let __it = [", "missing semantics should use inline wrapper prefix")
  assert_truthy(
    suffix:find("block(width: __d.width, height: __mh", 1, true) ~= nil,
    "missing semantics should use inline wrapper sizing"
  )
end

local function test_wrapper_imports_mitex_for_markdown_items()
  reset_modules()
  package.loaded["typst-concealer"] = {
    config = {
      header = "",
      mitex_package = "@preview/mitex:0.2.7",
      math_baseline_pt = 11,
      block_padding_cols = 15,
      block_preview_margin_pt = 6,
      ppi = 300,
    },
    _styling_prelude = "",
  }

  local wrapper = require("typst-concealer.wrapper")
  local doc = wrapper.build_batch_document({
    {
      bufnr = 1,
      item_idx = 1,
      range = { 0, 7, 0, 14 },
      str = '#mi("x + y")',
      prelude_count = 0,
      node_type = "math",
      semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" },
      requires_mitex = true,
    },
  }, nil, nil, nil, "full", {}, nil, false, {})

  assert_truthy(
    doc:find('#import "@preview/mitex:0.2.7": mitex, mi', 1, true) ~= nil,
    "markdown MiTeX items should import MiTeX"
  )
  assert_truthy(doc:find('#mi("x + y")', 1, true) ~= nil, "markdown inline render text should be included")
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
  assert_truthy(request, "full render should request service rendering")
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

local function test_machine_reducer_rebinds_when_reconciled_binding_disagrees_with_scan()
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

  overlay = state.overlays[overlay.overlay_id]
  overlay.binding_display_range = { 0, 99, 0, 0 }
  overlay.binding_buffer_version = 2
  overlay.binding_layout_version = 1

  state, effects = reducer.reduce(
    state,
    scan_event({ make_scanned_node() }, {
      buffer_version = 2,
    })
  )

  assert_eq(count_effects(effects, "request_full_render"), 0, "stale display binding should not recompile")
  local bind = first_effect(effects, "bind_overlay")
  assert_truthy(bind ~= nil, "reconciled binding mismatch should force a visible overlay rebind")
  assert_eq(bind.display_range[2], 0, "rebind should restore the scanned start column")
  assert_eq(bind.display_range[4], 3, "rebind should restore the scanned end column")
  assert_eq(bind.overlay_id, overlay.overlay_id, "rebind should target the visible overlay identity")
end

local function test_machine_reducer_rebinds_when_dirty_range_hits_old_binding_after_shift()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        source_range = { 10, 0, 12, 1 },
        display_range = { 10, 0, 12, 1 },
        semantics = { display_kind = "block", constraint_kind = "intrinsic", render_whole_line = false },
      }),
    })
  )
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
    binding_display_range = { 10, 0, 12, 1 },
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
    scan_event({
      make_scanned_node({
        source_range = { 20, 0, 22, 1 },
        display_range = { 20, 0, 22, 1 },
        semantics = { display_kind = "block", constraint_kind = "intrinsic", render_whole_line = false },
      }),
    }, {
      buffer_version = 2,
      binding_dirty_ranges = {
        { 10, 0, 12, 1 },
      },
    })
  )

  assert_eq(count_effects(effects, "request_full_render"), 0, "pure position shifts should not require rerender")
  local bind = first_effect(effects, "bind_overlay")
  assert_truthy(bind ~= nil, "dirty old binding range should force a visible overlay rebind after shift")
  assert_eq(bind.display_range[1], 20, "rebind should target the new display range")
  assert_eq(bind.overlay_id, overlay.overlay_id, "rebind should keep the same visible overlay identity")
end

local function test_machine_reducer_rebinds_visible_overlay_after_shift_even_if_binding_was_reconciled()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        source_range = { 10, 0, 12, 1 },
        display_range = { 10, 0, 12, 1 },
        semantics = { display_kind = "block", constraint_kind = "intrinsic", render_whole_line = false },
      }),
    })
  )
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
    binding_display_range = { 10, 0, 12, 1 },
  })
  overlay = state.overlays[overlay.overlay_id]
  state = reducer.reduce(state, page_ready_event(overlay))
  state = reducer.reduce(state, {
    type = "overlay_commit_succeeded",
    overlay_id = overlay.overlay_id,
    node_id = overlay.owner_node_id,
  })

  overlay = state.overlays[overlay.overlay_id]
  overlay.binding_display_range = { 20, 0, 22, 1 }
  overlay.binding_buffer_version = 2
  overlay.binding_layout_version = 1

  state, effects = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        source_range = { 20, 0, 22, 1 },
        display_range = { 20, 0, 22, 1 },
        semantics = { display_kind = "block", constraint_kind = "intrinsic", render_whole_line = false },
      }),
    }, {
      buffer_version = 2,
    })
  )

  local bind = first_effect(effects, "bind_overlay")
  assert_truthy(
    bind ~= nil,
    "a visible overlay that shifted must still rebind even if reconcile already updated binding metadata"
  )
  assert_eq(bind.display_range[1], 20, "rebind should target the shifted display range")
  assert_eq(bind.overlay_id, overlay.overlay_id, "rebind should keep the same visible overlay identity")
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
  assert_eq(state.buffers[1].nodes[first_id], nil, "deleted formula without visible overlay is purged from state")
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

local function test_machine_reducer_identity_repeated_identical_formulas_shift_down_together()
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
        source_range = { 10, 0, 10, 3 },
        display_range = { 10, 0, 10, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
      }),
      make_scanned_node({
        stable_key = nil,
        item_idx = 2,
        source_range = { 11, 0, 11, 3 },
        display_range = { 11, 0, 11, 3 },
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
        source_range = { 11, 0, 11, 3 },
        display_range = { 11, 0, 11, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
      }),
      make_scanned_node({
        stable_key = nil,
        item_idx = 2,
        source_range = { 12, 0, 12, 3 },
        display_range = { 12, 0, 12, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
      }),
    }, { buffer_version = 2 })
  )

  assert_eq(
    state.buffers[1].node_order[1],
    first_id,
    "first repeated formula should keep identity when the repeated run shifts down together"
  )
  assert_eq(
    state.buffers[1].node_order[2],
    second_id,
    "second repeated formula should keep identity when the repeated run shifts down together"
  )
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

local function test_machine_reducer_formula_batch_keeps_node_request_state_independent()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state, effects = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({ stable_key = "a", source_text = "$a$", source_text_hash = "hash:a" }),
      make_scanned_node({
        stable_key = "b",
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
    })
  )
  assert_eq(#effects, 0, "scan should only reconcile nodes")

  state, effects = reducer.reduce(state, { type = "formula_renders_requested", bufnr = 1 })
  local request = first_effect(effects, "request_formula_render_batch")
  assert_truthy(request, "formula render should use formula batch effect")
  assert_eq(#request.request.jobs, 2, "formula batch should include both dirty nodes")
  assert_eq(state.buffers[1].active_request_id, nil, "formula batch should not become buffer active request")

  local first_job = request.request.jobs[1]
  local second_job = request.request.jobs[2]
  state, effects = reducer.reduce(state, {
    type = "overlay_render_failed",
    request_id = request.request.request_id,
    overlay_id = first_job.overlay_id,
    node_rev = first_job.node_rev,
    context_id = first_job.context_id,
    context_rev = first_job.context_rev,
    reason = "failed first formula",
  })

  assert_eq(
    state.overlays[second_job.overlay_id].status,
    "placeholder",
    "failed first formula should not touch the second formula candidate"
  )
  assert_eq(
    state.buffers[1].nodes[second_job.node_id].candidate_overlay_id,
    second_job.overlay_id,
    "second formula should keep its pending candidate"
  )
  assert_eq(count_effects(effects, "retire_overlay"), 1, "only failed formula candidate should retire")
end

local function test_machine_reducer_formula_batch_respects_requested_node_order()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state, effects = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({ stable_key = "a", source_text = "$a$", source_text_hash = "hash:a" }),
      make_scanned_node({
        stable_key = "b",
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
      make_scanned_node({
        stable_key = "c",
        item_idx = 3,
        source_range = { 2, 0, 2, 3 },
        display_range = { 2, 0, 2, 3 },
        source_text = "$c$",
        source_text_hash = "hash:c",
      }),
    })
  )

  local node_a = state.buffers[1].node_order[1]
  local node_c = state.buffers[1].node_order[3]
  state, effects = reducer.reduce(state, {
    type = "formula_renders_requested",
    bufnr = 1,
    node_ids = { node_c, node_a },
  })

  local request = first_effect(effects, "request_formula_render_batch")
  assert_truthy(request, "requested formula nodes should produce a formula batch")
  assert_eq(#request.request.jobs, 2, "formula batch should include only requested nodes")
  assert_eq(request.request.jobs[1].node_id, node_c, "requested order should prioritize near-viewport node")
  assert_eq(request.request.jobs[2].node_id, node_a, "requested order should be preserved for remaining nodes")
end

local function test_formula_manager_render_queue_uses_coverage_priority()
  local state = fresh_state()
  local reducer = require("typst-concealer.machine.reducer")

  state.machine_state = reducer.reduce(
    state.machine_state,
    scan_event({
      make_scanned_node({
        stable_key = "hidden",
        source_text = "$hidden$",
        source_text_hash = "hash:hidden",
        render_in_coverage = false,
        render_priority = 0,
      }),
      make_scanned_node({
        stable_key = "far",
        item_idx = 2,
        source_range = { 20, 0, 20, 5 },
        display_range = { 20, 0, 20, 5 },
        source_text = "$far$",
        source_text_hash = "hash:far",
        render_in_coverage = true,
        render_priority = 20,
      }),
      make_scanned_node({
        stable_key = "near",
        item_idx = 3,
        source_range = { 2, 0, 2, 6 },
        display_range = { 2, 0, 2, 6 },
        source_text = "$near$",
        source_text_hash = "hash:near",
        render_in_coverage = true,
        render_priority = 0,
      }),
    })
  )

  local manager = require("typst-concealer.formula.manager").get(1)
  local node_ids = manager:render_queue_node_ids()
  local buf = state.machine_state.buffers[1]

  assert_eq(#node_ids, 2, "render queue should exclude nodes outside current coverage")
  assert_eq(buf.nodes[node_ids[1]].stable_key, "near", "nearest covered node should render first")
  assert_eq(buf.nodes[node_ids[2]].stable_key, "far", "farther covered node should render later")
end

local function test_machine_reducer_scan_retires_cleared_formula_candidates()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state, effects = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({ stable_key = "a", source_text = "$a$", source_text_hash = "hash:a" }),
      make_scanned_node({
        stable_key = "b",
        item_idx = 2,
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$b$",
        source_text_hash = "hash:b",
      }),
    })
  )
  state, effects = reducer.reduce(state, { type = "formula_renders_requested", bufnr = 1 })
  local request = first_effect(effects, "request_formula_render_batch")
  assert_truthy(request, "initial formula render should create pending candidates")
  local edited_job = request.request.jobs[1]
  local removed_job = request.request.jobs[2]

  state, effects = reducer.reduce(
    state,
    scan_event({
      make_scanned_node({
        stable_key = "a",
        source_text = "$aa$",
        source_text_hash = "hash:aa",
      }),
    }, { buffer_version = 2 })
  )

  assert_eq(
    count_effects(effects, "retire_overlay"),
    2,
    "scan should retire candidates cleared by edited and removed formulas"
  )
  assert_eq(
    state.overlays[edited_job.overlay_id].status,
    "retiring",
    "edited formula's in-flight candidate should be retiring"
  )
  assert_eq(
    state.overlays[removed_job.overlay_id].status,
    "retiring",
    "removed formula's in-flight candidate should be retiring"
  )
  assert_eq(
    state.buffers[1].nodes[edited_job.node_id].candidate_overlay_id,
    nil,
    "edited node should no longer point at the stale candidate"
  )
  assert_eq(
    state.buffers[1].nodes[removed_job.node_id],
    nil,
    "removed node without visible overlay should be dropped after its candidate is retired"
  )
end

local function test_machine_reducer_keeps_identical_pending_formula_candidate()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  local effects
  state, effects = reducer.reduce(state, scan_event({ make_scanned_node({ stable_key = "a" }) }))
  state, effects = reducer.reduce(state, { type = "formula_renders_requested", bufnr = 1 })
  local request = first_effect(effects, "request_formula_render_batch")
  assert_truthy(request, "initial formula render should create a candidate")
  local job = request.request.jobs[1]
  local first_render_epoch = state.buffers[1].render_epoch

  state, effects =
    reducer.reduce(state, scan_event({ make_scanned_node({ stable_key = "a" }) }, { buffer_version = 2 }))
  assert_eq(
    state.buffers[1].nodes[job.node_id].candidate_overlay_id,
    job.overlay_id,
    "unchanged pending scan should keep the in-flight candidate"
  )
  assert_eq(
    state.overlays[job.overlay_id].status,
    "placeholder",
    "unchanged pending scan should not retire the in-flight candidate"
  )

  state, effects = reducer.reduce(state, { type = "formula_renders_requested", bufnr = 1 })
  assert_eq(
    count_effects(effects, "request_formula_render_batch"),
    0,
    "identical pending formula should not schedule a duplicate render"
  )
  assert_eq(count_effects(effects, "retire_overlay"), 0, "identical pending formula should not supersede the candidate")
  assert_eq(state.buffers[1].render_epoch, first_render_epoch, "skipping duplicate render should not bump render epoch")
end

local function test_machine_reducer_flow_nodes_rerender_when_layout_changes()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")
  local flow_node = make_scanned_node({
    stable_key = "flow",
    node_type = "code",
    source_range = { 0, 0, 1, 0 },
    display_range = { 0, 0, 1, 0 },
    source_text = "#rect(width: 100%)",
    source_text_hash = "hash:flow",
    semantics = { display_kind = "block", constraint_kind = "flow" },
  })

  local state = types.initial_state()
  local effects
  state, effects = reducer.reduce(state, scan_event({ flow_node }, { layout_version = 80 }))
  state, effects = reducer.reduce(state, { type = "formula_renders_requested", bufnr = 1 })
  local request = first_effect(effects, "request_formula_render_batch")
  assert_truthy(request, "initial flow node render should create a candidate")
  state = commit_overlay_jobs(reducer, state, request)
  local visible_overlay_id = state.buffers[1].nodes[request.request.jobs[1].node_id].visible_overlay_id

  state, effects = reducer.reduce(state, scan_event({ flow_node }, { layout_version = 100 }))
  assert_eq(
    state.buffers[1].nodes[request.request.jobs[1].node_id].status,
    "stale",
    "flow node should become stale when columns change"
  )
  assert_eq(
    state.overlays[visible_overlay_id].status,
    "visible",
    "layout-sensitive rerender should keep the old image visible until replacement commits"
  )

  state, effects = reducer.reduce(state, { type = "formula_renders_requested", bufnr = 1 })
  assert_eq(
    count_effects(effects, "request_formula_render_batch"),
    1,
    "flow node should schedule a formula rerender after columns change"
  )
end

local function test_machine_reducer_layout_change_rebinds_without_formula_rerender()
  reset_modules()
  local types = require("typst-concealer.machine.types")
  local reducer = require("typst-concealer.machine.reducer")

  local state = types.initial_state()
  state.buffers[1] = {
    bufnr = 1,
    project_scope_id = "project:1",
    buffer_version = 1,
    layout_version = 80,
    render_epoch = 1,
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
        node_rev = 1,
        context_hash = "ctx:0",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        status = "stable",
        visible_overlay_id = "overlay:1",
      },
    },
    node_order = { "node:1" },
  }
  state.overlays["overlay:1"] = {
    overlay_id = "overlay:1",
    owner_node_id = "node:1",
    owner_bufnr = 1,
    owner_project_scope_id = "project:1",
    request_id = "formula:1",
    status = "visible",
    image_id = 10,
    extmark_id = 20,
    page_path = "/tmp/formula.png",
    natural_cols = 2,
    natural_rows = 1,
  }

  local effects
  state, effects = reducer.reduce(state, { type = "buffer_layout_changed", bufnr = 1, new_layout_version = 100 })
  assert_eq(count_effects(effects, "rerender_buffer"), 0, "layout change should not request buffer rerender")
  assert_eq(
    count_effects(effects, "request_formula_render_batch"),
    0,
    "layout change should not request formula render"
  )
  assert_eq(count_effects(effects, "bind_overlay"), 1, "layout change should rebind visible placement")
  assert_eq(state.buffers[1].nodes["node:1"].status, "stable", "layout change should keep formula clean")
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

local function test_machine_runtime_rebinds_overlay_without_terminal_image_refresh()
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

    assert_eq(#calls.cleared, 0, "rebind should keep the existing terminal image")
    assert_eq(#calls.created, 0, "rebind should not re-upload the terminal image")
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

local function test_extmark_collapses_wrapping_single_line_block_source()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  vim.o.columns = 40
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  local line = "$$\\frac{1}{2}\\Delta |\\nabla f|^2 = |\\nabla^2 f|^2 + \\operatorname{Ric}(\\nabla f,\\nabla f).$$"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line, "after" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local extmark = require("typst-concealer.extmark")
  local image_id = 1302
  local range = { 0, 0, 0, #line }
  local semantics = { display_kind = "block", constraint_kind = "intrinsic", source_kind = "math" }
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
  local item = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = range,
    display_range = range,
    node_type = "math",
    semantics = semantics,
  }
  state.image_id_to_extmark[image_id] = extmark_id
  state.item_by_image_id[image_id] = item

  extmark.conceal_for_image_id(bufnr, image_id, 30, 2, 1)

  local bs = state.get_buf_state(bufnr)
  local mm = bs.multiline_marks[extmark_id]
  assert_truthy(mm ~= nil and mm.is_block_carrier == true, "single-line block math should use block carrier")
  local carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, mm.carrier_id, { details = true })
  assert_eq(carrier[3].virt_text, nil, "single-line block math should not place image rows on source text")
  assert_eq(#(carrier[3].virt_lines or {}), 2, "single-line block math should render all rows as virtual lines")
  assert_eq(carrier[3].virt_lines_above, true, "single-line block math should render above the collapsed source line")
  assert_eq(#(mm.tail_ids or {}), 1, "single-line block math should collapse the wrapped source line")
  local line_conceal = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, mm.tail_ids[1], { details = true })
  assert_eq(line_conceal[3].conceal_lines, "", "single-line block source should be hidden with conceal_lines")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_scales_wide_block_images_to_window_width()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  local line = "$$\\Delta |\\nabla f|^2 = |\\nabla^2 f|^2 + Ric(\\nabla f,\\nabla f).$$"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line, "after" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local extmark = require("typst-concealer.extmark")
  local image_id = 1304
  local range = { 0, 0, 0, #line }
  local semantics = { display_kind = "block", constraint_kind = "intrinsic", source_kind = "math" }
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
  local item = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = range,
    display_range = range,
    node_type = "math",
    semantics = semantics,
  }
  state.image_id_to_extmark[image_id] = extmark_id
  state.item_by_image_id[image_id] = item

  local win_cols = vim.api.nvim_win_get_width(0)
  local natural_cols = win_cols + 30
  local natural_rows = 4
  local expected_rows = math.max(1, math.ceil(natural_rows * win_cols / natural_cols))

  extmark.create_image("/tmp/typst-concealer-wide-block.png", image_id, natural_cols, natural_rows)
  extmark.conceal_for_image_id(bufnr, image_id, natural_cols, natural_rows, 1)

  assert_eq(item.display_cols, win_cols, "wide block image should be placed at window width")
  assert_eq(item.display_rows, expected_rows, "wide block image rows should be scaled with width")

  local bs = state.get_buf_state(bufnr)
  local mm = bs.multiline_marks[extmark_id]
  local carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, mm.carrier_id, { details = true })
  local first_line = carrier[3].virt_lines and carrier[3].virt_lines[1] or {}
  local image_chunk = first_line[#first_line] and first_line[#first_line][1] or ""
  assert_eq(vim.fn.strdisplaywidth(image_chunk), win_cols, "wide block placeholder row should not exceed window width")

  extmark.flush_terminal_data()
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_multiline_block_uses_line_run_lifecycle()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "before", "$", "  x", "$", "after" })
  vim.api.nvim_win_set_cursor(0, { 5, 0 })

  local extmark = require("typst-concealer.extmark")
  local image_id = 1308
  local range = { 1, 0, 3, 1 }
  local semantics = { display_kind = "block", constraint_kind = "intrinsic", source_kind = "math" }
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
  state.item_by_image_id[image_id] = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = range,
    display_range = range,
    node_type = "math",
    semantics = semantics,
    natural_cols = 6,
    natural_rows = 2,
  }

  extmark.conceal_for_image_id(bufnr, image_id, 6, 2, 3)

  local bs = state.get_buf_state(bufnr)
  local mm = bs.multiline_marks[extmark_id]
  assert_truthy(mm ~= nil and mm.is_block_carrier == true, "multiline block should keep block metadata")
  assert_truthy(mm.line_run_id ~= nil, "multiline block should be owned by a line run")
  local run_id = mm.line_run_id
  local run = bs.line_run_marks[run_id]
  assert_eq(run.start_row, 1, "multiline block run should cover the first source row")
  assert_eq(run.end_row, 3, "multiline block run should cover the last source row")
  assert_eq(#mm.tail_ids, 3, "multiline block run should own conceal extmarks for every source row")

  local carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, mm.carrier_id, { details = true })
  assert_eq(carrier[1], 0, "multiline block run should anchor outside its source rows")
  assert_eq(carrier[3].virt_lines_above, false, "multiline block run should render after the previous safe row")
  assert_eq(#(carrier[3].virt_lines or {}), 2, "multiline block run should render image rows as virtual lines")
  for _, conceal_id in ipairs(mm.tail_ids) do
    local conceal = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, conceal_id, { details = true })
    assert_eq(conceal[3].conceal_lines, "", "multiline block source rows should collapse via line run")
  end

  state.prepare_extmark_reuse(bufnr, extmark_id)
  assert_eq(bs.line_run_marks[run_id], nil, "prepare_extmark_reuse should clear the multiline block line run")
  assert_eq(bs.multiline_marks[extmark_id], nil, "prepare_extmark_reuse should clear multiline block metadata")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_nonblock_multiline_uses_line_run_lifecycle()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "abc", "def", "ghi", "after" })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })

  local extmark = require("typst-concealer.extmark")
  local image_id = 1309
  local range = { 0, 0, 2, 3 }
  local semantics = { display_kind = "inline", constraint_kind = "flow", source_kind = "code" }
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
  state.item_by_image_id[image_id] = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = range,
    display_range = range,
    node_type = "code",
    semantics = semantics,
    natural_cols = 2,
    natural_rows = 2,
  }

  extmark.conceal_for_image_id(bufnr, image_id, 2, 2, 3)

  local bs = state.get_buf_state(bufnr)
  local mm = bs.multiline_marks[extmark_id]
  assert_truthy(mm ~= nil and mm.is_multiline_overlay == true, "non-block multiline should use overlay run metadata")
  assert_truthy(mm.line_run_id ~= nil, "non-block multiline should be owned by a line run")
  local run_id = mm.line_run_id
  local run = bs.line_run_marks[run_id]
  assert_eq(run.mode, "row_overlay", "non-block multiline should keep per-source-row overlay semantics")
  assert_eq(run.start_row, 0, "non-block multiline run should track the first source row")
  assert_eq(run.end_row, 2, "non-block multiline run should track the last source row")
  assert_eq(#run.sub_ids, 3, "non-block multiline run should own all row overlay extmarks")

  local first_overlay = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, run.sub_ids[1], { details = true })
  assert_truthy(first_overlay[3].virt_text ~= nil, "row-overlay run should render with virt_text")
  assert_eq(first_overlay[3].conceal, "", "row-overlay run should keep source rows visible but concealed")
  assert_eq(first_overlay[3].conceal_lines, nil, "row-overlay run should not collapse source rows")

  assert_eq(extmark.unconceal_extmark(bufnr, extmark_id), true, "unconceal should clear non-block multiline run")
  assert_eq(bs.line_run_marks[run_id], nil, "unconceal should remove the non-block multiline line run")
  assert_eq(
    #vim.api.nvim_buf_get_extmarks(bufnr, state.ns_id2, { 0, 0 }, { -1, -1 }, {}),
    0,
    "unconceal should delete all row-overlay extmarks"
  )

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_line_run_progressively_expands_active_block()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "A $a$",
    "$ b $",
    "C $c$",
    "after",
  })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })

  local extmark = require("typst-concealer.extmark")
  local inline_semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" }
  local block_semantics = { display_kind = "block", constraint_kind = "intrinsic", source_kind = "math" }

  local first_id = 1310
  local first_range = { 0, 2, 0, 5 }
  local first_extmark = extmark.place_render_extmark(bufnr, first_id, first_range, nil, true, inline_semantics)
  state.item_by_image_id[first_id] = {
    bufnr = bufnr,
    image_id = first_id,
    extmark_id = first_extmark,
    range = first_range,
    display_range = first_range,
    node_type = "math",
    semantics = inline_semantics,
    natural_cols = 1,
    natural_rows = 1,
  }

  local block_id = 1311
  local block_range = { 1, 0, 1, 5 }
  local block_extmark = extmark.place_render_extmark(bufnr, block_id, block_range, nil, true, block_semantics)
  state.item_by_image_id[block_id] = {
    bufnr = bufnr,
    image_id = block_id,
    extmark_id = block_extmark,
    range = block_range,
    display_range = block_range,
    node_type = "math",
    semantics = block_semantics,
    natural_cols = 2,
    natural_rows = 1,
  }

  local last_id = 1312
  local last_range = { 2, 2, 2, 5 }
  local last_extmark = extmark.place_render_extmark(bufnr, last_id, last_range, nil, true, inline_semantics)
  state.item_by_image_id[last_id] = {
    bufnr = bufnr,
    image_id = last_id,
    extmark_id = last_extmark,
    range = last_range,
    display_range = last_range,
    node_type = "math",
    semantics = inline_semantics,
    natural_cols = 1,
    natural_rows = 1,
  }

  extmark.conceal_for_image_id(bufnr, first_id, 1, 1, 1)
  extmark.conceal_for_image_id(bufnr, block_id, 2, 1, 1)
  extmark.conceal_for_image_id(bufnr, last_id, 1, 1, 1)

  local bs = state.get_buf_state(bufnr)
  local block_mm = bs.multiline_marks[block_extmark]
  assert_truthy(block_mm ~= nil and block_mm.line_run_id ~= nil, "block should join the initial collapsed run")
  assert_eq(
    bs.inline_line_marks[0].line_run_id,
    block_mm.line_run_id,
    "prefix inline row should share the initial collapsed run"
  )
  assert_eq(
    bs.inline_line_marks[2].line_run_id,
    block_mm.line_run_id,
    "suffix inline row should share the initial collapsed run"
  )

  assert_eq(extmark.unconceal_extmark(bufnr, block_extmark), true, "active block should expand")
  assert_eq(block_mm.line_run_id, nil, "active block should leave the collapsed run")
  assert_eq(block_mm.line_run_display_lines, nil, "active block display lines should be suppressed while expanded")
  assert_eq(bs.line_run_by_row[1], nil, "active block source row should not be concealed by a line run")

  local prefix = bs.inline_line_marks[0]
  local suffix = bs.inline_line_marks[2]
  assert_truthy(prefix ~= nil, "rows above the active block should remain collapsed")
  assert_truthy(suffix ~= nil, "rows below the active block should remain collapsed")
  assert_truthy(prefix.line_run_id ~= suffix.line_run_id, "prefix and suffix should become separate runs")

  local prefix_carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, prefix.carrier_id, { details = true })
  assert_eq(prefix_carrier[1], 1, "prefix run should anchor on the active row when no safe row exists above")
  assert_eq(prefix_carrier[3].virt_lines_above, true, "prefix run should render above the active row")

  local suffix_carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, suffix.carrier_id, { details = true })
  assert_eq(suffix_carrier[1], 3, "suffix run should use the following safe row when one exists")
  assert_eq(suffix_carrier[3].virt_lines_above, true, "suffix run should render before the following safe row")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_line_run_clear_invalidates_hover_guard()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "before", "$", "  x", "$", "after" })
  vim.api.nvim_win_set_cursor(0, { 5, 0 })

  local runtime = require("typst-concealer.machine.runtime")
  local extmark = require("typst-concealer.extmark")
  local image_id = 1313
  local range = { 1, 0, 3, 1 }
  local semantics = { display_kind = "block", constraint_kind = "intrinsic", source_kind = "math" }
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
  state.item_by_image_id[image_id] = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = range,
    display_range = range,
    node_type = "math",
    semantics = semantics,
    natural_cols = 6,
    natural_rows = 2,
  }

  extmark.conceal_for_image_id(bufnr, image_id, 6, 2, 3)

  local bs = state.get_buf_state(bufnr)
  local mm = bs.multiline_marks[extmark_id]
  assert_truthy(mm ~= nil and mm.line_run_id ~= nil, "block should be owned by a line run before clear")

  local hover = runtime.get_ui_buffer(bufnr).hover
  hover.invalidated = false
  assert_eq(extmark.unconceal_extmark(bufnr, extmark_id), true, "unconceal should clear the line run")
  assert_eq(hover.invalidated, true, "clearing a line run should force the next cursor UI sync")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_state_prepare_extmark_reuse_invalidates_hover_guard_for_line_run()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "before", "$", "  y", "$", "after" })
  vim.api.nvim_win_set_cursor(0, { 5, 0 })

  local runtime = require("typst-concealer.machine.runtime")
  local extmark = require("typst-concealer.extmark")
  local image_id = 1314
  local range = { 1, 0, 3, 1 }
  local semantics = { display_kind = "block", constraint_kind = "intrinsic", source_kind = "math" }
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
  state.item_by_image_id[image_id] = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = range,
    display_range = range,
    node_type = "math",
    semantics = semantics,
    natural_cols = 6,
    natural_rows = 2,
  }

  extmark.conceal_for_image_id(bufnr, image_id, 6, 2, 3)

  local bs = state.get_buf_state(bufnr)
  local mm = bs.multiline_marks[extmark_id]
  assert_truthy(mm ~= nil and mm.line_run_id ~= nil, "block should be owned by a line run before reuse")

  local hover = runtime.get_ui_buffer(bufnr).hover
  hover.invalidated = false
  state.prepare_extmark_reuse(bufnr, extmark_id)
  assert_eq(hover.invalidated, true, "prepare_extmark_reuse should force the next cursor UI sync")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_resync_repairs_restored_block_with_occupied_boundary_anchors()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "previous render item",
    "",
    "$",
    "  x",
    "$",
    "$",
    "  y",
    "$",
    "",
    "next render item",
  })

  local extmark = require("typst-concealer.extmark")
  local semantics = { display_kind = "block", constraint_kind = "intrinsic", source_kind = "math" }

  local function bind_block(image_id, range)
    local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
    state.item_by_image_id[image_id] = {
      bufnr = bufnr,
      image_id = image_id,
      extmark_id = extmark_id,
      range = range,
      display_range = range,
      node_type = "math",
      semantics = semantics,
      natural_cols = 4,
      natural_rows = 1,
      source_rows = range[3] - range[1] + 1,
    }
    extmark.conceal_for_image_id(bufnr, image_id, 4, 1, range[3] - range[1] + 1)
    return extmark_id
  end

  local first_extmark = bind_block(1315, { 2, 0, 4, 1 })
  local second_extmark = bind_block(1316, { 5, 0, 7, 1 })
  local bs = state.get_buf_state(bufnr)
  assert_truthy(bs.multiline_marks[first_extmark].line_run_id ~= nil, "first block should start collapsed")
  assert_truthy(bs.multiline_marks[second_extmark].line_run_id ~= nil, "second block should start collapsed")

  vim.api.nvim_buf_set_extmark(bufnr, state.ns_id2, 1, 0, { virt_lines = { { { "occupied previous anchor", "" } } } })
  vim.api.nvim_buf_set_extmark(bufnr, state.ns_id2, 8, 0, { virt_lines = { { { "occupied next anchor", "" } } } })
  state.item_by_image_id[91315] = {
    bufnr = bufnr,
    image_id = 91315,
    range = { 0, 0, 0, 1 },
    display_range = { 0, 0, 0, 1 },
    semantics = { display_kind = "inline" },
  }
  state.item_by_image_id[91316] = {
    bufnr = bufnr,
    image_id = 91316,
    range = { 9, 0, 9, 1 },
    display_range = { 9, 0, 9, 1 },
    semantics = { display_kind = "inline" },
  }

  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  assert_eq(extmark.unconceal_extmark(bufnr, first_extmark), true, "first block should expand under cursor")
  bs.currently_hidden_extmark_ids[first_extmark] = true
  assert_truthy(bs.multiline_marks[second_extmark].line_run_id ~= nil, "second block should stay collapsed")

  vim.api.nvim_win_set_cursor(0, { 6, 0 })
  extmark.reconcile_cursor_line_runs(bufnr, 5, 5)
  bs.currently_hidden_extmark_ids[first_extmark] = nil
  extmark.conceal_for_image_id(bufnr, 1315, 4, 1, 3)
  assert_eq(
    bs.multiline_marks[first_extmark].line_run_id,
    nil,
    "restoring without cursor anchor context should still reproduce the missing line-run state"
  )

  assert_eq(extmark.unconceal_extmark(bufnr, second_extmark), true, "second block should expand under cursor")
  bs.currently_hidden_extmark_ids[second_extmark] = true
  extmark.reconcile_cursor_line_runs(bufnr, 5, 5)

  local restored = bs.multiline_marks[first_extmark]
  assert_truthy(restored.line_run_id ~= nil, "final cursor resync should restore the first block line-run")
  assert_eq(bs.line_run_by_row[2], restored.line_run_id, "first block start row should be collapsed again")
  assert_eq(bs.line_run_by_row[3], restored.line_run_id, "first block middle row should be collapsed again")
  assert_eq(bs.line_run_by_row[4], restored.line_run_id, "first block end row should be collapsed again")
  assert_eq(bs.line_run_by_row[5], nil, "active second block row should remain expanded")

  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  bs.currently_hidden_extmark_ids[second_extmark] = nil
  extmark.conceal_for_image_id(bufnr, 1316, 4, 1, 3, { defer_line_run_reconcile = true })
  assert_eq(
    bs.multiline_marks[second_extmark].line_run_id,
    nil,
    "restoring the lower block should defer line-run creation to the cursor scheduler"
  )
  extmark.reconcile_cursor_line_runs(bufnr, 1, 1)

  local merged_run_id = bs.multiline_marks[first_extmark].line_run_id
  assert_truthy(merged_run_id ~= nil, "moving above the block cluster should restore the upper block")
  assert_eq(
    bs.multiline_marks[second_extmark].line_run_id,
    merged_run_id,
    "moving above the block cluster should merge the lower block back into the run"
  )
  assert_eq(bs.line_run_by_row[2], merged_run_id, "upper block start row should be collapsed after upward move")
  assert_eq(bs.line_run_by_row[7], merged_run_id, "lower block end row should be collapsed after upward move")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function virt_line_text(line)
  local parts = {}
  for _, chunk in ipairs(line or {}) do
    parts[#parts + 1] = chunk[1] or ""
  end
  return table.concat(parts)
end

local function hl_index(hl_group, expected)
  if hl_group == expected then
    return 1
  end
  if type(hl_group) ~= "table" then
    return nil
  end
  for idx, group in ipairs(hl_group) do
    if group == expected then
      return idx
    end
  end
end

local function assert_hl_contains(hl_group, expected, msg)
  assert_truthy(hl_index(hl_group, expected) ~= nil, msg .. "\nhl_group: " .. vim.inspect(hl_group))
end

local function test_extmark_embedded_block_math_uses_display_composer()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local old_conceallevel = vim.o.conceallevel
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  local line = "pre abc $ sin(alpha) $ tail"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "before", line, "after" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.cmd("syntax on")
  vim.cmd("syntax match TypstConcealerBlockComposerWord /abc/ conceal cchar=X")
  vim.api.nvim_set_hl(0, "TypstConcealerBlockComposerWord", { fg = "#00ff00" })
  vim.o.conceallevel = 2

  local tail_start = line:find("tail", 1, true) - 1
  local hl_ns = vim.api.nvim_create_namespace("typst-concealer-block-composer-test")
  vim.api.nvim_buf_set_extmark(bufnr, hl_ns, 1, tail_start, {
    end_col = tail_start + #"tail",
    hl_group = "String",
  })

  local extmark = require("typst-concealer.extmark")
  local image_id = 1305
  local math_start, math_end = line:find("$ sin(alpha) $", 1, true)
  local source_range = { 1, math_start - 1, 1, math_end }
  local display_range = { 1, 0, 1, #line }
  local semantics = {
    display_kind = "block",
    constraint_kind = "intrinsic",
    source_kind = "math",
    render_whole_line = true,
  }
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, display_range, nil, true, semantics)
  local item = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = source_range,
    display_range = display_range,
    display_prefix = "pre abc",
    display_suffix = "tail",
    node_type = "math",
    semantics = semantics,
  }
  state.image_id_to_extmark[image_id] = extmark_id
  state.item_by_image_id[image_id] = item

  extmark.conceal_for_image_id(bufnr, image_id, 8, 1, 1)

  local mm = state.get_buf_state(bufnr).multiline_marks[extmark_id]
  assert_truthy(mm ~= nil and mm.is_block_carrier == true, "embedded block math should use a block carrier")
  local carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, mm.carrier_id, { details = true })
  local virt_lines = carrier[3].virt_lines or {}
  assert_eq(carrier[1], 0, "embedded block carrier should anchor outside the concealed source row")
  assert_eq(carrier[3].virt_lines_above, false, "embedded block carrier should render after the previous row")
  assert_truthy(#virt_lines >= 3, "embedded block composer should split prefix, image, and suffix virtual lines")

  local prefix_text = virt_line_text(virt_lines[1])
  assert_truthy(prefix_text:find("pre X ", 1, true) ~= nil, "block composer should replay syntax conceal in prefix")
  assert_truthy(prefix_text:find("abc", 1, true) == nil, "block composer should not use raw display_prefix text")

  local seen_x_hl
  for _, chunk in ipairs(virt_lines[1]) do
    if (chunk[1] or ""):find("X", 1, true) ~= nil then
      seen_x_hl = chunk[2]
      break
    end
  end
  assert_hl_contains(
    seen_x_hl,
    "TypstConcealerBlockComposerWord",
    "block composer should preserve syntax conceal highlight"
  )

  local suffix_text = virt_line_text(virt_lines[#virt_lines])
  assert_truthy(suffix_text:find(" tail", 1, true) ~= nil, "block composer should replay suffix text")
  local seen_tail_hl
  for _, chunk in ipairs(virt_lines[#virt_lines]) do
    if chunk[1] == "t" then
      seen_tail_hl = chunk[2]
      break
    end
  end
  assert_hl_contains(seen_tail_hl, "String", "block composer should preserve suffix extmark highlights")

  local image_cols = 0
  local image_hl = "typst-concealer-image-id-" .. tostring(image_id)
  for _, virt_line in ipairs(virt_lines) do
    for _, chunk in ipairs(virt_line) do
      if chunk[2] == image_hl then
        image_cols = image_cols + vim.fn.strdisplaywidth(chunk[1] or "")
      end
    end
  end
  assert_eq(image_cols, 8, "embedded block composer should keep the rendered image placeholder width")

  vim.o.conceallevel = old_conceallevel
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_embedded_block_math_avoids_inline_source_anchor()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  local inline_line = "World $sin(alpha)$ beta lambda hello, world!"
  local block_line = "Hello, world $ sin(alpha) $ hello `hi`"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "before", inline_line, block_line, "after" })
  vim.api.nvim_win_set_cursor(0, { 4, 0 })

  local extmark = require("typst-concealer.extmark")
  local inline_id = 1306
  local inline_start, inline_end = inline_line:find("$sin(alpha)$", 1, true)
  local inline_range = { 1, inline_start - 1, 1, inline_end }
  local inline_semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" }
  local inline_extmark = extmark.place_render_extmark(bufnr, inline_id, inline_range, nil, true, inline_semantics)
  state.item_by_image_id[inline_id] = {
    bufnr = bufnr,
    image_id = inline_id,
    extmark_id = inline_extmark,
    range = inline_range,
    display_range = inline_range,
    node_type = "math",
    semantics = inline_semantics,
    natural_cols = 5,
    natural_rows = 1,
  }

  local block_id = 1307
  local block_start, block_end = block_line:find("$ sin(alpha) $", 1, true)
  local block_source_range = { 2, block_start - 1, 2, block_end }
  local block_display_range = { 2, 0, 2, #block_line }
  local block_semantics = {
    display_kind = "block",
    constraint_kind = "intrinsic",
    source_kind = "math",
    render_whole_line = true,
  }
  local block_extmark = extmark.place_render_extmark(bufnr, block_id, block_display_range, nil, true, block_semantics)
  state.item_by_image_id[block_id] = {
    bufnr = bufnr,
    image_id = block_id,
    extmark_id = block_extmark,
    range = block_source_range,
    display_range = block_display_range,
    display_prefix = "Hello, world",
    display_suffix = "hello `hi`",
    node_type = "math",
    semantics = block_semantics,
    natural_cols = 6,
    natural_rows = 1,
  }

  extmark.conceal_for_image_id(bufnr, block_id, 6, 1, 1)
  extmark.conceal_for_image_id(bufnr, inline_id, 5, 1, 1)

  local bs = state.get_buf_state(bufnr)
  local inline = bs.inline_line_marks[1]
  assert_truthy(inline ~= nil, "preceding inline math should still get a compact carrier")
  assert_eq(inline.anchor_row, 0, "preceding inline carrier should anchor above its source row")

  local mm = bs.multiline_marks[block_extmark]
  assert_truthy(mm ~= nil and mm.is_block_carrier == true, "embedded block should keep a block carrier")
  local carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, mm.carrier_id, { details = true })
  assert_eq(mm.carrier_id, inline.carrier_id, "adjacent inline and embedded block rows should share one run carrier")
  assert_eq(carrier[1], 0, "line-run carrier should anchor outside the rewritten source rows")
  assert_eq(carrier[3].virt_lines_above, false, "line-run carrier should render after the preceding safe row")
  assert_truthy(
    virt_line_text((carrier[3].virt_lines or {})[1] or {}):find("World", 1, true) ~= nil,
    "line-run carrier should render the preceding inline row first"
  )
  assert_truthy(
    virt_line_text((carrier[3].virt_lines or {})[2] or {}):find("Hello, world", 1, true) ~= nil,
    "embedded block carrier should still render the prefix"
  )

  local tail = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, mm.tail_ids[1], { details = true })
  assert_eq(tail[1], 2, "embedded block source row should still be concealed")
  assert_eq(tail[3].conceal_lines, "", "embedded block source row should collapse to zero height")

  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  extmark.sync_inline_line_carriers(bufnr, 1)
  assert_eq(bs.inline_line_marks[1], nil, "cursor row inline source should expand out of the shared run")
  carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, mm.carrier_id, { details = true })
  assert_eq(carrier[1], 3, "remaining embedded block run should re-anchor after the suppressed inline row")
  assert_eq(carrier[3].virt_lines_above, true, "remaining embedded block run should render before the following row")
  assert_truthy(
    virt_line_text((carrier[3].virt_lines or {})[1] or {}):find("Hello, world", 1, true) ~= nil,
    "embedded block should remain visible while the adjacent inline row is expanded"
  )

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_display_line_chunks_preserve_native_ui()
  fresh_state()

  local old_conceallevel = vim.o.conceallevel
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "A abc DEF tail" })
  vim.cmd("syntax on")
  vim.cmd("syntax match TypstConcealerTestWord /abc/ conceal cchar=X")
  vim.api.nvim_set_hl(0, "TypstConcealerTestWord", { fg = "#00ff00" })
  vim.o.conceallevel = 2

  local ns = vim.api.nvim_create_namespace("typst-concealer-display-test")
  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 6, {
    end_col = 9,
    conceal = "Y",
    hl_group = "ErrorMsg",
  })
  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 10, {
    virt_text = { { "V", "Search" } },
    virt_text_pos = "inline",
  })
  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 10, {
    end_col = 14,
    hl_group = "Search",
  })

  local chunks = require("typst-concealer.display").line_chunks(bufnr, 0)
  assert_eq(virt_line_text(chunks), "A X Y Vtail", "display chunks should replay native conceal and inline virt_text")

  local seen = {}
  for _, chunk in ipairs(chunks) do
    seen[chunk[1]] = chunk[2]
    if (chunk[1] or ""):find("V", 1, true) ~= nil then
      seen.V = chunk[2]
    end
    if (chunk[1] or ""):find("tail", 1, true) ~= nil then
      seen.tail = chunk[2]
    end
  end
  assert_hl_contains(seen.X, "TypstConcealerTestWord", "syntax conceal replacement should keep syntax highlight")
  assert_hl_contains(seen.Y, "ErrorMsg", "extmark conceal replacement should keep extmark highlight")
  assert_hl_contains(seen.V, "Search", "inline virtual text should keep its highlight")
  assert_hl_contains(seen.tail, "Search", "plain text should inherit extmark highlight")

  vim.o.conceallevel = old_conceallevel
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_display_line_chunks_preserve_treesitter_conceal()
  fresh_state()

  local old_conceallevel = vim.o.conceallevel
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local s = "abc"' })
  vim.bo[bufnr].filetype = "lua"
  vim.treesitter.query.set("lua", "highlights", '((string_content) @string.special (#set! conceal "X"))')
  vim.treesitter.start(bufnr, "lua")
  vim.cmd("redraw")
  vim.o.conceallevel = 2

  local chunks = require("typst-concealer.display").line_chunks(bufnr, 0)
  assert_eq(virt_line_text(chunks), 'local s = "X"', "display chunks should replay tree-sitter conceal")

  local seen_x_hl
  for _, chunk in ipairs(chunks) do
    if (chunk[1] or ""):find("X", 1, true) ~= nil then
      seen_x_hl = chunk[2]
      break
    end
  end
  assert_truthy(
    seen_x_hl == "@string.special.lua" or seen_x_hl == "@string.special",
    "tree-sitter conceal should keep capture highlight"
  )

  vim.o.conceallevel = old_conceallevel
  pcall(vim.treesitter.stop, bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_display_line_chunks_preserve_neovim_highlight_stack()
  fresh_state()

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'local s = "abc"' })
  vim.bo[bufnr].filetype = "lua"
  vim.treesitter.query.set("lua", "highlights", "((string_content) @string.special)")
  vim.treesitter.start(bufnr, "lua")
  vim.cmd("redraw")

  local ns = vim.api.nvim_create_namespace("typst-concealer-empty-highlight-test")
  vim.api.nvim_set_hl(0, "TypstConcealerEmptyHighlight", {})
  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 11, {
    end_col = 14,
    hl_group = "TypstConcealerEmptyHighlight",
    priority = 1000,
  })

  local chunks = require("typst-concealer.display").line_chunks(bufnr, 0)
  local seen_hl
  for _, chunk in ipairs(chunks) do
    if (chunk[1] or ""):find("abc", 1, true) ~= nil then
      seen_hl = chunk[2]
      break
    end
  end
  assert_truthy(
    hl_index(seen_hl, "@string.special.lua") ~= nil or hl_index(seen_hl, "@string.special") ~= nil,
    "tree-sitter highlight should remain in the Neovim-style highlight stack\nhl_group: " .. vim.inspect(seen_hl)
  )
  assert_hl_contains(
    seen_hl,
    "TypstConcealerEmptyHighlight",
    "higher-priority extmark highlight should remain in the Neovim-style highlight stack"
  )
  local tree_idx = hl_index(seen_hl, "@string.special.lua") or hl_index(seen_hl, "@string.special")
  local extmark_idx = hl_index(seen_hl, "TypstConcealerEmptyHighlight")
  assert_truthy(
    tree_idx < extmark_idx,
    "highlight stack should keep lower-priority tree-sitter before higher-priority extmark"
  )

  pcall(vim.treesitter.stop, bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_display_line_chunks_accept_math_conceal_provider()
  fresh_state()

  local original = package.loaded["math-conceal.render"]
  package.loaded["math-conceal.render"] = {
    collect_display_marks = function(bufnr, opts)
      assert_eq(opts.toprow, 0, "math-conceal provider should receive the target top row")
      assert_eq(opts.botrow, 0, "math-conceal provider should receive the target bottom row")
      return {
        {
          kind = "conceal",
          row = 0,
          col = 2,
          end_row = 0,
          end_col = 7,
          conceal = "alpha",
          hl_group = "@conceal",
          priority = 100,
        },
      }
    end,
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "A alpha tail" })

  local chunks = require("typst-concealer.display").line_chunks(bufnr, 0)
  assert_eq(virt_line_text(chunks), "A alpha tail", "display chunks should replay math-conceal provider marks")
  assert_eq(chunks[2][2], "@conceal", "math-conceal provider highlight should be preserved")

  package.loaded["math-conceal.render"] = original
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_compacts_inline_images_by_display_width()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  local line = "A " .. string.rep("x", 60) .. " B " .. string.rep("y", 60) .. " C end"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line, "after" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local extmark = require("typst-concealer.extmark")
  local semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "code" }
  local first_range = { 0, 2, 0, 62 }
  local second_range = { 0, 65, 0, 125 }
  local first_id = 1400
  local second_id = 1401
  local first_extmark = extmark.place_render_extmark(bufnr, first_id, first_range, nil, true, semantics)
  local second_extmark = extmark.place_render_extmark(bufnr, second_id, second_range, nil, true, semantics)

  state.item_by_image_id[first_id] = {
    bufnr = bufnr,
    image_id = first_id,
    extmark_id = first_extmark,
    range = first_range,
    display_range = first_range,
    node_type = "code",
    semantics = semantics,
    natural_cols = 2,
    natural_rows = 1,
  }
  state.item_by_image_id[second_id] = {
    bufnr = bufnr,
    image_id = second_id,
    extmark_id = second_extmark,
    range = second_range,
    display_range = second_range,
    node_type = "code",
    semantics = semantics,
    natural_cols = 2,
    natural_rows = 1,
  }

  extmark.conceal_for_image_id(bufnr, first_id, 2, 1, 1)
  extmark.conceal_for_image_id(bufnr, second_id, 2, 1, 1)

  local bs = state.get_buf_state(bufnr)
  local inline = bs.inline_line_marks[0]
  assert_truthy(inline ~= nil, "inline line should get a compact carrier")
  local carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, inline.carrier_id, { details = true })
  assert_truthy(carrier[1] ~= 0, "compact inline carrier should not be attached to the concealed source row")
  local virt_lines = carrier[3].virt_lines or {}
  assert_eq(#virt_lines, 1, "compact inline carrier should wrap by rendered width, not source width")
  local rendered = virt_line_text(virt_lines[1])
  assert_startswith(rendered, "A ", "compact inline carrier should keep source text before the first image")
  assert_truthy(rendered:find(" B ", 1, true) ~= nil, "compact inline carrier should keep text between images")
  assert_truthy(rendered:find(" C end", 1, true) ~= nil, "compact inline carrier should keep text after images")
  assert_eq(vim.fn.strdisplaywidth(rendered), 15, "compact inline carrier width should use image display cells")

  local conceal = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, inline.conceal_id, { details = true })
  assert_eq(conceal[3].conceal_lines, "", "compact inline carrier should hide the original source line")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_inline_math_carrier_reuses_display_composer()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  local line = "pre $x$ mid `hi` $y$ tail"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line, "after" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local code_start, code_end = line:find("`hi`", 1, true)
  local hl_ns = vim.api.nvim_create_namespace("typst-concealer-inline-math-composer-test")
  vim.api.nvim_buf_set_extmark(bufnr, hl_ns, 0, code_start - 1, {
    end_col = code_end,
    hl_group = "String",
  })

  local extmark = require("typst-concealer.extmark")
  local semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" }
  local first_start, first_end = line:find("$x$", 1, true)
  local second_start, second_end = line:find("$y$", 1, true)
  local first_range = { 0, first_start - 1, 0, first_end }
  local second_range = { 0, second_start - 1, 0, second_end }
  local first_id = 1403
  local second_id = 1404
  local first_extmark = extmark.place_render_extmark(bufnr, first_id, first_range, nil, true, semantics)
  local second_extmark = extmark.place_render_extmark(bufnr, second_id, second_range, nil, true, semantics)

  state.item_by_image_id[first_id] = {
    bufnr = bufnr,
    image_id = first_id,
    extmark_id = first_extmark,
    range = first_range,
    display_range = first_range,
    node_type = "math",
    semantics = semantics,
    natural_cols = 2,
    natural_rows = 1,
  }
  state.item_by_image_id[second_id] = {
    bufnr = bufnr,
    image_id = second_id,
    extmark_id = second_extmark,
    range = second_range,
    display_range = second_range,
    node_type = "math",
    semantics = semantics,
    natural_cols = 3,
    natural_rows = 1,
  }

  extmark.conceal_for_image_id(bufnr, first_id, 2, 1, 1)
  extmark.conceal_for_image_id(bufnr, second_id, 3, 1, 1)

  local inline = state.get_buf_state(bufnr).inline_line_marks[0]
  assert_truthy(inline ~= nil, "inline math row should get the shared compact carrier")
  local carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, inline.carrier_id, { details = true })
  local virt_lines = carrier[3].virt_lines or {}
  local rendered = {}
  local code_hl
  local image_cols = 0
  for _, virt_line in ipairs(virt_lines) do
    for _, chunk in ipairs(virt_line) do
      rendered[#rendered + 1] = chunk[1] or ""
      if chunk[1] == "h" then
        code_hl = chunk[2]
      end
      if
        chunk[2] == "typst-concealer-image-id-" .. tostring(first_id)
        or chunk[2] == "typst-concealer-image-id-" .. tostring(second_id)
      then
        image_cols = image_cols + vim.fn.strdisplaywidth(chunk[1] or "")
      end
    end
  end
  local rendered_text = table.concat(rendered)
  assert_truthy(rendered_text:find("$x$", 1, true) == nil, "composer should replace the first inline formula source")
  assert_truthy(rendered_text:find("$y$", 1, true) == nil, "composer should replace the second inline formula source")
  assert_truthy(rendered_text:find("pre ", 1, true) ~= nil, "composer should preserve text before inline formulas")
  assert_truthy(
    rendered_text:find(" mid `hi` ", 1, true) ~= nil,
    "composer should preserve text between inline formulas"
  )
  assert_truthy(rendered_text:find(" tail", 1, true) ~= nil, "composer should preserve text after inline formulas")
  assert_eq(image_cols, 5, "composer wrapping should account for rendered math image width")
  assert_hl_contains(code_hl, "String", "inline math carrier should replay surrounding native highlights")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_inline_carrier_replays_native_ui()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local old_conceallevel = vim.o.conceallevel
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  local source = string.rep("x", 20)
  local line = "A abc " .. source .. " DEF"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line, "after" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("syntax on")
  vim.cmd("syntax match TypstConcealerCarrierWord /abc/ conceal cchar=X")
  vim.api.nvim_set_hl(0, "TypstConcealerCarrierWord", { fg = "#00ff00" })
  vim.o.conceallevel = 2

  local other_ns = vim.api.nvim_create_namespace("typst-concealer-carrier-native-test")
  vim.api.nvim_buf_set_extmark(bufnr, other_ns, 0, #("A abc " .. source .. " "), {
    end_col = #line,
    conceal = "Y",
    hl_group = "ErrorMsg",
  })

  local extmark = require("typst-concealer.extmark")
  local semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "code" }
  local range = { 0, 6, 0, 6 + #source }
  local image_id = 1402
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
  state.item_by_image_id[image_id] = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = range,
    display_range = range,
    node_type = "code",
    semantics = semantics,
    natural_cols = 2,
    natural_rows = 1,
  }

  extmark.conceal_for_image_id(bufnr, image_id, 2, 1, 1)

  local inline = state.get_buf_state(bufnr).inline_line_marks[0]
  assert_truthy(inline ~= nil, "inline line should get a compact carrier")
  local carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, inline.carrier_id, { details = true })
  local rendered = virt_line_text((carrier[3].virt_lines or {})[1] or {})
  assert_truthy(rendered:find("X", 1, true) ~= nil, "compact carrier should replay syntax conceal")
  assert_truthy(rendered:find("Y", 1, true) ~= nil, "compact carrier should replay extmark conceal")
  assert_truthy(rendered:find("abc", 1, true) == nil, "compact carrier should not show concealed syntax source")
  assert_truthy(rendered:find("DEF", 1, true) == nil, "compact carrier should not show concealed extmark source")

  vim.o.conceallevel = old_conceallevel
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_inline_carrier_does_not_anchor_across_block_conceal()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "\\[",
    "x",
    "\\]",
    "Inline $y$",
    "after",
    "tail",
  })
  vim.api.nvim_win_set_cursor(0, { 6, 0 })

  local extmark = require("typst-concealer.extmark")
  local block_semantics = { display_kind = "block", constraint_kind = "intrinsic", source_kind = "math" }
  local block_id = 1415
  local block_range = { 0, 0, 2, 2 }
  local block_extmark = extmark.place_render_extmark(bufnr, block_id, block_range, nil, true, block_semantics)
  state.item_by_image_id[block_id] = {
    bufnr = bufnr,
    image_id = block_id,
    extmark_id = block_extmark,
    range = block_range,
    display_range = block_range,
    node_type = "math",
    semantics = block_semantics,
    natural_cols = 6,
    natural_rows = 2,
  }

  extmark.conceal_for_image_id(bufnr, block_id, 6, 2, 3)

  local inline_semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" }
  local inline_id = 1416
  local inline_range = { 3, 7, 3, 10 }
  local inline_extmark = extmark.place_render_extmark(bufnr, inline_id, inline_range, nil, true, inline_semantics)
  state.item_by_image_id[inline_id] = {
    bufnr = bufnr,
    image_id = inline_id,
    extmark_id = inline_extmark,
    range = inline_range,
    display_range = inline_range,
    node_type = "math",
    semantics = inline_semantics,
    natural_cols = 2,
    natural_rows = 1,
  }

  extmark.conceal_for_image_id(bufnr, inline_id, 2, 1, 1)

  local bs = state.get_buf_state(bufnr)
  local inline = bs.inline_line_marks[3]
  assert_truthy(inline ~= nil, "inline row following a concealed block should still get a compact carrier")
  local carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, inline.carrier_id, { details = true })
  assert_eq(carrier[1], 4, "inline carrier should anchor below the inline row instead of above the block")
  assert_eq(carrier[3].virt_lines_above, true, "inline carrier below the row should render above its anchor")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_compact_inline_image_chunks_wrap()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  local line = "A " .. string.rep("x", 60) .. " B"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line, "after" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local info = vim.fn.getwininfo(0)[1]
  local text_cols = vim.api.nvim_win_get_width(0) - ((info and info.textoff) or 0)
  local natural_cols = text_cols + 7

  local extmark = require("typst-concealer.extmark")
  local semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "code" }
  local range = { 0, 2, 0, 62 }
  local image_id = 1405
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
  state.item_by_image_id[image_id] = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = range,
    display_range = range,
    node_type = "code",
    semantics = semantics,
    natural_cols = natural_cols,
    natural_rows = 1,
  }

  extmark.conceal_for_image_id(bufnr, image_id, natural_cols, 1, 1)

  local bs = state.get_buf_state(bufnr)
  local inline = bs.inline_line_marks[0]
  assert_truthy(inline ~= nil, "wide inline image should get a compact carrier")
  local carrier = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, inline.carrier_id, { details = true })
  local virt_lines = carrier[3].virt_lines or {}
  assert_truthy(#virt_lines >= 2, "wide inline image should wrap across compact virtual lines")

  local hl_group = "typst-concealer-image-id-" .. tostring(image_id)
  local image_cols = 0
  for _, virt_line in ipairs(virt_lines) do
    assert_truthy(
      vim.fn.strdisplaywidth(virt_line_text(virt_line)) <= text_cols,
      "compact wrapped line should fit within the text viewport"
    )
    for _, chunk in ipairs(virt_line) do
      if chunk[2] == hl_group then
        image_cols = image_cols + vim.fn.strdisplaywidth(chunk[1] or "")
      end
    end
  end
  assert_eq(image_cols, natural_cols, "wide inline image placeholders should not be truncated")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_inline_compact_carrier_follows_cursor_row()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  local line = "A " .. string.rep("x", 60) .. " B"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line, "after" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  local extmark = require("typst-concealer.extmark")
  local semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "code" }
  local range = { 0, 2, 0, 62 }
  local image_id = 1410
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
  state.item_by_image_id[image_id] = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = range,
    display_range = range,
    node_type = "code",
    semantics = semantics,
    natural_cols = 2,
    natural_rows = 1,
  }

  extmark.conceal_for_image_id(bufnr, image_id, 2, 1, 1)
  local bs = state.get_buf_state(bufnr)
  assert_truthy(bs.inline_line_marks[0] ~= nil, "compact carrier should exist before cursor enters the row")

  extmark.sync_inline_line_carriers(bufnr, 0)
  assert_eq(bs.inline_line_marks[0], nil, "compact carrier should clear while the cursor is on its row")
  assert_truthy(bs.inline_line_attachment_marks[extmark_id] ~= nil, "cursor row should attach the image after source")
  local source_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
  assert_eq(source_mark[3].conceal, "", "cursor row source extmark should still conceal source")
  assert_truthy(
    source_mark[3].virt_text == nil or source_mark[3].virt_text[1] == nil or source_mark[3].virt_text[1][1] == "",
    "cursor row source extmark should not render the image placeholder at source start"
  )
  local attachment = bs.inline_line_attachment_marks[extmark_id]
  local attachment_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id2, attachment.attach_id, {
    details = true,
  })
  assert_eq(attachment_mark[1], 0, "cursor row image attachment should stay on the source row")
  assert_eq(attachment_mark[2], range[4], "cursor row image attachment should be placed after source")
  assert_truthy(
    attachment_mark[3].virt_text ~= nil and attachment_mark[3].virt_text[1] ~= nil,
    "cursor row image attachment should render the image placeholder"
  )

  extmark.conceal_for_image_id(bufnr, image_id, 2, 1, 1)
  source_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
  assert_eq(source_mark[3].conceal, "", "image refresh should keep the cursor row source concealed")

  extmark.sync_inline_line_carriers(bufnr, 1)
  assert_truthy(bs.inline_line_marks[0] ~= nil, "compact carrier should restore after cursor leaves its row")
  assert_eq(bs.inline_line_attachment_marks[extmark_id], nil, "leaving the row should clear row image attachment")
  source_mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
  assert_eq(source_mark[3].conceal, "", "leaving the row should restore source extmark conceal")
  assert_truthy(
    source_mark[3].virt_text ~= nil and source_mark[3].virt_text[1] ~= nil and source_mark[3].virt_text[1][1] ~= "",
    "leaving the row should restore the inline image placeholder"
  )

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_extmark_clears_shifted_inline_compact_carriers()
  local state = fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
      block_padding_cols = 0,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  local line = "A " .. string.rep("x", 60) .. " B"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "before", line, "after" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })

  local extmark = require("typst-concealer.extmark")
  local semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "code" }
  local range = { 1, 2, 1, 62 }
  local image_id = 1415
  local extmark_id = extmark.place_render_extmark(bufnr, image_id, range, nil, true, semantics)
  state.item_by_image_id[image_id] = {
    bufnr = bufnr,
    image_id = image_id,
    extmark_id = extmark_id,
    range = range,
    display_range = range,
    node_type = "code",
    semantics = semantics,
    natural_cols = 2,
    natural_rows = 1,
  }

  extmark.conceal_for_image_id(bufnr, image_id, 2, 1, 1)
  local bs = state.get_buf_state(bufnr)
  assert_truthy(bs.inline_line_marks[1] ~= nil, "compact carrier should exist before line insertion")

  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "" })
  local cleared = extmark.clear_inline_line_marks(bufnr, 0)
  assert_eq(cleared, 1, "line insertion should clear shifted compact carriers")
  assert_eq(bs.inline_line_marks[1], nil, "old row-keyed compact carrier should be removed")

  local ns2_marks = vim.api.nvim_buf_get_extmarks(bufnr, state.ns_id2, { 0, 0 }, { -1, -1 }, {})
  assert_eq(#ns2_marks, 0, "shifted compact carrier extmarks should be deleted")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_cursor_visibility_preserves_insert_math_after_stale_range()
  fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "A $ sin$" })
  vim.api.nvim_win_set_cursor(0, { 1, 6 })

  local cursor_visibility = require("typst-concealer.cursor-visibility")
  local item = {
    bufnr = bufnr,
    range = { 0, 2, 0, 5 },
    display_range = { 0, 0, 0, 5 },
    node_type = "math",
    semantics = {
      source_kind = "math",
      display_kind = "block",
      constraint_kind = "intrinsic",
      render_whole_line = true,
    },
  }

  assert_eq(
    cursor_visibility.should_preserve_source_at_cursor(bufnr, item, "i"),
    true,
    "insert cursor inside the current math span should keep stale overlays unconcealed"
  )

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_cursor_visibility_does_not_expand_to_adjacent_formula()
  fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$ a$ and $ b$" })
  vim.api.nvim_win_set_cursor(0, { 1, 11 })

  local cursor_visibility = require("typst-concealer.cursor-visibility")
  local item = {
    bufnr = bufnr,
    range = { 0, 0, 0, 4 },
    display_range = { 0, 0, 0, 4 },
    node_type = "math",
    semantics = {
      source_kind = "math",
      display_kind = "block",
      constraint_kind = "intrinsic",
      render_whole_line = true,
    },
  }

  assert_eq(
    cursor_visibility.should_preserve_source_at_cursor(bufnr, item, "i"),
    false,
    "insert cursor in another formula should not unconceal a disjoint stale overlay"
  )

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_cursor_visibility_inline_code_only_expands_inside_range()
  fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      conceal_in_normal = false,
    },
  }

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "A #text(red)[x] tail" })

  local cursor_visibility = require("typst-concealer.cursor-visibility")
  local item = {
    bufnr = bufnr,
    range = { 0, 2, 0, 15 },
    display_range = { 0, 2, 0, 15 },
    node_type = "code",
    semantics = {
      source_kind = "code",
      display_kind = "inline",
      constraint_kind = "intrinsic",
    },
  }

  vim.api.nvim_win_set_cursor(0, { 1, 17 })
  assert_eq(
    cursor_visibility.should_preserve_source_at_cursor(bufnr, item, "n"),
    false,
    "inline code should not expand merely because the cursor is on the same row"
  )

  vim.api.nvim_win_set_cursor(0, { 1, 8 })
  assert_eq(
    cursor_visibility.should_preserve_source_at_cursor(bufnr, item, "n"),
    true,
    "inline code should expand when the cursor enters its source range"
  )

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_machine_runtime_builds_service_render_job()
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
    config = {},
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
    config = {},
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

local function test_machine_runtime_cursor_sync_renders_preview()
  fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      cursor_hover_throttle_ms = 0,
      use_formula_service = false,
    },
  }

  local preview_calls = 0
  local hover_calls = 0
  package.loaded["typst-concealer.plan"] = {
    render_live_typst_preview = function()
      preview_calls = preview_calls + 1
    end,
    hide_extmarks_at_cursor = function()
      hover_calls = hover_calls + 1
    end,
  }

  require("typst-concealer.machine.runtime").sync_cursor_ui(1)
  assert_eq(preview_calls, 1, "CursorMoved sync should render preview")
  assert_eq(hover_calls, 1, "CursorMoved sync should still update conceal state")
end

local function test_machine_runtime_cursor_sync_routes_latex_to_formula_manager()
  fresh_state()
  package.loaded["typst-concealer"] = {
    config = {
      cursor_hover_throttle_ms = 0,
      use_formula_service = false,
    },
    source_kind_for_bufnr = function()
      return "latex"
    end,
  }

  local preview_calls = 0
  local hover_calls = 0
  package.loaded["typst-concealer.formula.manager"] = {
    sync_cursor_preview = function()
      preview_calls = preview_calls + 1
    end,
    sync_cursor_conceal = function()
      hover_calls = hover_calls + 1
    end,
  }

  local fallback_preview_calls = 0
  local fallback_hover_calls = 0
  package.loaded["typst-concealer.plan"] = {
    render_live_typst_preview = function()
      fallback_preview_calls = fallback_preview_calls + 1
    end,
    hide_extmarks_at_cursor = function()
      fallback_hover_calls = fallback_hover_calls + 1
    end,
  }

  require("typst-concealer.machine.runtime").sync_cursor_ui(1)
  assert_eq(preview_calls, 1, "latex CursorMoved sync should use formula-manager preview")
  assert_eq(hover_calls, 1, "latex CursorMoved sync should use formula-manager hover")
  assert_eq(fallback_preview_calls, 0, "latex CursorMoved sync should not use legacy Typst preview")
  assert_eq(fallback_hover_calls, 0, "latex CursorMoved sync should not use legacy hover")
end

local function test_machine_runtime_reconciles_visible_overlay_binding_from_extmark()
  local state = fresh_state()
  local runtime = require("typst-concealer.machine.runtime")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "alpha",
    "beta",
    "gamma",
    "delta",
  })

  local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, state.ns_id, 2, 0, {
    id = 41,
    end_row = 3,
    end_col = 5,
    virt_text = { { "" } },
    virt_text_pos = "overlay",
    invalidate = true,
  })

  state.machine_state.buffers[bufnr] = {
    bufnr = bufnr,
    project_scope_id = "p",
    buffer_version = 1,
    layout_version = 80,
    nodes = {
      ["node:1"] = {
        node_id = "node:1",
        bufnr = bufnr,
        project_scope_id = "p",
        visible_overlay_id = "overlay:1",
        display_range = { 0, 0, 1, 4 },
      },
    },
    node_order = { "node:1" },
  }
  state.machine_state.overlays["overlay:1"] = {
    overlay_id = "overlay:1",
    owner_bufnr = bufnr,
    owner_node_id = "node:1",
    request_id = "request:1",
    extmark_id = extmark_id,
    binding_display_range = { 0, 0, 1, 4 },
    binding_buffer_version = 1,
    binding_layout_version = 80,
  }

  local repaired = runtime.reconcile_visible_overlay_bindings(bufnr)
  local overlay = state.machine_state.overlays["overlay:1"]
  assert_eq(repaired, 1, "reconcile should repair stale visible overlay binding metadata")
  assert_eq(overlay.binding_display_range[1], 2, "binding start row should follow the actual extmark row")
  assert_eq(overlay.binding_display_range[3], 3, "binding end row should follow the actual extmark end row")
  assert_eq(overlay.binding_display_range[4], 5, "binding end col should follow the actual extmark end col")
  assert_eq(
    overlay.binding_buffer_version,
    vim.api.nvim_buf_get_changedtick(bufnr),
    "reconcile should stamp the current changedtick onto the repaired binding"
  )
end

local function test_machine_runtime_refreshes_visible_overlays_without_render_request()
  local state = fresh_state()
  local runtime = require("typst-concealer.machine.runtime")
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, "visible-refresh.typ")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$", "plain", "$y$" })
  package.loaded["typst-concealer"] = {
    _enabled_buffers = { [bufnr] = true },
    is_render_allowed = function()
      return true
    end,
    config = {
      conceal_in_normal = false,
    },
  }

  state.machine_state.buffers[bufnr] = {
    bufnr = bufnr,
    project_scope_id = "p",
    buffer_version = 1,
    layout_version = 80,
    nodes = {
      ["node:visible"] = {
        node_id = "node:visible",
        bufnr = bufnr,
        project_scope_id = "p",
        item_idx = 1,
        node_type = "math",
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$x$",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        status = "stable",
        visible_overlay_id = "overlay:visible",
      },
    },
    node_order = { "node:visible" },
  }
  state.machine_state.overlays["overlay:visible"] = {
    overlay_id = "overlay:visible",
    owner_node_id = "node:visible",
    owner_bufnr = bufnr,
    owner_project_scope_id = "p",
    request_id = "request:1",
    image_id = 1400,
    extmark_id = 1500,
    page_path = "/tmp/visible-refresh.png",
    page_stamp = "stamp:1",
    natural_cols = 2,
    natural_rows = 1,
    source_rows = 1,
    status = "visible",
    buffer_version = 1,
    layout_version = 80,
  }

  with_stubbed_extmark(function(calls)
    local refreshed = runtime.refresh_visible_overlays(bufnr, { margin = 0 })
    assert_eq(refreshed, 1, "visible refresh should process visible rendered overlays")
    assert_eq(#calls.swapped, 1, "visible refresh should rebind the visible extmark")
    assert_eq(#calls.created, 1, "newly visible overlay should be re-uploaded once")
    assert_eq(calls.flushed, 1, "visible refresh should flush uploaded image data")
    assert_eq(#calls.concealed, 1, "visible refresh should rewrite image placeholders")

    refreshed = runtime.refresh_visible_overlays(bufnr, { margin = 0 })
    assert_eq(refreshed, 1, "visible refresh should remain lightweight on repeated calls")
    assert_eq(#calls.created, 1, "unchanged visible overlay should not re-upload every cursor move")
    assert_eq(calls.flushed, 1, "visible refresh should not flush when nothing was uploaded")
    assert_eq(#calls.concealed, 2, "unchanged visible overlay should still rewrite placeholders")

    runtime.invalidate_terminal_uploads()
    refreshed = runtime.refresh_visible_overlays(bufnr, { margin = 0 })
    assert_eq(refreshed, 1, "terminal epoch invalidation should keep refresh lightweight")
    assert_eq(#calls.created, 2, "terminal epoch invalidation should re-upload the existing artifact")
    assert_eq(calls.flushed, 2, "terminal epoch repair should flush re-uploaded image data")
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_formula_manager_tracks_placement_indexes_and_read_model()
  local state = fresh_state()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$", "$y$" })

  state.machine_state.buffers[bufnr] = {
    bufnr = bufnr,
    project_scope_id = "p",
    buffer_version = 3,
    layout_version = 80,
    render_epoch = 2,
    context_id = "ctx",
    context_rev = 4,
    nodes = {
      ["node:x"] = {
        node_id = "node:x",
        bufnr = bufnr,
        project_scope_id = "p",
        item_idx = 1,
        node_type = "math",
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
        node_rev = 7,
        context_hash = "ctx:4",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" },
        status = "stable",
        visible_overlay_id = "overlay:x",
      },
      ["node:y"] = {
        node_id = "node:y",
        bufnr = bufnr,
        project_scope_id = "p",
        item_idx = 2,
        node_type = "math",
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$y$",
        source_text_hash = "hash:y",
        node_rev = 8,
        context_hash = "ctx:4",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" },
        status = "pending",
        candidate_overlay_id = "overlay:y",
      },
    },
    node_order = { "node:x", "node:y" },
  }
  state.machine_state.overlays["overlay:x"] = {
    overlay_id = "overlay:x",
    owner_node_id = "node:x",
    owner_bufnr = bufnr,
    owner_project_scope_id = "p",
    request_id = "request:x",
    render_epoch = 2,
    node_rev = 7,
    context_id = "ctx",
    context_rev = 4,
    buffer_version = 3,
    layout_version = 80,
    image_id = 3001,
    extmark_id = 4001,
    page_path = "/tmp/x.png",
    natural_cols = 2,
    natural_rows = 1,
    source_rows = 1,
    terminal_upload_epoch = 9,
    status = "visible",
  }
  state.machine_state.overlays["overlay:y"] = {
    overlay_id = "overlay:y",
    owner_node_id = "node:y",
    owner_bufnr = bufnr,
    owner_project_scope_id = "p",
    request_id = "request:y",
    render_epoch = 2,
    node_rev = 8,
    context_id = "ctx",
    context_rev = 4,
    buffer_version = 3,
    layout_version = 80,
    image_id = 3002,
    status = "rendering",
  }

  local manager = require("typst-concealer.formula.manager").get(bufnr):sync_from_machine()
  assert_truthy(manager.by_node_id["node:x"] ~= nil, "manager should index visible placement by node")
  assert_truthy(manager.by_node_id["node:y"] ~= nil, "manager should index pending placement by node")
  assert_eq(manager.extmark_index[4001], manager.by_node_id["node:x"], "manager should index visible extmark")
  assert_eq(manager.by_image_id[3001], manager.by_node_id["node:x"], "manager should index visible image")
  assert_eq(
    manager.by_node_id["node:y"].pending_render.request_id,
    "request:y",
    "placement should own pending render state"
  )
  assert_eq(manager.by_node_id["node:x"].image.sent_epoch, 9, "formula image should track terminal upload epoch")
  assert_eq(state.buffer_render_state[bufnr].full_items[1].node_id, "node:x", "read model should come from placement")
  assert_eq(state.item_by_image_id[3001].node_id, "node:x", "placement read model should index by image id")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_formula_placement_show_clears_hidden_before_conceal()
  local state = fresh_state()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$x$" })

  state.machine_state.buffers[bufnr] = {
    bufnr = bufnr,
    project_scope_id = "p",
    buffer_version = 1,
    layout_version = 80,
    render_epoch = 1,
    context_id = "ctx",
    context_rev = 1,
    nodes = {
      ["node:x"] = {
        node_id = "node:x",
        bufnr = bufnr,
        project_scope_id = "p",
        item_idx = 1,
        node_type = "math",
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$x$",
        source_text_hash = "hash:x",
        node_rev = 1,
        context_hash = "ctx",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" },
        status = "stable",
        visible_overlay_id = "overlay:x",
      },
    },
    node_order = { "node:x" },
  }
  state.machine_state.overlays["overlay:x"] = {
    overlay_id = "overlay:x",
    owner_node_id = "node:x",
    owner_bufnr = bufnr,
    owner_project_scope_id = "p",
    request_id = "request:x",
    render_epoch = 1,
    node_rev = 1,
    context_id = "ctx",
    context_rev = 1,
    buffer_version = 1,
    layout_version = 80,
    image_id = 501,
    extmark_id = 601,
    page_path = "/tmp/x.png",
    natural_cols = 2,
    natural_rows = 1,
    source_rows = 1,
    status = "visible",
  }

  local manager = require("typst-concealer.formula.manager").get(bufnr):sync_from_machine()
  local placement = manager.by_node_id["node:x"]
  local bs = state.get_buf_state(bufnr)
  bs.currently_hidden_extmark_ids[601] = true

  local original = package.loaded["typst-concealer.extmark"]
  local hidden_during_conceal = true
  package.loaded["typst-concealer.extmark"] = {
    conceal_for_image_id = function(target_bufnr)
      hidden_during_conceal = state.get_buf_state(target_bufnr).currently_hidden_extmark_ids[601]
    end,
  }

  local ok_run, err = pcall(function()
    assert_eq(placement:show(), true, "show should restore a visible placement")
    assert_eq(hidden_during_conceal, nil, "show should clear hidden state before redrawing the image")
  end)
  package.loaded["typst-concealer.extmark"] = original
  vim.api.nvim_buf_delete(bufnr, { force = true })
  if not ok_run then
    error(err)
  end
end

local function test_formula_cursor_fast_boundary_switch_only_touches_previous_and_current()
  local state = fresh_state()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$a$ and $b$ and $c$" })
  package.loaded["typst-concealer"] = {
    _enabled_buffers = { [bufnr] = true },
    is_render_allowed = function()
      return true
    end,
    config = {
      use_formula_service = true,
      conceal_in_normal = false,
    },
  }

  local nodes = {}
  local overlays = {}
  local specs = {
    { "a", 0, 3, 101, 201 },
    { "b", 8, 11, 102, 202 },
    { "c", 16, 19, 103, 203 },
  }
  for i, spec in ipairs(specs) do
    local name, start_col, end_col, image_id, extmark_id = spec[1], spec[2], spec[3], spec[4], spec[5]
    local node_id = "node:" .. name
    local overlay_id = "overlay:" .. name
    nodes[node_id] = {
      node_id = node_id,
      bufnr = bufnr,
      project_scope_id = "p",
      item_idx = i,
      node_type = "math",
      source_range = { 0, start_col, 0, end_col },
      display_range = { 0, start_col, 0, end_col },
      source_text = "$" .. name .. "$",
      source_text_hash = "hash:" .. name,
      node_rev = 1,
      context_hash = "ctx",
      prelude_count = 0,
      semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" },
      status = "stable",
      visible_overlay_id = overlay_id,
    }
    overlays[overlay_id] = {
      overlay_id = overlay_id,
      owner_node_id = node_id,
      owner_bufnr = bufnr,
      owner_project_scope_id = "p",
      request_id = "request:" .. name,
      render_epoch = 1,
      node_rev = 1,
      context_id = "ctx",
      context_rev = 1,
      buffer_version = 1,
      layout_version = 80,
      image_id = image_id,
      extmark_id = extmark_id,
      page_path = "/tmp/" .. name .. ".png",
      natural_cols = 1,
      natural_rows = 1,
      source_rows = 1,
      terminal_upload_epoch = state.terminal_upload_epoch,
      status = "visible",
    }
  end
  state.machine_state.buffers[bufnr] = {
    bufnr = bufnr,
    project_scope_id = "p",
    buffer_version = 1,
    layout_version = 80,
    render_epoch = 1,
    context_id = "ctx",
    context_rev = 1,
    nodes = nodes,
    node_order = { "node:a", "node:b", "node:c" },
  }
  state.machine_state.overlays = overlays
  local manager = require("typst-concealer.formula.manager").get(bufnr):sync_from_machine()

  with_stubbed_extmark(function(calls)
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    manager:sync_cursor_conceal()
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    manager:sync_cursor_conceal()
    vim.api.nvim_win_set_cursor(0, { 1, 9 })
    manager:sync_cursor_conceal()

    assert_eq(#calls.unconcealed, 2, "fast cursor movement should hide only entered formula placements")
    assert_eq(calls.unconcealed[1].extmark_id, 201, "first formula should be hidden when entered")
    assert_eq(calls.unconcealed[2].extmark_id, 202, "second formula should be hidden when entered")
    assert_eq(#calls.concealed, 1, "leaving the first formula should restore only that source placement")
    assert_eq(calls.concealed[1].image_id, 101, "restore should target the previous formula image")
    for _, call in ipairs(calls.unconcealed) do
      assert_truthy(call.extmark_id ~= 203, "unrelated formula extmark should not be hidden")
    end
    for _, call in ipairs(calls.concealed) do
      assert_truthy(call.image_id ~= 103, "unrelated formula image should not be reattached")
    end
    assert_eq(#calls.syncs, 3, "cursor boundary changes should reconcile line-runs once after each transition")
    assert_eq(#calls.syncs[#calls.syncs].hidden, 1, "final line-run resync should observe one settled hidden extmark")
    assert_eq(
      calls.syncs[#calls.syncs].hidden[1],
      202,
      "final line-run resync should observe the settled hidden extmark set"
    )
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_formula_cursor_preview_targets_single_placement()
  local state = fresh_state()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$a$ $b$" })
  vim.api.nvim_win_set_cursor(0, { 1, 5 })

  package.loaded["typst-concealer"] = {
    _enabled_buffers = { [bufnr] = true },
    is_render_allowed = function()
      return true
    end,
    config = {
      use_formula_service = true,
      live_preview_enabled = true,
      conceal_in_normal = false,
    },
  }

  state.machine_state.buffers[bufnr] = {
    bufnr = bufnr,
    project_scope_id = "p",
    buffer_version = 1,
    layout_version = 80,
    render_epoch = 1,
    context_id = "ctx",
    context_rev = 1,
    nodes = {
      ["node:a"] = {
        node_id = "node:a",
        bufnr = bufnr,
        project_scope_id = "p",
        item_idx = 1,
        node_type = "math",
        source_range = { 0, 0, 0, 3 },
        display_range = { 0, 0, 0, 3 },
        source_text = "$a$",
        source_text_hash = "hash:a",
        node_rev = 1,
        context_hash = "ctx",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" },
        status = "stable",
        visible_overlay_id = "overlay:a",
      },
      ["node:b"] = {
        node_id = "node:b",
        bufnr = bufnr,
        project_scope_id = "p",
        item_idx = 2,
        node_type = "math",
        source_range = { 0, 4, 0, 7 },
        display_range = { 0, 4, 0, 7 },
        source_text = "$b$",
        source_text_hash = "hash:b",
        node_rev = 1,
        context_hash = "ctx",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic", source_kind = "math" },
        status = "stable",
        visible_overlay_id = "overlay:b",
      },
    },
    node_order = { "node:a", "node:b" },
  }
  state.machine_state.overlays["overlay:a"] = {
    overlay_id = "overlay:a",
    owner_node_id = "node:a",
    owner_bufnr = bufnr,
    owner_project_scope_id = "p",
    request_id = "request:a",
    render_epoch = 1,
    node_rev = 1,
    context_id = "ctx",
    context_rev = 1,
    buffer_version = 1,
    layout_version = 80,
    image_id = 701,
    extmark_id = 801,
    page_path = "/tmp/a.png",
    natural_cols = 1,
    natural_rows = 1,
    source_rows = 1,
    status = "visible",
  }
  state.machine_state.overlays["overlay:b"] = {
    overlay_id = "overlay:b",
    owner_node_id = "node:b",
    owner_bufnr = bufnr,
    owner_project_scope_id = "p",
    request_id = "request:b",
    render_epoch = 1,
    node_rev = 1,
    context_id = "ctx",
    context_rev = 1,
    buffer_version = 1,
    layout_version = 80,
    image_id = 702,
    extmark_id = 802,
    page_path = "/tmp/b.png",
    natural_cols = 1,
    natural_rows = 1,
    source_rows = 1,
    status = "visible",
  }

  local preview_calls = {}
  local clear_calls = 0
  package.loaded["typst-concealer.plan"] = {
    render_live_typst_preview_for_item = function(_, item)
      preview_calls[#preview_calls + 1] = item
      return true, { node_id = item.node_id }, "preview:" .. tostring(item.node_id)
    end,
    clear_live_typst_preview = function()
      clear_calls = clear_calls + 1
    end,
  }

  local manager = require("typst-concealer.formula.manager").get(bufnr)
  assert_eq(manager:sync_cursor_preview(), true, "cursor preview should expand the current placement")
  assert_eq(#preview_calls, 1, "cursor preview should target exactly one placement")
  assert_eq(preview_calls[1].node_id, "node:b", "cursor preview should target the placement under cursor")
  assert_eq(manager.preview_placement_id, "node:b", "manager should remember the preview placement")
  assert_eq(manager.by_node_id["node:b"].preview_render_key, "preview:node:b", "placement should own preview key")
  assert_eq(manager.by_node_id["node:a"].preview_render_key, nil, "unrelated placement should not enter preview")

  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  manager:sync_cursor_preview()
  assert_eq(clear_calls, 1, "leaving formula placement should clear only the active preview")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_machine_runtime_scroll_refresh_reuploads_blocks_only()
  local state = fresh_state()
  local runtime = require("typst-concealer.machine.runtime")
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, "block-scroll-refresh.typ")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "$ x $", "$y$" })
  package.loaded["typst-concealer"] = {
    _enabled_buffers = { [bufnr] = true },
    is_render_allowed = function()
      return true
    end,
    config = {
      conceal_in_normal = false,
    },
  }

  state.machine_state.buffers[bufnr] = {
    bufnr = bufnr,
    project_scope_id = "p",
    buffer_version = 1,
    layout_version = 80,
    nodes = {
      ["node:block"] = {
        node_id = "node:block",
        bufnr = bufnr,
        project_scope_id = "p",
        item_idx = 1,
        node_type = "math",
        source_range = { 0, 0, 0, 5 },
        display_range = { 0, 0, 0, 5 },
        source_text = "$ x $",
        prelude_count = 0,
        semantics = { display_kind = "block", constraint_kind = "intrinsic" },
        status = "stable",
        visible_overlay_id = "overlay:block",
      },
      ["node:inline"] = {
        node_id = "node:inline",
        bufnr = bufnr,
        project_scope_id = "p",
        item_idx = 2,
        node_type = "math",
        source_range = { 1, 0, 1, 3 },
        display_range = { 1, 0, 1, 3 },
        source_text = "$y$",
        prelude_count = 0,
        semantics = { display_kind = "inline", constraint_kind = "intrinsic" },
        status = "stable",
        visible_overlay_id = "overlay:inline",
      },
    },
    node_order = { "node:block", "node:inline" },
  }
  state.machine_state.overlays["overlay:block"] = {
    overlay_id = "overlay:block",
    owner_node_id = "node:block",
    owner_bufnr = bufnr,
    owner_project_scope_id = "p",
    request_id = "request:1",
    image_id = 1600,
    extmark_id = 1700,
    page_path = "/tmp/block-scroll-refresh.png",
    page_stamp = "stamp:block",
    natural_cols = 2,
    natural_rows = 1,
    source_rows = 1,
    status = "visible",
    buffer_version = 1,
    layout_version = 80,
  }
  state.machine_state.overlays["overlay:inline"] = {
    overlay_id = "overlay:inline",
    owner_node_id = "node:inline",
    owner_bufnr = bufnr,
    owner_project_scope_id = "p",
    request_id = "request:1",
    image_id = 1601,
    extmark_id = 1701,
    page_path = "/tmp/inline-scroll-refresh.png",
    page_stamp = "stamp:inline",
    natural_cols = 1,
    natural_rows = 1,
    source_rows = 1,
    status = "visible",
    buffer_version = 1,
    layout_version = 80,
  }

  with_stubbed_extmark(function(calls)
    runtime.refresh_visible_overlays(bufnr, { margin = 0 })
    assert_eq(#calls.created, 2, "first visible refresh uploads both visible images")
    assert_eq(calls.flushed, 1, "initial visible refresh should flush uploaded images")

    runtime.refresh_visible_overlays(bufnr, { margin = 0, force_reupload_blocks = true })
    assert_eq(#calls.created, 3, "scroll refresh should reupload the block image")
    assert_eq(calls.flushed, 2, "scroll refresh should flush reuploaded block images")
    assert_eq(calls.created[3].image_id, 1600, "scroll refresh should not reupload unchanged inline images")

    runtime.refresh_visible_overlays(bufnr, { margin = 0, skip_blocks = true })
    assert_eq(#calls.created, 3, "cursor refresh should not reupload skipped block images")
    assert_eq(calls.flushed, 2, "cursor refresh should not flush when no images were uploaded")
    assert_eq(#calls.swapped, 5, "cursor refresh should only rebind the inline image")
    assert_eq(calls.swapped[5].image_id, 1601, "cursor refresh should skip block extmark rebuilds")
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

local function test_machine_resources_share_apply_allocation_pool()
  local state = fresh_state()
  state.pid = 700
  local resources = require("typst-concealer.machine.resources")
  local image_id = resources.allocate_image_id(1)
  assert_eq(image_id, 700, "machine resources should allocate from state pid")
  assert_eq(state.image_ids_in_use[image_id], 1, "machine allocation should reserve the image id")

  local apply = require("typst-concealer.apply")
  local apply_image_id = apply._new_image_id(2)
  assert_eq(apply_image_id, 701, "apply allocation should share the machine resource pool")
  assert_eq(state.image_ids_in_use[apply_image_id], 2, "apply allocation should reserve through resources")

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

local tests = {
  { test_supports_typst_and_markdown_buffers, "ok typst and markdown buffers are supported" },
  { test_custom_markdown_filetypes_are_supported, "ok custom markdown filetypes are supported" },
  { test_latex_buffers_require_enabled_backend, "ok latex buffers require enabled backend" },
  { test_latex_wrapper_applies_configured_color_to_math_modes, "ok latex wrapper applies color to math modes" },
  {
    test_latex_scope_uses_empty_preamble_without_document_boundary,
    "ok latex body-only files use empty preamble",
  },
  { test_markdown_adapter_collects_inline_and_block_math, "ok markdown adapter collects math" },
  { test_latex_adapter_collects_top_level_math, "ok latex adapter collects top-level math" },
  {
    test_latex_adapter_collects_buffer_independent_of_viewport,
    "ok latex adapter scans buffer independently of render coverage",
  },
  { test_viewport_change_tracking_is_adapter_scoped, "ok viewport change tracking is adapter scoped" },
  { test_render_buf_scans_markdown_math_nodes, "ok render_buf scans markdown math nodes" },
  { test_render_buf_scans_latex_math_nodes, "ok render_buf scans latex math nodes" },
  {
    test_render_buf_routes_latex_scan_through_formula_manager,
    "ok render_buf routes latex scans through formula manager",
  },
  { test_vim_resized_renders_on_column_change, "ok VimResized renders on column change" },
  { test_root_prefers_cwd_fallback, "ok root fallback uses cwd" },
  { test_get_root_overrides_fallback, "ok get_root overrides root base" },
  { test_service_cleanup_removes_latex_work_directories, "ok service cleanup removes latex work dirs" },
  { test_session_render_request_tracks_active_service_request, "ok session tracks machine render requests" },
  { test_session_render_request_via_service_writes_json, "ok session writes compiler service requests" },
  { test_latex_service_request_writes_backend_json, "ok session writes latex backend requests" },
  {
    test_latex_preview_uses_preview_service_and_accepts_formula_response,
    "ok latex preview uses preview service",
  },
  { test_service_validates_page_contract, "ok service validates page contract" },
  { test_service_success_clears_active_meta, "ok service success clears active meta" },
  { test_formula_service_success_routes_by_node_revision, "ok formula service routes by node revision" },
  {
    test_formula_transport_batch_does_not_install_buffer_active_request,
    "ok formula transport batch does not install buffer active request",
  },
  {
    test_formula_transport_prunes_superseded_queued_batches,
    "ok formula transport prunes superseded queued batches",
  },
  {
    test_formula_transport_stale_response_reschedules_pending_node,
    "ok formula transport stale responses converge pending nodes",
  },
  {
    test_formula_manager_self_check_reschedules_lost_candidate,
    "ok formula manager self-check reschedules lost candidates",
  },
  { test_formula_service_stale_node_revision_is_discarded, "ok formula service discards stale node revision" },
  { test_formula_diagnostics_replace_per_node, "ok formula diagnostics replace per node" },
  {
    _G.test_service_error_diagnostics_clear_candidate_placeholder,
    "ok service error diagnostics clear candidate placeholder",
  },
  {
    test_service_one_dirty_slot_keeps_full_shape_and_commits_once,
    "ok service one dirty slot keeps full shape and commits once",
  },
  { test_service_ignores_context_leading_pages, "ok service ignores context leading pages" },
  { test_service_stale_response_cleans_candidates, "ok service stale responses clean candidates" },
  { test_service_write_failure_cleans_active_request, "ok service write failure cleans active request" },
  { test_service_exit_cleans_active_request, "ok service exit cleans active request" },
  { test_service_spawn_failure_cleans_candidate, "ok service spawn failure cleans candidate" },
  { test_service_diagnostics_mapping, "ok service diagnostics mapping" },
  { test_preview_service_routing_and_stale_cleanup, "ok preview service routing and stale cleanup" },
  { test_preview_service_uses_last_page_after_context, "ok preview service uses last page after context" },
  {
    test_live_preview_keeps_old_highlight_until_replacement_commits,
    "ok live preview keeps old highlight until replacement commits",
  },
  {
    test_preview_cleanup_reattaches_only_source_item,
    "ok preview cleanup reattaches only source item",
  },
  { test_service_artifact_cleanup_preserves_live_paths, "ok service artifact cleanup preserves live paths" },
  { test_wrapper_cache_tracks_root_signature, "ok wrapper cache keys include root signature" },
  { test_inline_wrapper_keeps_single_row_width_intrinsic, "ok inline wrapper keeps single-row width intrinsic" },
  { test_wrapper_defaults_missing_semantics_to_inline, "ok wrapper defaults missing semantics to inline" },
  { test_wrapper_imports_mitex_for_markdown_items, "ok wrapper imports MiTeX for markdown items" },
  { test_remote_urls_do_not_rewrite_against_root, "ok remote urls bypass root rewrite" },
  { test_named_path_args_rewrite_local_paths, "ok named path args rewrite local paths" },
  { test_named_path_args_preserve_remote_urls, "ok named path args preserve remote urls" },
  {
    test_machine_reducer_enforces_request_identity_and_delayed_retire,
    "ok machine reducer enforces request identity and delayed retire",
  },
  {
    test_machine_reducer_rebinds_stable_visible_overlay_on_precise_dirty_range,
    "ok machine reducer rebinds stable visible overlays on precise dirty ranges",
  },
  {
    test_machine_reducer_rebinds_when_dirty_range_hits_old_binding_after_shift,
    "ok machine reducer rebinds visible overlays when old binding range is dirtied after shift",
  },
  {
    test_machine_reducer_rebinds_visible_overlay_after_shift_even_if_binding_was_reconciled,
    "ok machine reducer rebinds shifted visible overlays even after binding reconcile",
  },
  {
    test_machine_reducer_rebinds_when_reconciled_binding_disagrees_with_scan,
    "ok machine reducer rebinds visible overlays when reconciled binding disagrees with scan",
  },
  {
    test_machine_reducer_does_not_rebind_stable_overlay_for_disjoint_dirty_range,
    "ok machine reducer skips disjoint display binding changes",
  },
  {
    test_machine_reducer_retires_deleted_only_formula_on_render_boundary,
    "ok machine reducer retires deleted only formula on render boundary",
  },
  {
    test_machine_reducer_keeps_overlapping_orphan_until_replacement_commit,
    "ok machine reducer keeps overlapping orphan until replacement commit",
  },
  {
    test_machine_reducer_reuses_range_identity_without_stable_key,
    "ok machine reducer reuses range identity without stable key",
  },
  { test_machine_reducer_identity_adjacent_formula_edit, "ok machine reducer identity adjacent formula edit" },
  {
    test_machine_reducer_identity_deletion_with_upward_shift,
    "ok machine reducer identity deletion with upward shift",
  },
  {
    test_machine_reducer_identity_insertion_between_formulas,
    "ok machine reducer identity insertion between formulas",
  },
  {
    test_machine_reducer_identity_repeated_identical_formulas,
    "ok machine reducer identity repeated identical formulas",
  },
  {
    test_machine_reducer_identity_repeated_identical_formulas_shift_down_together,
    "ok machine reducer identity repeated identical formulas shift down together",
  },
  {
    test_machine_reducer_stable_slots_include_clean_pages_for_one_dirty_node,
    "ok machine reducer stable slots include clean pages for one dirty node",
  },
  {
    test_machine_reducer_stable_slots_append_insertions_without_shifting_pages,
    "ok machine reducer stable slots append insertions without shifting pages",
  },
  {
    test_machine_reducer_stable_slots_tombstone_deletions_without_shifting_pages,
    "ok machine reducer stable slots tombstone deletions without shifting pages",
  },
  {
    test_machine_reducer_retires_overlapping_orphans_after_commit,
    "ok machine reducer retires overlapping orphans after commit",
  },
  {
    test_machine_reducer_cleans_orphans_covered_by_visible_nodes,
    "ok machine reducer cleans orphans covered by visible nodes",
  },
  { test_machine_reducer_abandons_idle_request_candidates, "ok machine reducer abandons idle request candidates" },
  {
    test_machine_reducer_failed_request_cleans_candidates_and_active_id,
    "ok machine reducer failed request cleans candidates",
  },
  {
    test_machine_reducer_formula_batch_keeps_node_request_state_independent,
    "ok machine reducer formula batch keeps node state independent",
  },
  {
    test_machine_reducer_formula_batch_respects_requested_node_order,
    "ok machine reducer formula batch respects requested node order",
  },
  {
    test_formula_manager_render_queue_uses_coverage_priority,
    "ok formula manager render queue uses coverage priority",
  },
  {
    test_machine_reducer_scan_retires_cleared_formula_candidates,
    "ok machine reducer scan retires cleared formula candidates",
  },
  {
    test_machine_reducer_keeps_identical_pending_formula_candidate,
    "ok machine reducer keeps identical pending formula candidates",
  },
  {
    test_machine_reducer_flow_nodes_rerender_when_layout_changes,
    "ok machine reducer flow nodes rerender when layout changes",
  },
  {
    test_machine_reducer_layout_change_rebinds_without_formula_rerender,
    "ok machine reducer layout change rebinds without formula rerender",
  },
  { test_machine_runtime_rebuilds_compat_read_model, "ok machine runtime rebuilds compat read model" },
  {
    test_machine_runtime_rebinds_overlay_without_terminal_image_refresh,
    "ok machine runtime rebinds overlays without terminal image refresh",
  },
  {
    test_machine_runtime_places_cursor_overlay_unconcealed,
    "ok machine runtime keeps cursor overlay placeholders unconcealed",
  },
  { _G.__typst_concealer_regression_tests },
  { test_extmark_conceal_preserves_source_under_cursor, "ok extmark conceal keeps cursor source visible" },
  {
    test_extmark_collapses_wrapping_single_line_block_source,
    "ok extmark collapses wrapping single-line block source",
  },
  {
    test_extmark_embedded_block_math_uses_display_composer,
    "ok extmark embedded block math uses display composer",
  },
  {
    test_extmark_embedded_block_math_avoids_inline_source_anchor,
    "ok extmark embedded block math avoids inline source anchors",
  },
  {
    test_extmark_multiline_block_uses_line_run_lifecycle,
    "ok extmark multiline block uses line-run lifecycle",
  },
  {
    test_extmark_nonblock_multiline_uses_line_run_lifecycle,
    "ok extmark non-block multiline uses line-run lifecycle",
  },
  {
    test_extmark_line_run_progressively_expands_active_block,
    "ok extmark line-run progressively expands active block",
  },
  {
    test_extmark_line_run_clear_invalidates_hover_guard,
    "ok extmark line-run clear invalidates hover guard",
  },
  {
    test_state_prepare_extmark_reuse_invalidates_hover_guard_for_line_run,
    "ok state prepares line-run reuse with hover invalidation",
  },
  {
    test_extmark_resync_repairs_restored_block_with_occupied_boundary_anchors,
    "ok extmark cursor resync repairs restored block with occupied anchors",
  },
  {
    test_extmark_scales_wide_block_images_to_window_width,
    "ok extmark scales wide block images to window width",
  },
  {
    test_display_line_chunks_preserve_native_ui,
    "ok display line chunks preserve native UI",
  },
  {
    test_display_line_chunks_preserve_treesitter_conceal,
    "ok display line chunks preserve tree-sitter conceal",
  },
  {
    test_display_line_chunks_preserve_neovim_highlight_stack,
    "ok display line chunks preserve Neovim highlight stack",
  },
  {
    test_display_line_chunks_accept_math_conceal_provider,
    "ok display line chunks accept math-conceal provider",
  },
  {
    test_extmark_compacts_inline_images_by_display_width,
    "ok extmark compacts inline images by display width",
  },
  {
    test_extmark_inline_math_carrier_reuses_display_composer,
    "ok extmark inline math carrier reuses display composer",
  },
  {
    test_extmark_inline_carrier_replays_native_ui,
    "ok extmark inline carrier replays native UI",
  },
  {
    test_extmark_inline_carrier_does_not_anchor_across_block_conceal,
    "ok extmark inline carriers do not anchor across blocks",
  },
  {
    test_extmark_compact_inline_image_chunks_wrap,
    "ok extmark compact inline image chunks wrap",
  },
  {
    test_extmark_inline_compact_carrier_follows_cursor_row,
    "ok extmark inline compact carrier follows cursor row",
  },
  {
    test_extmark_clears_shifted_inline_compact_carriers,
    "ok extmark clears shifted inline compact carriers",
  },
  {
    test_cursor_visibility_preserves_insert_math_after_stale_range,
    "ok cursor visibility keeps edited insert math source visible",
  },
  {
    test_cursor_visibility_does_not_expand_to_adjacent_formula,
    "ok cursor visibility does not expand across adjacent formulas",
  },
  {
    test_cursor_visibility_inline_code_only_expands_inside_range,
    "ok cursor visibility expands inline code only inside its range",
  },
  { test_machine_runtime_builds_service_render_job, "ok machine runtime builds service render job" },
  { test_machine_runtime_resets_buffer_snapshot, "ok machine runtime resets buffer snapshot" },
  { test_machine_runtime_retire_removes_overlay_entry, "ok machine runtime retire removes overlay entry" },
  {
    test_machine_runtime_reset_buffer_releases_candidate_resources,
    "ok machine runtime reset releases candidate resources",
  },
  { test_machine_runtime_tracks_ui_state, "ok machine runtime tracks ui state" },
  {
    test_machine_runtime_cursor_sync_renders_preview,
    "ok machine runtime cursor sync renders preview",
  },
  {
    test_machine_runtime_cursor_sync_routes_latex_to_formula_manager,
    "ok machine runtime routes latex cursor sync through formula manager",
  },
  {
    test_machine_runtime_reconciles_visible_overlay_binding_from_extmark,
    "ok machine runtime reconciles visible overlay bindings from extmarks",
  },
  {
    test_machine_runtime_refreshes_visible_overlays_without_render_request,
    "ok machine runtime refreshes visible overlays without render requests",
  },
  {
    test_formula_manager_tracks_placement_indexes_and_read_model,
    "ok formula manager tracks placement indexes and read model",
  },
  {
    test_formula_placement_show_clears_hidden_before_conceal,
    "ok formula placement restores hidden image before conceal",
  },
  {
    test_formula_cursor_fast_boundary_switch_only_touches_previous_and_current,
    "ok formula cursor boundary switches stay placement-local",
  },
  {
    test_formula_cursor_preview_targets_single_placement,
    "ok formula cursor preview targets one placement",
  },
  {
    test_machine_runtime_scroll_refresh_reuploads_blocks_only,
    "ok machine runtime scroll refresh reuploads blocks only",
  },
  { test_machine_resources_share_apply_allocation_pool, "ok machine resources share apply allocation pool" },
  { test_commit_plan_reuses_stable_render_for_same_source, "ok commit_plan reuses same-source stable renders" },
  { test_commit_plan_does_not_reuse_render_for_changed_source, "ok commit_plan rejects changed-source stale renders" },
  { test_commit_plan_cleans_removed_items_immediately, "ok commit_plan cleans removed items immediately" },
}

local function main()
  for _, test in ipairs(tests) do
    test[1]()
    if test[2] then
      ok(test[2])
    end
  end
  vim.cmd("qa!")
end

main()
