---Display-stream reconstruction for rows redrawn by typst-concealer.
---
---The compositor cannot ask Neovim for a pre-layout "final line", so this
---module reconstructs the parts we can own: native syntax/tree-sitter/semantic
---highlights, persistent extmark highlights, syntax conceal, extmark conceal,
---and inline virtual text.  Callers can then inject image atoms before wrapping.

local kitty_codes = require("typst-concealer.kitty-codes")
local M = {}

local function buf_win(bufnr)
  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
    return winid
  end
end

local function conceallevel(bufnr)
  local winid = buf_win(bufnr)
  if winid then
    return tonumber(vim.wo[winid].conceallevel) or 0
  end
  return tonumber(vim.o.conceallevel) or 0
end

local function excluded_ns(opts, ns_id)
  return opts and opts.exclude_namespaces and opts.exclude_namespaces[ns_id] == true
end

local function item_hl(item)
  if type(item) ~= "table" then
    return nil
  end

  local item_opts = item.opts
  if type(item_opts) == "table" then
    if item_opts.hl_group ~= nil then
      return item_opts.hl_group
    end
  end
  if item.hl_group ~= nil then
    return item.hl_group
  end
  if type(item_opts) == "table" then
    if item_opts.hl_group_link ~= nil then
      return item_opts.hl_group_link
    end
  end
  return item.hl_group_link
end

local function append_hl(stack, hl_group)
  if type(hl_group) == "table" then
    for _, group in ipairs(hl_group) do
      append_hl(stack, group)
    end
    return
  end
  if type(hl_group) ~= "string" and type(hl_group) ~= "number" then
    return
  end
  if hl_group == "" then
    return
  end
  if stack[#stack] ~= hl_group then
    stack[#stack + 1] = hl_group
  end
end

local function stack_hl(stack)
  if #stack == 0 then
    return ""
  end
  if #stack == 1 then
    return stack[1]
  end
  return stack
end

local function position_in_item(item, row, col)
  if item.row == nil or item.col == nil then
    return true
  end

  local start_row = tonumber(item.row) or row
  local start_col = tonumber(item.col) or col
  local item_opts = item.opts or item
  local end_row = tonumber(item.end_row or item_opts.end_row) or start_row
  local end_col = tonumber(item.end_col or item_opts.end_col) or start_col + 1
  if row < start_row or row > end_row then
    return false
  end
  if start_row == end_row then
    return col >= start_col and col < end_col
  end
  return (row == start_row and col >= start_col)
    or (row == end_row and col < end_col)
    or (row > start_row and row < end_row)
end

local function inspect_hl_stack(bufnr, row, col, opts)
  local ok, inspected = pcall(vim.inspect_pos, bufnr, row, col, {
    extmarks = "all",
    syntax = true,
    treesitter = true,
    semantic_tokens = true,
  })
  if not ok or type(inspected) ~= "table" then
    return ""
  end

  local stack = {}
  for _, item in ipairs(inspected.syntax or {}) do
    append_hl(stack, item_hl(item))
  end
  for _, item in ipairs(inspected.treesitter or {}) do
    append_hl(stack, item_hl(item))
  end
  for _, item in ipairs(inspected.semantic_tokens or {}) do
    append_hl(stack, item_hl(item))
  end

  local extmarks = {}
  for _, item in ipairs(inspected.extmarks or {}) do
    if not excluded_ns(opts, item.ns_id) and position_in_item(item, row, col) then
      extmarks[#extmarks + 1] = item
    end
  end
  table.sort(extmarks, function(a, b)
    local a_opts = a.opts or {}
    local b_opts = b.opts or {}
    local a_priority = tonumber(a_opts.priority) or 0
    local b_priority = tonumber(b_opts.priority) or 0
    if a_priority ~= b_priority then
      return a_priority < b_priority
    end
    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
  end)
  for _, item in ipairs(extmarks) do
    append_hl(stack, item_hl(item))
  end

  return stack_hl(stack)
end

local function line_chars(bufnr, row, line, opts)
  local chars = {}
  local col = 0
  local char_count = vim.fn.strchars(line)
  for idx = 0, char_count - 1 do
    local text = vim.fn.strcharpart(line, idx, 1)
    local next_col = col + #text
    chars[#chars + 1] = {
      start_col = col,
      end_col = next_col,
      text = text,
      hl_group = inspect_hl_stack(bufnr, row, col, opts),
    }
    col = next_col
  end
  return chars
end

local function char_at_byte(line, col)
  local text = vim.fn.strcharpart(line:sub(col + 1), 0, 1)
  if text == "" then
    return line:sub(col + 1, col + 1)
  end
  return text
end

local function append_chunk(chunks, text, hl_group)
  if text == "" then
    return
  end
  local last = chunks[#chunks]
  hl_group = hl_group or ""
  if last ~= nil and not last.image and vim.deep_equal(last[2], hl_group) then
    last[1] = (last[1] or "") .. text
    return
  end
  chunks[#chunks + 1] = { text, hl_group }
end

local function append_chars(chunks, chars, start_col, end_col)
  for _, char in ipairs(chars) do
    if char.end_col > start_col and char.start_col < end_col then
      append_chunk(chunks, char.text, char.hl_group)
    end
  end
end

local function normalize_range(row, start_col, end_col, line_len)
  start_col = math.max(0, math.min(tonumber(start_col) or 0, line_len))
  end_col = math.max(start_col, math.min(tonumber(end_col) or start_col, line_len))
  return {
    row = row,
    start_col = start_col,
    end_col = end_col,
  }
end

local function collect_syntax_conceal(bufnr, row, line, opts, operations)
  if conceallevel(bufnr) <= 0 then
    return
  end

  local col = 0
  while col < #line do
    local ok, info = pcall(vim.fn.synconcealed, row + 1, col + 1)
    if not ok or type(info) ~= "table" or tonumber(info[1]) ~= 1 then
      local text = char_at_byte(line, col)
      col = col + math.max(1, #text)
    else
      local start_col = col
      local conceal_text = info[2] or ""
      local region = tonumber(info[3]) or 0
      repeat
        local text = char_at_byte(line, col)
        col = col + math.max(1, #text)
        ok, info = pcall(vim.fn.synconcealed, row + 1, col + 1)
      until not ok
        or type(info) ~= "table"
        or tonumber(info[1]) ~= 1
        or tonumber(info[3]) ~= region
        or (info[2] or "") ~= conceal_text

      operations[#operations + 1] = vim.tbl_extend("force", normalize_range(row, start_col, col, #line), {
        source = "syntax",
        priority = 90,
        chunks = {
          { conceal_text, inspect_hl_stack(bufnr, row, start_col, opts) },
        },
      })
    end
  end
end

local function capture_metadata(metadata, capture_id)
  if type(metadata) ~= "table" then
    return nil
  end
  return metadata[capture_id]
end

local function metadata_value(metadata, capture_id, key)
  local capture_data = capture_metadata(metadata, capture_id)
  if type(capture_data) == "table" and capture_data[key] ~= nil then
    return capture_data[key]
  end
  if type(metadata) == "table" then
    return metadata[key]
  end
end

local function treesitter_capture_hl(query, capture_id, lang, metadata)
  local hl_group = metadata_value(metadata, capture_id, "highlight")
  if type(hl_group) == "string" and hl_group ~= "" then
    return hl_group
  end

  local capture = query.captures and query.captures[capture_id]
  if type(capture) ~= "string" or capture == "" then
    return "Conceal"
  end

  if type(lang) == "string" and lang ~= "" then
    return "@" .. capture .. "." .. lang
  end

  return "@" .. capture
end

local function collect_treesitter_conceal(bufnr, row, line, operations)
  if conceallevel(bufnr) <= 0 then
    return
  end
  local highlighter_api = vim.treesitter and vim.treesitter.highlighter
  local highlighter = highlighter_api and highlighter_api.active and highlighter_api.active[bufnr]
  if highlighter == nil then
    return
  end

  local function visit_state(state)
    local highlighter_query = state.highlighter_query or {}
    local query = highlighter_query._query
    local tree = state.tstree
    if query == nil or tree == nil then
      return
    end

    local ok_root, root = pcall(function()
      return tree:root()
    end)
    if not ok_root or root == nil then
      return
    end

    for capture_id, node, metadata in query:iter_captures(root, bufnr, row, row + 1) do
      local conceal = metadata_value(metadata, capture_id, "conceal")
      if conceal ~= nil then
        local start_row, start_col, end_row, end_col = node:range()
        if start_row <= row and end_row >= row then
          local line_start_col = row == start_row and start_col or 0
          local line_end_col = row == end_row and end_col or #line
          operations[#operations + 1] =
            vim.tbl_extend("force", normalize_range(row, line_start_col, line_end_col, #line), {
              source = "treesitter",
              priority = tonumber(metadata_value(metadata, capture_id, "priority")) or 100,
              chunks = {
                { conceal or "", treesitter_capture_hl(query, capture_id, highlighter_query.lang, metadata) },
              },
            })
        end
      end
    end
  end

  if type(highlighter.for_each_highlight_state) == "function" then
    pcall(function()
      highlighter:for_each_highlight_state(visit_state)
    end)
  else
    for _, state in ipairs(highlighter._highlight_states or {}) do
      visit_state(state)
    end
  end
end

local function collect_extmark_ops(bufnr, row, line, opts, operations)
  local ok, extmarks = pcall(
    vim.api.nvim_buf_get_extmarks,
    bufnr,
    -1,
    { row, 0 },
    { row, -1 },
    { details = true, overlap = true }
  )
  if not ok then
    return
  end

  for _, mark in ipairs(extmarks) do
    local col = mark[3]
    local details = mark[4] or {}
    if details.ns_id ~= nil and not excluded_ns(opts, details.ns_id) then
      local end_row = tonumber(details.end_row) or row
      local end_col = tonumber(details.end_col) or col
      local priority = tonumber(details.priority) or 0
      if details.conceal ~= nil and end_row == row then
        operations[#operations + 1] = vim.tbl_extend("force", normalize_range(row, col, end_col, #line), {
          source = "extmark",
          priority = priority,
          chunks = {
            { details.conceal or "", details.hl_group or inspect_hl_stack(bufnr, row, col, opts) },
          },
        })
      end

      if type(details.virt_text) == "table" and details.virt_text_pos == "inline" then
        operations[#operations + 1] = {
          row = row,
          start_col = col,
          end_col = col,
          source = "extmark-virt-text",
          priority = priority,
          chunks = vim.deepcopy(details.virt_text),
        }
      end
    end
  end
end

local function collect_math_conceal_ops(bufnr, row, line, opts, operations)
  if opts and opts.math_conceal == false then
    return
  end

  local ok, render = pcall(require, "math-conceal.render")
  if not ok or type(render.collect_display_marks) ~= "function" then
    return
  end

  local ok_marks, marks = pcall(render.collect_display_marks, bufnr, {
    toprow = row,
    botrow = row,
  })
  if not ok_marks or type(marks) ~= "table" then
    return
  end

  for _, mark in ipairs(marks) do
    if mark.kind == "conceal" and mark.row == row and mark.end_row == row then
      operations[#operations + 1] = vim.tbl_extend("force", normalize_range(row, mark.col, mark.end_col, #line), {
        source = "math-conceal",
        priority = tonumber(mark.priority) or 100,
        chunks = {
          { mark.conceal or "", mark.hl_group or inspect_hl_stack(bufnr, row, mark.col, opts) },
        },
      })
    end
  end
end

local function collect_operations(bufnr, row, line, replacements, opts)
  local operations = {}
  collect_syntax_conceal(bufnr, row, line, opts, operations)
  collect_treesitter_conceal(bufnr, row, line, operations)
  collect_extmark_ops(bufnr, row, line, opts, operations)
  collect_math_conceal_ops(bufnr, row, line, opts, operations)

  for _, replacement in ipairs(replacements or {}) do
    local op = vim.tbl_extend("force", normalize_range(row, replacement.start_col, replacement.end_col, #line), {
      source = replacement.source or "replacement",
      priority = tonumber(replacement.priority) or 10000,
      chunks = replacement.chunks or {},
    })
    operations[#operations + 1] = op
  end

  table.sort(operations, function(a, b)
    if a.start_col == b.start_col then
      if a.end_col == b.end_col then
        return (a.priority or 0) > (b.priority or 0)
      end
      return a.end_col > b.end_col
    end
    return a.start_col < b.start_col
  end)
  return operations
end

---Build chunks for a source line, with native display operations replayed.
--- @param bufnr integer
--- @param row integer
--- @param replacements table[]|nil caller-owned replacements, e.g. image atoms
--- @param opts table|nil { exclude_namespaces?: table<integer, boolean> }
--- @return table[]|nil chunks
function M.line_chunks(bufnr, row, replacements, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  opts = opts or {}

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if line == nil then
    return nil
  end

  local chars = line_chars(bufnr, row, line, opts)
  local operations = collect_operations(bufnr, row, line, replacements, opts)
  local chunks = {}
  local last_col = 0

  for _, op in ipairs(operations) do
    if op.start_col >= last_col then
      append_chars(chunks, chars, last_col, op.start_col)
      for _, chunk in ipairs(op.chunks or {}) do
        chunks[#chunks + 1] = chunk
      end
      last_col = math.max(last_col, op.end_col)
    end
  end

  append_chars(chunks, chars, last_col, #line)
  return chunks
end

local function image_placeholder_text(row, cols, start_col)
  start_col = start_col or 0
  local line = ""
  for col = start_col, start_col + cols - 1 do
    line = line .. kitty_codes.placeholder .. kitty_codes.diacritics[row] .. kitty_codes.diacritics[col + 1]
  end
  return line
end

local function append_wrapped_text(lines, line_idx, col, text, hl_group, max_cols)
  local char_count = vim.fn.strchars(text)
  for idx = 0, char_count - 1 do
    local ch = vim.fn.strcharpart(text, idx, 1)
    local width = vim.fn.strdisplaywidth(ch)
    if width > 0 and col > 0 and col + width > max_cols then
      line_idx = line_idx + 1
      lines[line_idx] = {}
      col = 0
    end
    lines[line_idx][#lines[line_idx] + 1] = { ch, hl_group or "" }
    col = col + width
  end
  return line_idx, col
end

local function append_wrapped_image(lines, line_idx, col, chunk, max_cols)
  local offset = 0
  local remaining = chunk.width or 0
  local hl_group = chunk.hl_group or chunk[2] or chunk[1] or ""

  while remaining > 0 do
    if col >= max_cols then
      line_idx = line_idx + 1
      lines[line_idx] = {}
      col = 0
    end

    local available = max_cols - col
    if available <= 0 then
      available = max_cols
    end
    local take = math.min(remaining, available)
    lines[line_idx][#lines[line_idx] + 1] = {
      image_placeholder_text(chunk.image_row or 1, take, offset),
      hl_group,
    }
    offset = offset + take
    remaining = remaining - take
    col = col + take
  end

  return line_idx, col
end

local function append_wrapped_chunk(lines, line_idx, col, chunk, max_cols)
  local text = chunk[1] or ""
  if chunk.image then
    return append_wrapped_image(lines, line_idx, col, chunk, max_cols)
  end
  if text == "" then
    return line_idx, col
  end

  local hl_group = chunk[2] or ""
  local width = chunk.width or vim.fn.strdisplaywidth(text)
  if chunk.atomic then
    if col > 0 and col + width > max_cols then
      line_idx = line_idx + 1
      lines[line_idx] = {}
      col = 0
    end
    lines[line_idx][#lines[line_idx] + 1] = { text, hl_group }
    return line_idx, col + width
  end

  return append_wrapped_text(lines, line_idx, col, text, hl_group, max_cols)
end

---Wrap composed chunks into Neovim virtual-line chunks by display width.
--- @param chunks table[]
--- @param max_cols integer
--- @return table[]
function M.wrap_chunks(chunks, max_cols)
  max_cols = math.max(1, tonumber(max_cols) or 1)
  local lines = { {} }
  local line_idx = 1
  local col = 0
  for _, chunk in ipairs(chunks or {}) do
    line_idx, col = append_wrapped_chunk(lines, line_idx, col, chunk, max_cols)
  end
  if #lines[#lines] == 0 then
    lines[#lines][1] = { "", "" }
  end
  return lines
end

---Compose a source line and wrap it into virtual lines.
--- @param bufnr integer
--- @param row integer
--- @param replacements table[]|nil
--- @param max_cols integer
--- @param opts table|nil
--- @return table[]|nil lines
function M.line_virt_lines(bufnr, row, replacements, max_cols, opts)
  local chunks = M.line_chunks(bufnr, row, replacements, opts)
  if chunks == nil then
    return nil
  end
  return M.wrap_chunks(chunks, max_cols)
end

local function append_wrapped_nonempty(lines, chunks, max_cols)
  if #chunks == 0 then
    return
  end
  for _, line in ipairs(M.wrap_chunks(chunks, max_cols)) do
    lines[#lines + 1] = line
  end
end

---Compose a source line containing a block atom into virtual lines.
---
---The block atom replaces a source range but renders as independent virtual
---lines. Text before and after the block is still reconstructed through the
---same display stream as inline composition, so native highlights/conceal and
---supported provider marks remain visible.
--- @param bufnr integer
--- @param row integer
--- @param block table { start_col: integer, end_col: integer, lines: table[] }
--- @param max_cols integer
--- @param opts table|nil
--- @return table[]|nil lines
function M.line_block_virt_lines(bufnr, row, block, max_cols, opts)
  if type(block) ~= "table" then
    return nil
  end

  local marker = {
    block = true,
    lines = block.lines or {},
  }
  local chunks = M.line_chunks(bufnr, row, {
    {
      source = block.source or "block-replacement",
      start_col = block.start_col,
      end_col = block.end_col,
      priority = tonumber(block.priority) or 10000,
      chunks = { marker },
    },
  }, opts)
  if chunks == nil then
    return nil
  end

  local lines = {}
  local pending = {}
  for _, chunk in ipairs(chunks) do
    if chunk.block then
      append_wrapped_nonempty(lines, pending, max_cols)
      pending = {}
      for _, line in ipairs(chunk.lines or {}) do
        lines[#lines + 1] = line
      end
    else
      pending[#pending + 1] = chunk
    end
  end
  append_wrapped_nonempty(lines, pending, max_cols)

  if #lines == 0 then
    lines[1] = { { "", "" } }
  end
  return lines
end

return M
