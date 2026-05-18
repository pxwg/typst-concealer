# Source References

This file name follows the requested spelling: `sorce.md`.

## Best Access Paths

Use current branch files for implementation targets:

```sh
rg -n "scan_formula_matches|render_formula_batch_via_service|build_formula_service_spec" lua/typst-concealer
sed -n '1102,1195p' lua/typst-concealer/plan.lua
sed -n '967,1040p' lua/typst-concealer/session.lua
sed -n '2754,2865p' lua/typst-concealer/session.lua
```

Use local `fork/main` for the remote-main backend reference. It matches GitHub `pxwg/typst-concealer` `main` at `7ede02e42cb7fc34034fe530a7e4c0991322c72e`.

```sh
git ls-tree -r --name-only fork/main
git show fork/main:lua/typst-concealer/backends/latex/units.lua
git show fork/main:lua/typst-concealer/backends/latex/wrapper.lua
git show fork/main:lua/typst-concealer/backends/latex/session.lua
git show fork/main:lua/typst-concealer/backends/typst/init.lua
```

If the local ref may be stale, verify GitHub directly:

```sh
curl -sS 'https://api.github.com/repos/pxwg/typst-concealer/git/trees/main?recursive=1'
curl -sS https://raw.githubusercontent.com/pxwg/typst-concealer/main/lua/typst-concealer/backends/latex/units.lua
```

## Plan-To-Code Map

### Backend Selection

Current branch:

- `lua/typst-concealer/init.lua:188` - `source_kind_for_bufnr()` currently returns `typst` or `markdown`.
- `lua/typst-concealer/init.lua:395` - setup config is still Typst-centric plus markdown filetypes.
- `lua/typst-concealer/init.lua:560` and later autocmds - managed patterns are currently `*.typ` plus markdown filetype handling.

Remote reference:

- `fork/main:lua/typst-concealer/init.lua` - has `FILETYPE_TO_BACKEND`, `backends.typst`, and opt-in `backends.latex`.
- `fork/main:lua/typst-concealer/backends/latex/init.lua` - backend facade shape: setup, collect units, classify, render, session lifecycle.

Use remote `init.lua` as a reference for config shape and filetype registration, but wire it to current `machine.runtime` calls instead of remote `plan.set_buf_backend()`.

### LaTeX Source Adapter

Current branch:

- `lua/typst-concealer/plan.lua:1102` - `scan_formula_matches()` dispatches Typst vs markdown and converts entries to `scanned_nodes`.
- `lua/typst-concealer/source-adapters/markdown.lua:135` - adapter contract for non-Typst source that already emits render entries.
- `lua/typst-concealer/semantics.lua:28` - current Typst classification for display and layout semantics.

Remote reference:

- `fork/main:lua/typst-concealer/backends/latex/units.lua` - tree-sitter query for `(inline_formula)`, `(displayed_equation)`, `(math_environment)`, top-level traversal, and incremental merge.
- `fork/main:lua/typst-concealer/backends/latex/semantics.lua` - simple LaTeX inline/display semantics.

Best approach:

- Copy the unit collection idea, not the backend ownership model.
- Implement as `source-adapters/latex.lua` or a backend adapter consumed by current `plan.scan_formula_matches()`.
- Emit current-branch entry fields so no reducer changes are needed for the first pass.

### Machine Lifecycle

Current branch:

- `lua/typst-concealer/machine/types.lua:33` - `NodeType` is only `"math" | "code"`.
- `lua/typst-concealer/machine/types.lua:210` - `ScannedNode` contract.
- `lua/typst-concealer/machine/types.lua:224` - `RenderJob` contract sent toward session.
- `lua/typst-concealer/machine/reducer.lua:909` - `nodes_scanned` reconciliation and slot sync.
- `lua/typst-concealer/machine/reducer.lua:1136` - node-level formula render request generation.
- `lua/typst-concealer/machine/reducer.lua:1474` - batch render response acceptance.
- `lua/typst-concealer/machine/reducer.lua:1556` - render failure handling.
- `lua/typst-concealer/machine/runtime.lua:447` - `build_render_job()`.

Best approach:

- Avoid adding a new lifecycle.
- Add only metadata needed for backend routing, preferably in `semantics.source_kind` or `project_scope`.
- Keep all stale response checks and overlay ownership in the reducer unchanged.

### Formula Presentation

Current branch:

- `lua/typst-concealer/formula/manager.lua:386` - builds batch render requests from reducer effects.
- `lua/typst-concealer/formula/manager.lua:602` - live preview is placement-driven.
- `lua/typst-concealer/formula/manager.lua:686` - scan-to-formula scheduling entry point.
- `lua/typst-concealer/formula/placement.lua:46` - placement object mirrors one formula node.
- `lua/typst-concealer/formula/placement.lua:308` - builds a render job for its overlay.
- `lua/typst-concealer/formula/placement.lua:407` - updates visible presentation without compile.
- `lua/typst-concealer/formula/placement.lua:495` - commits a rendered artifact.
- `lua/typst-concealer/formula/image.lua` - tracks terminal upload epoch for a formula artifact.

Remote reference:

- Do not reuse remote LaTeX direct `on_page_rendered()` path for final integration.
- Remote `backends/latex/session.lua` calls `apply.accept_page_update()` directly; current branch should instead call `formula.manager.rendered()` and let placement commit.

### Project Scope

Current branch:

- `lua/typst-concealer/project-scope.lua:31` - resolves Typst root, inputs, preamble path, and context signature.
- `lua/typst-concealer/path-rewrite.lua` - root-relative path helpers for generated documents.
- `lua/typst-concealer/workspace.lua:40` - per-buffer workspace under `.typst-concealer`.
- `lua/typst-concealer/workspace.lua:80` - stable slot path generation.

Remote reference:

- `fork/main:lua/typst-concealer/backends/latex/session.lua` - simple cache-dir and input/pdf/png path derivation.
- `fork/main:lua/typst-concealer/backends/latex/wrapper.lua` - minimal LaTeX preamble assembly.

Best approach:

- Extend current project scope rather than adopting remote cache dirs.
- Include LaTeX root/main/preamble/compiler args in `context_signature`.
- Keep generated files inside current workspace so cleanup and diagnostics stay consistent.

### Wrapping And Context

Current branch:

- `lua/typst-concealer/wrapper.lua:100` - builds Typst document-level context.
- `lua/typst-concealer/wrapper.lua:297` - builds one slot sidecar and source line map.
- `lua/typst-concealer/wrapper.lua:379` - old full batch document builder.
- `lua/typst-concealer/session.lua:903` - current full-service spec.
- `lua/typst-concealer/session.lua:967` - current formula-service spec.

Remote reference:

- `fork/main:lua/typst-concealer/backends/latex/wrapper.lua` - delimiter unwrapping, `preview` package, one preview block per page, page filename calculation.

Best approach:

- Borrow LaTeX document construction ideas.
- Return current-style `nodes`, `formula_line_maps`, `generated_slot_paths`, `context_source`, and `cache_key`.
- Keep page-to-node mapping in session meta, not in a backend-owned session table.

### Render Transport

Current branch:

- `lua/typst-concealer/session.lua:967` - `build_formula_service_spec()`.
- `lua/typst-concealer/session.lua:1670` and following - formula service response handling.
- `lua/typst-concealer/session.lua:2754` - `render_formula_batch_via_service()`.
- `lua/typst-concealer/session.lua:2866` - full render request path.
- `lua/typst-concealer/session.lua:3021` - preview request path.
- `service/src/protocol.rs:8` - JSON-lines message variants.
- `service/src/protocol.rs:31` - `RenderFormulasRequest`.
- `service/src/main.rs` - request dispatch and worker scheduling.
- `service/src/compiler.rs:200` - Typst formula rendering.
- `service/src/compiler.rs:415` - virtual document entry construction.
- `service/src/compiler.rs:437` - formula cache key.

Remote reference:

- `fork/main:lua/typst-concealer/backends/latex/session.lua` - pdflatex to converter pipeline and log parsing.

Best approach:

- Add a LaTeX renderer under the Rust service, or a backend-aware Lua transport that still reports through current session response handlers.
- Prefer Rust service integration so request ordering, workers, cache metrics, and stale response handling stay unified.

### Diagnostics

Current branch:

- `lua/typst-concealer/session.lua:35` and following - quickfix bucket rebuild.
- `lua/typst-concealer/session.lua:1302` and following - full diagnostics mapping.
- `lua/typst-concealer/session.lua:1388` and following - formula diagnostics mapping.
- `tests/run.lua` - existing diagnostics and stale-response tests around service requests.

Remote reference:

- `fork/main:lua/typst-concealer/backends/latex/session.lua` - `parse_latex_log()` handles `! ...` plus `l.N` log patterns.

Best approach:

- Reuse remote log parsing as a starting parser only.
- Store output in current `render_diagnostics[bufnr].formula_by_node`.
- Map generated line positions through current slot line maps.

### Artifact Cleanup

Current branch:

- `lua/typst-concealer/session.lua:253` - local unlink helper.
- `lua/typst-concealer/session.lua:268` - checks whether a service PNG is still referenced.
- `lua/typst-concealer/session.lua:302` - safe artifact unlink.
- `lua/typst-concealer/session.lua:427` and following - cache/workspace cleanup.
- `lua/typst-concealer/machine/resources.lua` - image id and extmark resource release.

Remote reference:

- Remote LaTeX cleanup deletes its session files directly. Use this only as a list of generated artifacts, not as final cleanup behavior.

Best approach:

- Put LaTeX PNGs in current workspace outputs.
- Let placement/resource cleanup own image ids.
- Use `safe_unlink_service_artifact()` for rendered files.

### Tests

Current branch:

- `tests/run.lua` has coverage for session request JSON, formula transport batches, stale formula responses, wrapper line maps, reducer formula batches, and artifact cleanup.
- Use `rg -n "formula_transport|overlay_pages_batch_ready|safe_unlink|wrapper|diagnostics" tests/run.lua` to find nearby examples.

Remote reference:

- `fork/main:tests/run.lua` has lighter backend-oriented tests. Use for expected LaTeX units/wrapper behavior, not lifecycle assertions.

Best approach:

- Add Lua tests first with service stubs.
- Add external-tool rendering tests guarded by executable checks.

