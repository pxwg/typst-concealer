--- Typst document wrapper construction for typst-concealer.
--- Builds the Typst source that wraps each snippet so it renders at the correct
--- cell-grid dimensions.
---
--- TypstBackend interface (current: Typst only)
---   M.build_batch_document(items) -> string    assembled multi-page Typst source
---   M.build_wrapper(item, source_rows)         per-item wrapper dispatch
---   M.make_inline_sizing_wrap(source_rows)     intrinsic-constraint wrapper
---   M.make_flow_block_wrap(bufnr)              flow-constraint wrapper
---                                              (page width = available cols, no terminal padding)
local state = require("typst-concealer.state")
local M = {}

--- @param s string
--- @return integer
local function count_lines(s)
  if s == "" then
    return 0
  end
  local _, n = s:gsub("\n", "\n")
  if s:sub(-1) ~= "\n" then
    n = n + 1
  end
  return n
end

--- @param parts string[]
--- @param s string
--- @param cur_line integer
--- @return integer
local function push(parts, s, cur_line)
  parts[#parts + 1] = s
  return cur_line + count_lines(s)
end

--- Advance a 1-based (line, col) cursor through string s.
--- Column is also 1-based and points to the next character position.
--- @param s string
--- @param line integer
--- @param col integer
--- @return integer, integer
local function advance_pos(s, line, col)
  if s == "" then
    return line, col
  end

  local idx = 1
  while true do
    local nl = s:find("\n", idx, true)
    if nl == nil then
      return line, col + (#s - idx + 1)
    end
    line = line + 1
    col = 1
    idx = nl + 1
  end
end

--- @param item table
--- @return string
local function normalize_item_str(item)
  if type(item.str) == "table" then
    return table.concat(item.str)
  end
  return item.str
end

--- Returns the column width of the window displaying bufnr (falls back to current window).
--- @param bufnr integer
--- @return integer
local function get_win_cols(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  return vim.api.nvim_win_get_width(winid ~= -1 and winid or 0)
end

--- Returns available window width in Typst points.
--- Typst page width = 可用宽度（不含终端 padding）; terminal padding is added by extmark layer.
--- @param bufnr integer
--- @return number
local function current_window_width_pt(bufnr)
  local config = require("typst-concealer").config
  local baseline_pt = config.math_baseline_pt or 11
  local pad_cols = config.block_padding_cols or 4
  local win_cols = get_win_cols(bufnr)
  local usable_cols = math.max(8, win_cols - 2 * pad_cols)
  if state._cell_px_w and state._cell_px_h then
    local cell_w_pt = baseline_pt * (state._cell_px_w / state._cell_px_h)
    return usable_cols * cell_w_pt
  end
  local approx_cell_w_pt = baseline_pt * 0.55
  return usable_cols * approx_cell_w_pt
end

--- Inline/intrinsic sizing wrapper: fits content to an exact terminal cell grid.
--- @param source_rows integer
--- @return string prefix, string suffix   both "" when cell size is unknown
function M.make_inline_sizing_wrap(source_rows)
  local config = require("typst-concealer").config
  if state._cell_px_h and state._cell_px_w then
    local baseline_pt = config.math_baseline_pt
    local cell_w_pt = baseline_pt * (state._cell_px_w / state._cell_px_h)
    if source_rows == 1 then
      return "#context { let __it = [",
        string.format(
          "]; let __d = measure(__it); let __mh = %gpt; let __mw = %gpt;"
            .. " let __rows = __d.height / __mh;"
            .. " let __cols = calc.max(1, calc.ceil(__d.width / __mw - 0.001));"
            .. " let __tw = __cols * __mw;"
            .. " if __rows <= 1.5 { block(width: __tw, height: __mh, clip: true, align(horizon, __it)) }"
            .. " else { let __r = calc.max(1, calc.ceil(__rows - 0.001));"
            .. " block(width: __tw, height: __r * __mh, align(horizon, __it)) } }\n",
          baseline_pt,
          cell_w_pt
        )
    else
      return "#context { let __it = [",
        string.format(
          "]; let __d = measure(__it); let __mh = %gpt; let __mw = %gpt;"
            .. " let __rows = calc.max(1, calc.ceil(__d.height / __mh - 0.001));"
            .. " let __cols = calc.max(1, calc.ceil(__d.width / __mw - 0.001));"
            .. " let __th = __rows * __mh; let __tw = __cols * __mw;"
            .. " block(width: __tw, height: __th, align(horizon, __it)) }\n",
          baseline_pt,
          cell_w_pt
        )
    end
  elseif state._cell_px_h then
    local baseline_pt = config.math_baseline_pt
    if source_rows == 1 then
      return "#context { let __it = [",
        string.format(
          "]; let __d = measure(__it); let __mh = %gpt;"
            .. " let __rows = __d.height / __mh;"
            .. " if __rows <= 1.5 { block(width: __d.width, height: __mh, clip: true, align(horizon, __it)) }"
            .. " else { let __r = calc.max(1, calc.ceil(__rows - 0.001));"
            .. " block(width: __d.width, height: __r * __mh, align(horizon, __it)) } }\n",
          baseline_pt
        )
    else
      return "#context { let __it = [",
        string.format(
          "]; let __d = measure(__it); let __mh = %gpt;"
            .. " let __rows = calc.max(1, calc.ceil(__d.height / __mh - 0.001));"
            .. " let __th = __rows * __mh;"
            .. " block(width: __d.width, height: __th, align(horizon, __it)) }\n",
          baseline_pt
        )
    end
  end
  return "", ""
end

--- Flow-block wrapper: Typst page width = available column width (no terminal padding).
--- Terminal display padding (block_padding_cols) is added separately in the extmark layer.
--- block_preview_margin_pt is Typst-side inset inside the rendered image (orthogonal to terminal padding).
--- @param bufnr integer
--- @return string prefix, string suffix
function M.make_flow_block_wrap(bufnr)
  local config = require("typst-concealer").config
  local page_w_pt = current_window_width_pt(bufnr)
  local margin_pt = config.block_preview_margin_pt or 0
  return string.format(
    "#context {\n"
      .. "  set page(width: %gpt, height: auto, margin: (x: 0pt, y: 0pt), fill: none)\n"
      .. "  block(width: 100%%, inset: (x: %gpt, y: 0pt))[\n",
    page_w_pt,
    margin_pt
  ),
    "  ]\n}\n"
end

--- Wrapper dispatch: wrapper choice comes only from semantics.constraint_kind.
--- @param item table  item with semantics field
--- @param source_rows integer
--- @return string prefix, string suffix
function M.build_wrapper(item, source_rows)
  if item.semantics.constraint_kind == "flow" then
    return M.make_flow_block_wrap(item.bufnr)
  else
    return M.make_inline_sizing_wrap(source_rows)
  end
end

--- Build multi-page Typst source for a batch render session.
--- @param items table[]
--- @param buf_dir string|nil   source buffer directory (for path rewriting)
--- @param source_root string|nil  source/project root used for `/...` semantics
--- @param effective_root string|nil  actual Typst `--root` used by the watch session
--- @param kind "full"|"preview"|nil  session kind forwarded to get_preamble_file
--- @return string, table
function M.build_batch_document(items, buf_dir, source_root, effective_root, kind)
  local main = require("typst-concealer")
  local config = main.config
  local doc = {}
  local line_map = {}
  local cur_line = 1
  local cur_col = 1
  local rep_bufnr = (items[1] and items[1].bufnr) or 0

  local do_rewrite = buf_dir ~= nil and source_root ~= nil and effective_root ~= nil
  local pr = do_rewrite and require("typst-concealer.path-rewrite") or nil
  local function maybe_rewrite(text)
    if pr == nil then
      return text
    end
    return pr.rewrite_paths(text, {
      bufnr = rep_bufnr,
      buf_dir = buf_dir,
      source_root = source_root,
      effective_root = effective_root,
    })
  end
  local function append_chunk(chunk)
    doc[#doc + 1] = chunk
    cur_line, cur_col = advance_pos(chunk, cur_line, cur_col)
  end

  if config.header and config.header ~= "" then
    append_chunk(maybe_rewrite(config.header) .. "\n")
  end

  append_chunk(main._styling_prelude)

  -- Inject project-level context via get_preamble_file.
  -- The returned filesystem path is converted to a Typst root-relative path so
  -- that `#include` resolves correctly regardless of where the temp file lives.
  if type(config.get_preamble_file) == "function" and pr ~= nil then
    local buf_path_for_pf = (items[1] and vim.api.nvim_buf_get_name(items[1].bufnr)) or ""
    local cwd_for_pf = vim.fn.getcwd()
    local ok, pf = pcall(config.get_preamble_file, rep_bufnr, buf_path_for_pf, cwd_for_pf, kind or "full")
    if ok and type(pf) == "string" and pf ~= "" then
      local abs = vim.fs.normalize(vim.fn.fnamemodify(pf, ":p")):gsub("/$", "")
      local typst_path = pr.encode_root_relative(abs, effective_root)
      append_chunk('#include "' .. typst_path .. '"\n')
    end
  end

  for idx, item in ipairs(items) do
    if idx > 1 then
      append_chunk("#pagebreak()\n")
    end

    for i = 1, item.prelude_count do
      append_chunk(maybe_rewrite(state.runtime_preludes[i]))
    end

    local source_rows = item.range[3] - item.range[1] + 1
    local wrap_prefix, wrap_suffix = M.build_wrapper(item, source_rows)

    if wrap_prefix ~= "" then
      append_chunk(wrap_prefix)
    end

    local item_text = maybe_rewrite(normalize_item_str(item))
    local gen_start = cur_line
    local gen_start_col = cur_col
    local gen_end_line, gen_end_col_next = advance_pos(item_text, gen_start, gen_start_col)
    local gen_end = gen_end_line
    append_chunk(item_text)

    local src_start_col = item.range[2] + 1
    local src_end_col = item.range[4] + 1
    local gen_end_col = math.max(1, gen_end_col_next - 1)

    line_map[#line_map + 1] = {
      gen_start = gen_start,
      gen_end = gen_end,
      gen_start_col = gen_start_col,
      gen_end_col = gen_end_col,
      bufnr = item.bufnr,
      src_start = item.range[1] + 1,
      src_end = item.range[3] + 1,
      src_start_col = src_start_col,
      src_end_col = src_end_col,
      item_idx = idx,
    }

    if wrap_suffix ~= "" then
      append_chunk(wrap_suffix)
    else
      append_chunk("\n")
    end
  end

  return table.concat(doc), line_map
end

return M
