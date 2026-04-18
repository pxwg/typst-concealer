--- Benchmark: compiler service vs typst watch render latency.
---
--- Usage (from within a Neovim instance with typst-concealer loaded):
---   :luafile tests/bench_service.lua
---
--- Or from the CLI against a running Neovim:
---   nvim --server <socket> --remote-expr 'luaeval("dofile(\"tests/bench_service.lua\")")'

local state = require("typst-concealer.state")
local session = require("typst-concealer.session")
local runtime = require("typst-concealer.machine.runtime")
local main = require("typst-concealer")

local bufnr = vim.api.nvim_get_current_buf()

local function fmt_us(us)
  if us == nil then
    return "N/A"
  end
  if us >= 1000000 then
    return string.format("%.1fs", us / 1000000)
  elseif us >= 1000 then
    return string.format("%.1fms", us / 1000)
  end
  return string.format("%dμs", us)
end

-- Print last service benchmark data if available.
local function print_service_bench()
  local b = state._last_service_bench
  if b == nil then
    print("[bench] No service benchmark data yet. Trigger a render first.")
    return
  end

  local roundtrip_us = nil
  if b.request_sent_at and b.response_at then
    roundtrip_us = math.floor((b.response_at - b.request_sent_at) / 1000)
  end

  local lines = {
    "╔══════════════════════════════════════════════════════════╗",
    "║         typst-concealer-service benchmark               ║",
    "╠══════════════════════════════════════════════════════════╣",
    string.format("║  request_id:     %-38s ║", b.request_id or "?"),
    string.format("║  total pages:    %-38d ║", b.total_pages or 0),
    string.format("║  rendered pages: %-38s ║", tostring(b.rendered_pages or "?")),
    string.format("║  cached skipped: %-38d ║", b.skipped_cached or 0),
    string.format("║  dispatched:     %-38d ║", b.dispatched or 0),
    "╠══════════════════════════════════════════════════════════╣",
    string.format("║  [Rust] compile:     %-34s ║", fmt_us(b.compile_us)),
    string.format("║  [Rust] render:      %-34s ║", fmt_us(b.render_us)),
    string.format("║  [Lua]  dispatch:    %-34s ║", fmt_us(b.lua_dispatch_us)),
    string.format("║  [E2E]  roundtrip:   %-34s ║", fmt_us(roundtrip_us)),
    "╚══════════════════════════════════════════════════════════╝",
  }
  for _, l in ipairs(lines) do
    print(l)
  end
end

-- Print last watch benchmark data if available.
local function print_watch_bench()
  local b = state._last_watch_bench
  if b == nil then
    print("[bench] No watch benchmark data yet. Switch to watch mode and trigger a render.")
    return
  end

  local lines = {
    "╔══════════════════════════════════════════════════════════╗",
    "║         typst watch benchmark                           ║",
    "╠══════════════════════════════════════════════════════════╣",
    string.format("║  page index:     %-38d ║", b.page_index or 0),
    string.format("║  poll cycles:    %-38d ║", b.poll_cycles or 0),
    "╠══════════════════════════════════════════════════════════╣",
    string.format("║  [Watch] file→stable: %-33s ║", fmt_us(b.file_stable_us)),
    string.format("║  [Lua]   dispatch:    %-33s ║", fmt_us(b.lua_dispatch_us)),
    string.format("║  [E2E]   roundtrip:   %-33s ║", fmt_us(b.roundtrip_us)),
    "╚══════════════════════════════════════════════════════════╝",
  }
  for _, l in ipairs(lines) do
    print(l)
  end
end

-- Run a quick N-iteration micro-benchmark by programmatically editing
-- the buffer and measuring compile roundtrip each time.
local function run_bench(n)
  n = n or 5

  if not main.config.use_compiler_service then
    print("[bench] This benchmark requires use_compiler_service = true")
    return
  end

  print(string.format("[bench] Running %d iterations on buf %d ...", n, bufnr))

  -- Find the last math node in the buffer.
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- We'll append/remove a trailing space in a math formula to trigger re-render.
  local target_line = nil
  for i = line_count, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if text:match("^%$") or text:match("%$%s*$") then
      target_line = i
      break
    end
  end

  if target_line == nil then
    print("[bench] No math formula found in buffer")
    return
  end

  local results = {}

  for iter = 1, n do
    -- Toggle a trailing space to force a change
    local lines = vim.api.nvim_buf_get_lines(bufnr, target_line - 1, target_line, false)
    local text = lines[1] or ""
    if text:sub(-1) == " " then
      vim.api.nvim_buf_set_lines(bufnr, target_line - 1, target_line, false, { text:sub(1, -2) })
    else
      vim.api.nvim_buf_set_lines(bufnr, target_line - 1, target_line, false, { text .. " " })
    end

    -- Trigger render
    state._last_service_bench = nil
    local t0 = vim.uv.hrtime()
    runtime.render_buf(bufnr)

    -- Wait for response (busy-poll via vim.wait, up to 10s)
    vim.wait(10000, function()
      return state._last_service_bench ~= nil
    end, 10)

    local t1 = vim.uv.hrtime()
    local b = state._last_service_bench

    if b then
      local wall_us = math.floor((t1 - t0) / 1000)
      results[#results + 1] = {
        wall_us = wall_us,
        compile_us = b.compile_us or 0,
        render_us = b.render_us or 0,
        lua_dispatch_us = b.lua_dispatch_us or 0,
        rendered_pages = b.rendered_pages or 0,
        total_pages = b.total_pages or 0,
      }
    else
      print(string.format("  iter %d: TIMEOUT", iter))
    end
  end

  if #results == 0 then
    print("[bench] No results collected.")
    return
  end

  -- Compute stats
  local sum = { wall = 0, compile = 0, render = 0, lua = 0 }
  for _, r in ipairs(results) do
    sum.wall = sum.wall + r.wall_us
    sum.compile = sum.compile + r.compile_us
    sum.render = sum.render + r.render_us
    sum.lua = sum.lua + r.lua_dispatch_us
  end

  local nn = #results
  print("")
  print(
    "╔══════════════════════════════════════════════════════════╗"
  )
  print("║         Service Benchmark Results                       ║")
  print(
    "╠══════════════════════════════════════════════════════════╣"
  )
  print(string.format("║  iterations:     %-38d ║", nn))
  print(string.format("║  total pages:    %-38d ║", results[1].total_pages))
  print(string.format("║  rendered/iter:  %-38d ║", results[nn].rendered_pages))
  print(
    "╠══════════════════════════════════════════════════════════╣"
  )
  print(string.format("║  avg wall time:    %-36s ║", fmt_us(sum.wall / nn)))
  print(string.format("║  avg compile:      %-36s ║", fmt_us(sum.compile / nn)))
  print(string.format("║  avg render:       %-36s ║", fmt_us(sum.render / nn)))
  print(string.format("║  avg lua dispatch: %-36s ║", fmt_us(sum.lua / nn)))
  print(string.format("║  avg overhead:     %-36s ║", fmt_us((sum.wall - sum.compile - sum.render) / nn)))
  print(
    "╠══════════════════════════════════════════════════════════╣"
  )

  -- Per-iteration details
  for i, r in ipairs(results) do
    print(
      string.format(
        "║  [%d] wall=%s compile=%s render=%s lua=%s  ║",
        i,
        fmt_us(r.wall_us),
        fmt_us(r.compile_us),
        fmt_us(r.render_us),
        fmt_us(r.lua_dispatch_us)
      )
    )
  end
  print(
    "╚══════════════════════════════════════════════════════════╝"
  )
end

-- Export for interactive use
_G.typst_bench = {
  service = print_service_bench,
  watch = print_watch_bench,
  run = run_bench,
}

print("[bench] Loaded. Commands:")
print("  :lua typst_bench.service()    -- show last service timing")
print("  :lua typst_bench.run(5)       -- run 5-iteration benchmark")
return true
