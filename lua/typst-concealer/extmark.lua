--- Neovim extmark management and kitty graphics protocol for typst-concealer.
--- This is the Neovim display layer: extmark placement, image upload, concealing.
--- All display decisions come from semantics.display_kind.
--- block_padding_cols = 终端显示留白（Neovim display 层，与 Typst page width 正交）

local state      = require("typst-concealer.state")
local kitty_codes = require("typst-concealer.kitty-codes")
local M = {}

local is_tmux    = vim.env.TMUX ~= nil
local vim_stdout = assert(vim.loop.new_tty(1, false))

local function tmux_escape(message)
  return "\x1bPtmux;" .. message:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
end

local function send_kitty_escape(message)
  if is_tmux then
    vim_stdout:write(tmux_escape("\x1b_G" .. message .. "\x1b\\"))
  else
    vim_stdout:write("\x1b_G" .. message .. "\x1b\\")
  end
end

--- Upload an image to the terminal via kitty graphics protocol.
--- @param path    string  path to the PNG file
--- @param image_id integer
--- @param width   integer  in terminal cells
--- @param height  integer  in terminal cells
function M.create_image(path, image_id, width, height)
  path = vim.base64.encode(path)
  send_kitty_escape("q=2,f=100,t=t,i=" .. image_id .. ";" .. path)
  send_kitty_escape("q=2,a=p,U=1,i=" .. image_id .. ",c=" .. width .. ",r=" .. height)
end

--- Delete an image from the terminal.
--- @param image_id integer
function M.clear_image(image_id)
  send_kitty_escape("q=2,a=d,d=i,i=" .. image_id)
  state.image_ids_in_use[image_id] = nil
end

--- Returns leading spaces needed to centre an image of natural_cols width.
--- @param natural_cols integer
--- @return integer
local function center_padding(natural_cols)
  local win_width = vim.api.nvim_win_get_width(0)
  if natural_cols >= win_width then
    return 0
  end
  return math.floor((win_width - natural_cols) / 2)
end

--- Low-level extmark placement. Use place_render_extmark for external callers.
--- @param image_id  integer
--- @param range     Range4
--- @param extmark_id integer|nil
--- @param concealing boolean|nil
--- @param is_block  boolean|nil
--- @return integer  new extmark_id
local function place_image_extmark(image_id, range, extmark_id, concealing, is_block)
  local start_row, start_col, end_row, end_col = range[1], range[2], range[3], range[4]
  local height = end_row - start_row + 1
  local new_extmark_id

  if height == 1 then
    if concealing == false then
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, state.ns_id, start_row, start_col, {
        id = extmark_id,
        virt_lines = { { { "" } } },
        virt_text_pos = "overlay",
        invalidate = true,
        end_col = end_col,
        end_row = end_row,
      })
    elseif is_block then
      -- Block single-line: overlay to avoid line wrapping, will be centred later
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, state.ns_id, start_row, start_col, {
        id = extmark_id,
        virt_text = { { "" } },
        virt_text_pos = "overlay",
        conceal = "",
        invalidate = true,
        end_col = end_col,
        end_row = end_row,
      })
    else
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, state.ns_id, start_row, start_col, {
        id = extmark_id,
        virt_text = { { "" } },
        virt_text_pos = "inline",
        conceal = "",
        invalidate = true,
        end_col = end_col,
        end_row = end_row,
      })
    end
  else
    if concealing == false then
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, state.ns_id, start_row, start_col, {
        id = extmark_id,
        invalidate = true,
        virt_text = { { "" } },
        -- used for determining the virt_text_pos of child ns_id2 extmarks
        virt_text_pos = "right_align",
        end_col = end_col,
        end_row = end_row,
      })
    elseif is_block then
      -- Block multi-line: conceal_lines (ns_id) + virt_lines (ns_id3) so that
      -- 'wrap' does not insert phantom screen lines between image rows.
      -- They must be in separate extmarks/namespaces because Neovim does not
      -- render virt_lines on a line that is itself concealed.
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, state.ns_id, start_row, start_col, {
        id = extmark_id,
        invalidate = true,
        --- @diagnostic disable-next-line: assign-type-mismatch
        conceal_lines = "",
        end_col = end_col,
        end_row = end_row,
      })
      -- Place a ns_id3 extmark on the line AFTER the concealed range so that
      -- its virt_lines (above=true) appear right where the item was.
      local line_count = vim.api.nvim_buf_line_count(0)
      local vl_row = end_row + 1
      if vl_row >= line_count then
        vim.api.nvim_buf_set_lines(0, line_count, line_count, false, { "" })
      end
      local vl_id = vim.api.nvim_buf_set_extmark(0, state.ns_id3, vl_row, 0, {
        virt_lines = { { { "", "" } } }, -- placeholder, filled in conceal_for_image_id
        virt_lines_above = true,
      })
      state.block_virt_lines_marks[new_extmark_id] = vl_id
      state.multiline_marks[new_extmark_id] = { virt_lines = true }
    else
      new_extmark_id = vim.api.nvim_buf_set_extmark(0, state.ns_id, start_row, start_col, {
        id = extmark_id,
        invalidate = true,
        virt_text = { { "" } },
        virt_text_pos = "overlay",
        end_col = end_col,
        end_row = end_row,
      })
      state.multiline_marks[new_extmark_id] = {}
    end
  end

  state.image_id_to_extmark[image_id] = new_extmark_id
  return new_extmark_id
end

--- Public entry: place an extmark driven by render semantics.
--- Display decision comes only from semantics.display_kind.
--- @param image_id   integer
--- @param range      Range4
--- @param extmark_id integer|nil
--- @param concealing boolean|nil
--- @param semantics  table  RenderSemantics
--- @return integer
function M.place_render_extmark(image_id, range, extmark_id, concealing, semantics)
  local is_block = (semantics.display_kind == "block")
  return place_image_extmark(image_id, range, extmark_id, concealing, is_block)
end

--- Rebuild an existing extmark in-place for a new range.
--- Keeps the old rendered image visible until swap time.
--- @param bufnr      integer
--- @param image_id   integer
--- @param extmark_id integer
--- @param range      Range4
--- @param semantics  table  RenderSemantics
function M.swap_extmark_to_range(bufnr, image_id, extmark_id, range, semantics)
  state.prepare_extmark_reuse(bufnr, extmark_id)
  local new_id = place_image_extmark(image_id, range, extmark_id, nil, semantics.display_kind == "block")
  state.image_id_to_extmark[image_id] = new_id
end

--- Update the virt_text/virt_lines on an existing extmark.
--- @param bufnr           integer
--- @param extmark_id      integer
--- @param virt_text_data  table
--- @param skip_hide_check boolean|nil
function M.update_extmark_text(bufnr, extmark_id, virt_text_data, skip_hide_check)
  if (skip_hide_check ~= true) and state.Currently_hidden_extmark_ids[extmark_id] ~= nil then
    state.Currently_hidden_extmark_ids[extmark_id] = virt_text_data
    return
  end
  local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id, extmark_id, { details = true })
  if #m == 0 then
    return
  end
  local row, col, opts = m[1], m[2], m[3]

  local height = opts.end_row - row + 1
  if height ~= 1 then
    local mm = state.multiline_marks[extmark_id]
    -- virt_lines-based block multiline: update is handled in conceal_for_image_id
    if mm and mm.virt_lines then
      return
    end
    if mm then
      for _, id in pairs(mm) do
        vim.api.nvim_buf_del_extmark(bufnr, state.ns_id2, id)
      end
    end
    state.multiline_marks[extmark_id] = {}
    for i = 1, height do
      local lines = vim.api.nvim_buf_get_lines(0, row, opts.end_row + 1, false)
      local conceal = nil
      if opts.virt_text_pos ~= "right_align" then
        conceal = ""
      end
      local virt_text_line = virt_text_data[i]
      if type(virt_text_line) == "string"
        or (type(virt_text_line) == "table" and type(virt_text_line[1]) == "string")
      then
        virt_text_line = { virt_text_line }
      end
      local new_id = vim.api.nvim_buf_set_extmark(0, state.ns_id2, row + i - 1, 0, {
        virt_text     = virt_text_line,
        conceal       = conceal,
        virt_text_pos = opts.virt_text_pos,
        end_col       = #lines[i],
        end_row       = row + i - 1,
      })
      table.insert(state.multiline_marks[extmark_id], new_id)
    end
  elseif opts.virt_text_pos == "inline"
    or (opts.virt_text_pos == "overlay" and opts.conceal == "")
  then
    vim.api.nvim_buf_set_extmark(0, state.ns_id, row, col, {
      id            = extmark_id,
      virt_text     = virt_text_data,
      virt_text_pos = opts.virt_text_pos,
      invalidate    = opts.invalidate,
      end_col       = opts.end_col,
      end_row       = opts.end_row,
      --- @diagnostic disable-next-line nvim type is wrong
      conceal       = "",
    })
  else
    vim.api.nvim_buf_set_extmark(0, state.ns_id, row, col, {
      id            = extmark_id,
      virt_lines    = { virt_text_data },
      virt_text_pos = opts.virt_text_pos,
      invalidate    = opts.invalidate,
      end_col       = opts.end_col,
      end_row       = opts.end_row,
      --- @diagnostic disable-next-line nvim type is wrong
      conceal       = opts.conceal,
    })
  end
end

--- Add concealing unicode characters for a rendered image.
--- Padding decision comes from the item's semantics (looked up from state).
---   flow + block  → block_padding_cols left padding (terminal display layer)
---   intrinsic + block → centred
---   inline        → no padding
--- @param bufnr        integer
--- @param image_id     integer
--- @param natural_cols integer
--- @param natural_rows integer
--- @param source_rows  integer
function M.conceal_for_image_id(bufnr, image_id, natural_cols, natural_rows, source_rows)
  local extmark_id          = state.image_id_to_extmark[image_id]
  local multiline_extmark_ids = state.multiline_marks[extmark_id]

  local hl_group = "typst-concealer-image-id-" .. tostring(image_id)
  vim.api.nvim_set_hl(0, hl_group, { fg = string.format("#%06X", image_id) })

  -- Retrieve semantics from the owning item (replaces block_formula_ids / flow_block_ids)
  local item   = state.get_item_by_image_id(image_id)
  local config = require("typst-concealer").config
  local pad    = 0
  if item and item.semantics then
    if item.semantics.constraint_kind == "flow" then
      -- Multiline code: left padding = terminal display padding
      -- block_padding_cols = 终端显示留白（Neovim display 层）
      pad = config.block_padding_cols or 0
    elseif item.semantics.display_kind == "block" then
      -- Math display (single- or multi-line): centre in window
      pad = center_padding(natural_cols)
    end
  end

  local pad_str = pad > 0 and string.rep(" ", pad) or nil

  local function make_row_list(i)
    local line = ""
    for j = 0, natural_cols - 1 do
      line = line
        .. kitty_codes.placeholder
        .. kitty_codes.diacritics[i]
        .. kitty_codes.diacritics[j + 1]
    end
    if pad_str then
      return { { pad_str, "" }, { line, hl_group } }
    end
    return { { line, hl_group } }
  end

  local too_tall_msg = "This image attempted to render taller than "
    .. #kitty_codes.diacritics
    .. " lines. If you legitimately see this in a real document, open an issue."

  if multiline_extmark_ids == nil then
    M.update_extmark_text(bufnr, extmark_id, make_row_list(1))
  elseif multiline_extmark_ids.virt_lines then
    local render_rows = natural_rows
    local lines       = {}
    local above_blank = 0
    if natural_rows < source_rows then
      above_blank = math.floor((source_rows - natural_rows) / 2)
      render_rows = source_rows
    end
    for i = 1, render_rows do
      local image_row = i - above_blank
      if image_row < 1 or image_row > natural_rows then
        lines[i] = { { "", hl_group } }
      elseif image_row >= #kitty_codes.diacritics then
        lines[i] = { { too_tall_msg, hl_group } }
      else
        lines[i] = make_row_list(image_row)
      end
    end
    if state.Currently_hidden_extmark_ids[extmark_id] ~= nil then
      state.Currently_hidden_extmark_ids[extmark_id] = { block_virt_lines = true, virt_lines_data = lines }
      return
    end
    local vl_id = state.block_virt_lines_marks[extmark_id]
    if vl_id then
      local m = vim.api.nvim_buf_get_extmark_by_id(bufnr, state.ns_id3, vl_id, { details = true })
      if #m > 0 then
        local row, col = m[1], m[2]
        vim.api.nvim_buf_set_extmark(bufnr, state.ns_id3, row, col, {
          id               = vl_id,
          virt_lines       = lines,
          virt_lines_above = true,
        })
      end
    end
  else
    local lines = {}
    if natural_rows < source_rows then
      local above_blank = math.floor((source_rows - natural_rows) / 2)
      for i = 1, source_rows do
        local image_row = i - above_blank
        if image_row < 1 or image_row > natural_rows then
          lines[i] = { { "", hl_group } }
        elseif image_row >= #kitty_codes.diacritics then
          lines[i] = { { too_tall_msg, hl_group } }
        else
          lines[i] = make_row_list(image_row)
        end
      end
    else
      for i = 1, source_rows do
        if i >= #kitty_codes.diacritics then
          lines[i] = { { too_tall_msg, hl_group } }
        else
          lines[i] = make_row_list(i)
        end
      end
    end
    M.update_extmark_text(bufnr, extmark_id, lines)
  end
end

return M
