# LaTeX Backend Plan

## Goal

Add LaTeX math rendering as an independent backend while preserving the current branch's proven frontend lifecycle:

- tree-sitter scans a buffer and emits stable node descriptions.
- `machine.reducer` owns node, slot, overlay, request, stale-response, and retire state.
- `formula.manager` and `formula.placement` own per-node presentation side effects.
- `session.lua` owns transport, diagnostics routing, artifact cleanup, and service request ordering.

The LaTeX work should not port the remote `main` frontend image scheduler. Remote `fork/main` is useful for backend shape, LaTeX AST queries, wrapper construction, and process pipeline ideas, but its `state.watch_sessions` plus direct `apply.accept_page_update` flow is weaker than the current reducer/placement path.

## Target Architecture

The target flow should be:

```text
init/source kind
  -> source adapter scan
  -> plan.scan_formula_matches
  -> machine.reducer nodes_scanned
  -> formula.manager.update_from_scan
  -> reducer formula_renders_requested
  -> session backend request builder
  -> backend renderer/service
  -> session response validator
  -> formula.manager.rendered/render_failed
  -> placement.commit_render/update_presentation
```

Only source scanning, project context, document wrapping, compiler transport, and diagnostics parsing should become backend-specific. Node lifecycle and image presentation stay shared.

## Design Rules

1. Keep LaTeX nodes as normal formula nodes.
   LaTeX math can use `node_type = "math"` and semantics `{ source_kind = "latex", display_kind = ..., constraint_kind = "intrinsic" }`. Add a `backend_id = "latex"` field only if request routing cannot be derived reliably from the buffer/project scope.

2. Do not create a parallel overlay lifecycle.
   Avoid `watch_sessions`, `page_state`, direct `state.get_item_by_image_id`, and direct `apply.accept_page_update` for LaTeX full renders. The current `formula.manager`/`placement` path already handles stale responses, extmark drift, image reuse, hover reveal, preview, and artifact cleanup.

3. Treat LaTeX as project-scoped, not markdown-scoped.
   A `.tex` file needs project context: root, main file, preamble, compiler args, aux/output directory, and external asset freshness. The backend must not render snippets as isolated markdown math without a project preamble.

4. Keep the transport batch node-level.
   Current `render_formula_batch_via_service()` is the right abstraction: each dirty node gets its own candidate overlay and response. The backend may compile a multi-page batch internally, but session responses must resolve back to node ids and overlay ids.

## Tasks

### 1. Register Backend Selection

- Add LaTeX support to `source_kind_for_bufnr()` for `tex`, `plaintex`, `latex`, and `.tex`.
- Add backend config under `config.backends.latex`, while preserving current top-level Typst options.
- Add managed autocmd patterns for `*.tex`, but keep existing buffer-local scheduling through `machine.runtime`.
- Add prerequisite checks as warnings, not hard setup failures, for optional LaTeX support:
  `latex` parser, compiler executable, and converter executable.

Expected config shape:

```lua
require("typst-concealer").setup({
  backends = {
    latex = {
      enabled = true,
      compiler = "pdflatex",
      converter = "pdftocairo",
      header = "",
      get_root = function(bufnr, path, cwd, kind) end,
      get_main_file = function(bufnr, path, cwd, kind) end,
      get_preamble_file = function(bufnr, path, cwd, kind) end,
    },
  },
})
```

### 2. Add LaTeX Source Adapter

Create `lua/typst-concealer/source-adapters/latex.lua`.

Responsibilities:

- Use tree-sitter `latex` query for top-level math:
  `(inline_formula)`, `(displayed_equation)`, `(math_environment)`.
- Collect only maximal nodes, so nested captures do not double-render.
- Reuse the current pending-change strategy where safe. LaTeX math-only changes can be incrementally merged; line-count changes or preamble-region changes should force a full scan.
- Emit entries compatible with `plan.scan_formula_matches()`:
  `range`, `display_range`, `node_type = "math"`, `source_text`, `render_text`, `stable_key`, `backend_node_type`, `semantics`.
- Preserve the original source text and delimiters. The wrapper should decide whether to unwrap or normalize delimiters.

### 3. Generalize Scan Dispatch

Update `scan_formula_matches()` so `source_kind == "latex"` uses the LaTeX adapter and still returns `scanned_nodes`.

Minimum shared node fields stay the same:

- `source_range`
- `display_range`
- `source_text`
- `source_str`
- `source_text_hash`
- `context_hash`
- `prelude_count`
- `node_type`
- `semantics`

For LaTeX, `prelude_count` should initially be `0`; project context belongs to the backend context hash, not to Typst runtime preludes.

### 4. Extend Project Scope

Extend `project-scope.lua` to resolve backend-specific project scope.

For LaTeX scope include:

- `backend_id = "latex"`
- `source_root`
- `effective_root`
- `buf_dir`
- `buf_path`
- `main_path`
- `preamble_path`
- `compiler_args`
- `context_signature`

Root and preamble resolution order:

1. `backends.latex.get_root()`
2. directory of `get_main_file()` if configured
3. nearest TeX project markers (`latexmkrc`, `.latexmkrc`, `Tectonic.toml`, `.git`)
4. buffer directory

Preamble resolution order:

1. `backends.latex.get_preamble_file()`
2. preamble extracted from `main_path` before `\begin{document}`
3. minimal default preamble

The `context_signature` must include root, main path, preamble content/signature, compiler args, styling prelude, PPI/cell metrics, and backend version.

### 5. Build LaTeX Documents

Add a LaTeX wrapper module, either `lua/typst-concealer/latex-wrapper.lua` or `lua/typst-concealer/backends/latex/wrapper.lua` if backend folders are introduced.

Responsibilities:

- Build document context:
  document class, `preview` or `standalone` package, math packages, color styling, user header, and project preamble.
- Build per-node slot source:
  one formula per logical page or one virtual source per node, depending on service implementation.
- Preserve line maps for diagnostics from generated source back to buffer ranges.
- Normalize only where needed:
  inline `$...$` and `\(...\)` remain inline math; `$$...$$`, `\[...\]`, and math environments remain display math.

Remote `fork/main`'s LaTeX wrapper is a good starting point for delimiter handling and `preview` package usage, but it must be adapted to current slot/request metadata.

### 6. Add Backend Transport

Preferred implementation: keep one JSON-lines Rust service and add a LaTeX render path.

Lua side:

- Add a backend-aware request builder next to `build_formula_service_spec()`, e.g. `build_latex_formula_service_spec()`.
- Route `render_formula_batch_via_service()` based on source/project backend.
- Store backend-aware meta:
  `service_engine = "latex"`, `generated_slot_paths`, `formula_line_maps`, `context_id`, `context_rev`, `source_root`, `effective_root`.
- Keep full and preview service processes separate as they are today.

Rust side:

- Add a protocol variant such as `render_latex_formulas`, or add a `backend` field to `RenderFormulasRequest`.
- Add `service/src/latex.rs` with a renderer that:
  writes a generated `.tex` document,
  invokes the configured compiler,
  converts PDF pages to PNG,
  returns one response per formula node,
  caches by context hash, node source hash, compiler args, root, PPI, and external file mtimes.
- Keep output PNGs under the current workspace outputs directory so Lua cleanup can use existing artifact guards.

An acceptable first implementation can compile a whole batch document and map pages to nodes. A later optimization can compile per-node virtual documents in parallel if batch latency is too high.

### 7. Diagnostics

Diagnostics should be backend-specific but reported through current quickfix buckets.

- Parse LaTeX log errors and warnings.
- Map generated line positions through slot line maps when possible.
- Attribute preamble/header errors to generated context files or project preamble files.
- Store node-level diagnostics in `render_diagnostics[bufnr].formula_by_node[node_id]`, matching the current Typst formula path.
- Clear diagnostics for deleted nodes during scan/request reconciliation.

### 8. Preview

Reuse current live preview ownership:

- `formula.manager:sync_cursor_preview()`
- `plan.render_live_typst_preview_for_item()`
- `session.render_preview_tail_via_service()`
- `runtime.accept_preview_page_update()`

Rename later if desired, but do not fork behavior for LaTeX initially. For the first pass, LaTeX preview can render raw source without symbol highlighting. Symbol-span highlighting can be added after stable rendering.

### 9. Artifact Lifecycle

LaTeX PNGs must obey the same lifecycle guarantees as Typst PNGs.

- Use workspace output directories from `workspace.lua`.
- Use content or request-stamped filenames.
- Do not delete a PNG if any live overlay or preview still references it.
- Route cleanup through `safe_unlink_service_artifact()`.
- Do not let the LaTeX backend directly clear kitty image ids; placement owns that.

### 10. Tests

Lua tests:

- LaTeX filetypes become supported only when enabled.
- LaTeX adapter collects inline, display, and math environment nodes.
- Incremental scan keeps stable keys and avoids duplicate nested math nodes.
- Scanned LaTeX nodes go through `formula.manager.update_from_scan()`.
- Formula batch requests do not install buffer-global active requests.
- Stale LaTeX responses are dropped and artifacts are cleaned.
- Diagnostics map from generated slot lines to source lines.
- Deleted nodes clear node-level diagnostics.

Rust/service tests:

- Protocol decodes LaTeX render requests.
- Wrapper/compiler invocation produces one PNG per node when toolchain is available.
- Cache invalidates when preamble or imported files change.
- Compiler failure returns diagnostics without committing overlays.

Mark external-tool tests as skipped when `pdflatex`/`tectonic` or `pdftocairo` are missing.

### 11. Milestones

1. Scanner-only milestone:
   backend config, filetype support, LaTeX source adapter, and Lua tests for scan output.

2. State-machine integration milestone:
   LaTeX nodes enter reducer/manager and produce formula render jobs, with service calls stubbed in tests.

3. Rendering milestone:
   backend request builder plus Rust LaTeX renderer, response validation, and PNG commit through placement.

4. Project-context milestone:
   root/main/preamble resolution, context hashing, external file invalidation, diagnostics mapping.

5. Preview and polish milestone:
   live preview, docs, user config, skipped external-tool tests, and benchmark comparison with Typst formula service.

