--- LaTeX render-semantics classification for typst-concealer.
--- Only math nodes are rendered; no code-block support for LaTeX.

local M = {}

--- Classify a LaTeX render unit into RenderSemantics.
--- node_type is one of: "inline_formula", "displayed_equation", "math_environment"
--- @param range table  Range4 {start_row, start_col, end_row, end_col}
--- @param _bufnr integer
--- @param node_type string
--- @return table  RenderSemantics
function M.classify(_range, _bufnr, node_type)
  if node_type == "inline_formula" then
    return {
      constraint_kind = "intrinsic",
      display_kind = "inline",
      source_kind = "math",
    }
  end
  -- displayed_equation, math_environment → block
  return {
    constraint_kind = "intrinsic",
    display_kind = "block",
    source_kind = "math",
  }
end

return M
