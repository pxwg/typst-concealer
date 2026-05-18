--- LaTeX document wrapper construction for service-backed formula rendering.

local M = {}

local function count_lines(text)
  text = text or ""
  if text == "" then
    return 0
  end
  local _, n = text:gsub("\n", "\n")
  if text:sub(-1) ~= "\n" then
    n = n + 1
  end
  return n
end

local function ensure_trailing_newline(text)
  text = text or ""
  if text == "" or text:sub(-1) == "\n" then
    return text
  end
  return text .. "\n"
end

local function normal_hex_color()
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = "Normal" })
  if not ok or type(hl) ~= "table" or hl.fg == nil then
    return nil
  end
  return string.format("%06X", hl.fg)
end

local function configured_hex_color(config)
  local color = config and config.color or nil
  if type(color) == "string" then
    local hex = color:match("#([%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F])")
      or color:match("^([%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F][%da-fA-F])$")
    if hex ~= nil then
      return hex:upper()
    end
  end
  if config == nil or config.styling_type == nil or config.styling_type == "colorscheme" then
    return normal_hex_color()
  end
  return nil
end

local function default_packages(config)
  local parts = {
    "\\usepackage[active,tightpage]{preview}\n",
    "\\setlength\\PreviewBorder{0pt}\n",
    "\\setlength{\\topskip}{0pt}\n",
    "\\usepackage{amsmath,amssymb,amsfonts,mathtools}\n",
    "\\usepackage{xcolor}\n",
    "\\pagestyle{empty}\n",
    "\\setlength{\\parindent}{0pt}\n",
  }
  local hex = configured_hex_color(config)
  if hex ~= nil then
    parts[#parts + 1] = table.concat({
      "\\AtBeginDocument{%\n",
      ("  \\color[HTML]{%s}%%\n"):format(hex),
      ("  \\everymath\\expandafter{\\the\\everymath\\color[HTML]{%s}}%%\n"):format(hex),
      ("  \\everydisplay\\expandafter{\\the\\everydisplay\\color[HTML]{%s}}%%\n"):format(hex),
      "}\n",
    })
  end
  return table.concat(parts)
end

--- @param project_scope table
--- @param config table
--- @return string
function M.build_context_document(project_scope, config)
  config = config or {}
  local project_preamble = ensure_trailing_newline(project_scope and project_scope.preamble_source or "")
  local parts = {}
  if not project_preamble:find("\\documentclass", 1, false) then
    parts[#parts + 1] = "\\documentclass{article}\n"
  end
  parts[#parts + 1] = project_preamble
  parts[#parts + 1] = default_packages(config)
  if config.header ~= nil and config.header ~= "" then
    parts[#parts + 1] = ensure_trailing_newline(config.header)
  end
  return table.concat(parts)
end

--- @param source string
--- @param backend_node_type string
--- @return string
function M.unwrap_math(source, backend_node_type)
  source = source or ""
  if backend_node_type == "math_environment" then
    return source
  end
  if backend_node_type == "inline_formula" then
    if source:sub(1, 2) == "\\(" and source:sub(-2) == "\\)" then
      return "$" .. source:sub(3, -3) .. "$"
    end
    if source:sub(1, 1) == "$" and source:sub(-1) == "$" and source:sub(1, 2) ~= "$$" then
      return source
    end
    return "$" .. source .. "$"
  end
  if backend_node_type == "displayed_equation" then
    if source:sub(1, 2) == "$$" and source:sub(-2) == "$$" then
      return "\\[" .. source:sub(3, -3) .. "\\]"
    end
    if source:sub(1, 2) == "\\[" and source:sub(-2) == "\\]" then
      return source
    end
    return "\\[" .. source .. "\\]"
  end
  return source
end

--- @param job table
--- @param context_source string
--- @return table
function M.build_formula_line_map(job, context_source)
  local source = job.source_str or job.source_text or job.str or ""
  local backend_node_type = job.backend_node_type
    or (job.semantics and job.semantics.backend_node_type)
    or "inline_formula"
  local content = M.unwrap_math(source, backend_node_type)
  local gen_start = count_lines(context_source) + 3
  local content_lines = math.max(1, count_lines(content))
  return {
    item_idx = job.item_idx,
    bufnr = job.bufnr,
    gen_start = gen_start,
    gen_end = gen_start + content_lines - 1,
    gen_start_col = 1,
    src_start = (job.range and job.range[1] or 0) + 1,
    src_end = (job.range and job.range[3] or 0) + 1,
    src_start_col = (job.range and job.range[2] or 0) + 1,
    src_end_col = (job.range and job.range[4] or 0) + 1,
  }
end

--- @param context_source string
--- @param source string
--- @param backend_node_type string
--- @return string
function M.build_formula_document(context_source, source, backend_node_type)
  return table.concat({
    ensure_trailing_newline(context_source),
    "\\begin{document}\n",
    "\\begin{preview}\n",
    ensure_trailing_newline(M.unwrap_math(source, backend_node_type)),
    "\\end{preview}\n",
    "\\end{document}\n",
  })
end

return M
