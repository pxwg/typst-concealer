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
--- @param project_root string|nil  project root (for path rewriting)
--- @return string, table
function M.build_batch_document(items, buf_dir, project_root)
  local main = require("typst-concealer")
  local config = main.config
  local doc = {}
  local line_map = {}
  local cur_line = 1

  local do_rewrite = buf_dir ~= nil and project_root ~= nil
  local pr = do_rewrite and require("typst-concealer.path-rewrite") or nil
  local function maybe_rewrite(text)
    return pr and pr.rewrite_paths(text, buf_dir, project_root) or text
  end

  if config.header and config.header ~= "" then
    cur_line = push(doc, maybe_rewrite(config.header) .. "\n", cur_line)
  end

  cur_line = push(doc, main._styling_prelude, cur_line)

  for idx, item in ipairs(items) do
    if idx > 1 then
      cur_line = push(doc, "#pagebreak()\n", cur_line)
    end

    for i = 1, item.prelude_count do
      cur_line = push(doc, maybe_rewrite(state.runtime_preludes[i]), cur_line)
    end

    local source_rows = item.range[3] - item.range[1] + 1
    local wrap_prefix, wrap_suffix = M.build_wrapper(item, source_rows)

    if wrap_prefix ~= "" then
      cur_line = push(doc, wrap_prefix, cur_line)
    end

    local item_text = maybe_rewrite(normalize_item_str(item))
    local gen_start = cur_line
    cur_line = push(doc, item_text, cur_line)
    local gen_end = cur_line - 1

    line_map[#line_map + 1] = {
      gen_start = gen_start,
      gen_end = gen_end,
      bufnr = item.bufnr,
      src_start = item.range[1] + 1,
      src_end = item.range[3] + 1,
      item_idx = idx,
    }

    if wrap_suffix ~= "" then
      cur_line = push(doc, wrap_suffix, cur_line)
    else
      cur_line = push(doc, "\n", cur_line)
    end
  end

  return table.concat(doc), line_map
end

return M
