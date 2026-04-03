--- Path rewriting utilities for typst-concealer.
--- Rewrites relative paths in Typst source to root-relative paths so that
--- temp files placed in the cache directory can resolve imports/images correctly.
local M = {}

--- Return the longest common ancestor directory of dir1 and dir2.
--- Both must be absolute paths. Returns "/" if they share only the root.
--- @param dir1 string
--- @param dir2 string
--- @return string
function M.common_ancestor(dir1, dir2)
  local function split(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
      parts[#parts + 1] = part
    end
    return parts
  end
  local p1 = split(dir1)
  local p2 = split(dir2)
  local shared = {}
  for i = 1, math.min(#p1, #p2) do
    if p1[i] == p2[i] then
      shared[#shared + 1] = p1[i]
    else
      break
    end
  end
  return #shared > 0 and ("/" .. table.concat(shared, "/")) or "/"
end

--- Walk upward from buf_dir to find the nearest directory containing typst.toml.
--- Falls back to buf_dir if none is found.
--- @param buf_dir string
--- @return string
function M.get_project_root(buf_dir)
  local dir = buf_dir
  while true do
    if vim.uv.fs_stat(dir .. "/typst.toml") ~= nil then
      return dir
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end
  return buf_dir
end

--- Convert a relative path to a root-relative path (leading "/").
--- Absolute paths and @-package paths are returned unchanged.
--- Paths that resolve outside project_root are returned unchanged.
--- @param path string
--- @param buf_dir string
--- @param project_root string
--- @return string
function M.make_root_relative(path, buf_dir, project_root)
  if path:sub(1, 1) == "/" or path:sub(1, 1) == "@" then
    return path
  end
  local abs = vim.fn.fnamemodify(buf_dir .. "/" .. path, ":p"):gsub("/$", "")
  local prefix = project_root .. "/"
  if abs:sub(1, #prefix) ~= prefix then
    return path
  end
  return "/" .. abs:sub(#prefix + 1)
end

--- Rewrite all relative path strings in a Typst text fragment.
--- Handles: #import, #include, image(), json(), toml(), yaml(), read(), csv(),
---           bibliography() first arg and style: named arg.
--- @param text string
--- @param buf_dir string
--- @param project_root string
--- @return string
function M.rewrite_paths(text, buf_dir, project_root)
  local function rw(p)
    return M.make_root_relative(p, buf_dir, project_root)
  end
  local function sub(a, p, b)
    return a .. rw(p) .. b
  end

  -- #import / #include keywords
  for _, kw in ipairs({ "import", "include" }) do
    text = text:gsub('(#' .. kw .. '%s+")([^"]*)(")', sub)
    text = text:gsub("(#" .. kw .. "%s+')" .. "([^']*)" .. "(')", sub)
  end

  -- Function calls: first positional string argument
  local FIRST_ARG_FNS = { "image", "json", "toml", "yaml", "read", "csv", "bibliography" }
  for _, fn in ipairs(FIRST_ARG_FNS) do
    text = text:gsub('(' .. fn .. '%s*%(%s*")([^"]*)(")', sub)
    text = text:gsub("(" .. fn .. "%s*%(%s*')" .. "([^']*)" .. "(')", sub)
  end

  -- bibliography(style: "path.csl") named argument
  text = text:gsub('(style%s*:%s*")([^"]*)(")', sub)
  text = text:gsub("(style%s*:%s*')" .. "([^']*)" .. "(')", sub)

  return text
end

return M
