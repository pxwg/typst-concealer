--- LaTeX document wrapper construction for typst-concealer.
--- Builds a multi-page LaTeX source that renders each snippet on its own page
--- using the `preview` package for tight bounding boxes.
---
--- Pipeline: pdflatex → pdftoppm → per-page PNG files

local M = {}

--- Strip the outer math delimiters from a captured source string and return
--- the inner content suitable for insertion into a \begin{preview} block.
--- For math_environment nodes the source is returned verbatim (it already
--- contains \begin{...}...\end{...}).
--- @param source string  raw buffer text for the node
--- @param node_type string  "inline_formula" | "displayed_equation" | "math_environment"
--- @return string
function M.unwrap_math(source, node_type)
  if node_type == "math_environment" then
    return source
  end
  if node_type == "inline_formula" then
    -- Strip leading/trailing $ (may be $…$ or \(…\))
    local inner = source:match("^%$(.-)%$$") or source:match("^\\%((.-)\\%)$") or source
    return "$" .. inner .. "$"
  end
  if node_type == "displayed_equation" then
    -- Strip \[…\] or $$…$$
    local inner = source:match("^%$%$(.-)%$%$$") or source:match("^%\\%[(.-)%\\%]$") or source
    return "\\[" .. inner .. "\\]"
  end
  return source
end

--- Build the preamble block inserted before \begin{document}.
--- @param config table  LaTeX backend config
--- @param styling_prelude string  colour/font commands from get_styling_prelude()
--- @return string
local function build_preamble(config, styling_prelude)
  local parts = {
    "\\documentclass{article}\n",
    "\\usepackage[active,tightpage]{preview}\n",
    "\\setlength\\PreviewBorder{1pt}\n",
    "\\usepackage{amsmath,amssymb,amsfonts,mathtools}\n",
    "\\usepackage{xcolor}\n",
    "\\pagestyle{empty}\n",
    "\\setlength{\\parindent}{0pt}\n",
  }
  if styling_prelude and styling_prelude ~= "" then
    parts[#parts + 1] = styling_prelude .. "\n"
  end
  if config.header and config.header ~= "" then
    parts[#parts + 1] = config.header .. "\n"
  end
  return table.concat(parts)
end

--- Build a complete multi-page LaTeX document for a list of items.
--- Each item occupies exactly one page (one \begin{preview} block).
--- Returns the document source and a line_map table mapping generated lines
--- back to source positions (for error reporting).
--- @param items table[]   PlannedItem list
--- @param config table    LaTeX backend config
--- @param styling_prelude string
--- @return string doc_source, table line_map
function M.build_batch_document(items, config, styling_prelude)
  local preamble = build_preamble(config, styling_prelude)
  local parts = { preamble, "\\begin{document}\n" }
  local line_map = {}
  local cur_line = 1 + select(2, preamble:gsub("\n", "\n")) + 1 -- after \begin{document}

  for idx, item in ipairs(items) do
    if idx > 1 then
      parts[#parts + 1] = "\\newpage\n"
      cur_line = cur_line + 1
    end
    parts[#parts + 1] = "\\begin{preview}\n"
    cur_line = cur_line + 1

    local content = M.unwrap_math(item.str or "", item.backend_node_type or item.node_type or "inline_formula")
    local src_start = item.range[1] + 1 -- 1-based
    local src_end = item.range[3] + 1
    local content_lines = select(2, content:gsub("\n", "\n")) + 1
    line_map[#line_map + 1] = {
      item_idx = idx,
      bufnr = item.bufnr,
      gen_start = cur_line,
      gen_end = cur_line + content_lines - 1,
      gen_start_col = 1,
      src_start = src_start,
      src_end = src_end,
      src_start_col = item.range[2] + 1,
      src_end_col = item.range[4] + 1,
    }
    parts[#parts + 1] = content .. "\n"
    cur_line = cur_line + content_lines
    parts[#parts + 1] = "\\end{preview}\n"
    cur_line = cur_line + 1
  end

  parts[#parts + 1] = "\\end{document}\n"
  return table.concat(parts), line_map
end

--- Return the expected PNG path for page `i` in a document with `n_pages` total.
--- pdftoppm zero-pads to the minimum width needed for n_pages.
--- @param output_prefix string
--- @param page_idx integer  1-based
--- @param n_pages integer   total number of pages in document
--- @return string
function M.page_path(output_prefix, page_idx, n_pages)
  local n_digits = #tostring(n_pages)
  return string.format("%s-%0" .. n_digits .. "d.png", output_prefix, page_idx)
end

return M
