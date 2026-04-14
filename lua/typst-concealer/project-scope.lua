--- Shared project scope resolution for planner and watch sessions.

local M = {}

local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/$", "")
end

local function get_buf_dir(bufnr)
  local buf_file = vim.api.nvim_buf_get_name(bufnr)
  if buf_file == nil or buf_file == "" then
    return vim.uv.cwd()
  end
  return vim.fn.fnamemodify(buf_file, ":h")
end

local function signature(parts)
  return vim.fn.sha256(table.concat(parts or {}, "\0"))
end

local function resolve_root_base(configured_root, cwd, project_root, buf_dir)
  return normalize(configured_root) or normalize(cwd) or normalize(project_root) or normalize(buf_dir)
end

--- @param bufnr integer
--- @param kind "full"
--- @return ProjectScope
function M.resolve(bufnr, kind)
  local main = require("typst-concealer")
  local config = main.config or {}
  local path_rewrite = require("typst-concealer.path-rewrite")

  local buf_path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.fn.getcwd()
  local buf_dir = get_buf_dir(bufnr)
  local project_root = path_rewrite.get_project_root(buf_dir)

  local configured_root = nil
  if type(config.get_root) == "function" then
    local ok, result = pcall(config.get_root, bufnr, buf_path, cwd, kind)
    if ok and type(result) == "string" and result ~= "" then
      configured_root = result
    end
  end

  local source_root = resolve_root_base(configured_root, cwd, project_root, buf_dir)
  local effective_root = source_root

  local inputs = {}
  if type(config.get_inputs) == "function" then
    local ok, result = pcall(config.get_inputs, bufnr, buf_path, cwd, kind)
    if ok and type(result) == "table" then
      inputs = result
    end
  end

  local preamble_path = ""
  if type(config.get_preamble_file) == "function" then
    local ok, result = pcall(config.get_preamble_file, bufnr, buf_path, cwd, kind)
    if ok and type(result) == "string" then
      preamble_path = normalize(result) or result
    end
  end

  local inputs_signature = signature(inputs)
  local preamble_signature = signature({ preamble_path })
  local context_signature = signature({
    kind or "",
    normalize(buf_path) or "",
    source_root or "",
    effective_root or "",
    inputs_signature,
    preamble_signature,
  })

  return {
    project_scope_id = context_signature,
    source_root = source_root,
    effective_root = effective_root,
    inputs_signature = inputs_signature,
    preamble_signature = preamble_signature,
    context_signature = context_signature,
    buf_dir = buf_dir,
    buf_path = buf_path,
    cwd = cwd,
    inputs = inputs,
    preamble_path = preamble_path,
  }
end

return M
