use std::fs;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::PathBuf;
use std::time::Instant;

use image::codecs::png::{CompressionType, FilterType, PngEncoder};
use image::{ColorType, ImageEncoder};
use typst::diag::{Severity, SourceDiagnostic};
use typst::layout::PagedDocument;

use crate::protocol::{CompileRequest, CompileResponse, CompileStatus, DiagnosticInfo, PageResult};
use crate::world::ConcealerWorld;

pub struct Compiler {
    world: ConcealerWorld,
    /// Hash of Page (frame + fill) from previous compile, indexed by page.
    prev_frame_hashes: Vec<u64>,
    prev_page_paths: Vec<PathBuf>,
    prev_page_dims: Vec<(u32, u32)>,
    prev_ppi: u32,
}

impl Compiler {
    pub fn new() -> Self {
        Self {
            world: ConcealerWorld::new(),
            prev_frame_hashes: Vec::new(),
            prev_page_paths: Vec::new(),
            prev_page_dims: Vec::new(),
            prev_ppi: 0,
        }
    }

    pub fn compile(&mut self, req: CompileRequest) -> CompileResponse {
        let request_id = req.request_id;
        let output_dir = req.output_dir;
        let ppi = req.ppi.max(1);

        self.world.update(req.source_text, req.root, req.inputs);

        // Evict stale comemo memoization entries so incremental compilation
        // remains effective without unbounded memory growth.
        comemo::evict(30);

        if let Err(err) = fs::create_dir_all(&output_dir) {
            return CompileResponse {
                request_id,
                status: CompileStatus::Error,
                pages: vec![],
                diagnostics: vec![DiagnosticInfo {
                    message: format!("failed to create output directory: {err}"),
                    severity: "error".to_string(),
                    file: None,
                    line: None,
                    column: None,
                }],
                compile_us: None,
                render_us: None,
                rendered_pages: None,
            };
        }

        let t_compile = Instant::now();
        let warned = typst::compile::<PagedDocument>(&self.world);
        let compile_us = t_compile.elapsed().as_micros() as u64;

        let warnings = self.format_diagnostics(warned.warnings.iter());
        let document = match warned.output {
            Ok(document) => document,
            Err(errors) => {
                let mut diagnostics = warnings;
                diagnostics.extend(self.format_diagnostics(errors.iter()));
                return CompileResponse {
                    request_id,
                    status: CompileStatus::Error,
                    pages: vec![],
                    diagnostics,
                    compile_us: Some(compile_us),
                    render_us: None,
                    rendered_pages: None,
                };
            }
        };

        let pixel_per_pt = ppi as f32 / 72.0;
        let ppi_changed = ppi != self.prev_ppi;
        let mut pages = Vec::new();
        let mut diagnostics = warnings;
        let mut new_frame_hashes = Vec::with_capacity(document.pages.len());
        let mut new_paths = Vec::with_capacity(document.pages.len());
        let mut new_dims = Vec::with_capacity(document.pages.len());

        let t_render = Instant::now();
        let mut rendered_count = 0usize;

        for (i, page) in document.pages.iter().enumerate() {
            // Hash the compiled page frame (cheap) to detect unchanged pages
            // before doing the expensive pixel rendering.
            let mut hasher = DefaultHasher::new();
            page.hash(&mut hasher);
            ppi.hash(&mut hasher);
            let frame_hash = hasher.finish();

            let can_reuse = !ppi_changed
                && i < self.prev_frame_hashes.len()
                && self.prev_frame_hashes[i] == frame_hash
                && self.prev_page_paths[i].exists();

            if can_reuse {
                let dims = self.prev_page_dims[i];
                new_frame_hashes.push(frame_hash);
                new_paths.push(self.prev_page_paths[i].clone());
                new_dims.push(dims);

                pages.push(PageResult {
                    page_index: i,
                    path: self.prev_page_paths[i].clone(),
                    width_px: dims.0,
                    height_px: dims.1,
                    cached: true,
                });
                continue;
            }

            // Page changed — render to pixels and write PNG.
            rendered_count += 1;
            let pixmap = typst_render::render(page, pixel_per_pt);
            let dims = (pixmap.width(), pixmap.height());

            // Use pixel hash for the filename so identical renders share a path.
            let mut px_hasher = DefaultHasher::new();
            pixmap.data().hash(&mut px_hasher);
            let px_hash = px_hasher.finish();

            let path = output_dir.join(format!("page-{i}-{px_hash:016x}.png"));
            if !path.exists() {
                if let Err(err) = write_pixmap_png(&path, &pixmap) {
                    diagnostics.push(DiagnosticInfo {
                        message: format!("failed to write rendered page: {err}"),
                        severity: "error".to_string(),
                        file: None,
                        line: None,
                        column: None,
                    });
                    return CompileResponse {
                        request_id,
                        status: CompileStatus::Error,
                        pages,
                        diagnostics,
                        compile_us: Some(compile_us),
                        render_us: Some(t_render.elapsed().as_micros() as u64),
                        rendered_pages: Some(rendered_count),
                    };
                }
            }

            new_frame_hashes.push(frame_hash);
            new_paths.push(path.clone());
            new_dims.push(dims);

            pages.push(PageResult {
                page_index: i,
                path,
                width_px: dims.0,
                height_px: dims.1,
                cached: false,
            });
        }

        let render_us = t_render.elapsed().as_micros() as u64;

        // Do NOT clean up old PNG files here.  The Lua plugin manages page
        // lifecycles (retire_overlay / cleanup_service_cache_dir) and the same
        // Compiler instance serves both full-render and preview requests, so
        // deleting pages from a previous compile would race with the terminal
        // still reading those files via the kitty graphics protocol.

        self.prev_frame_hashes = new_frame_hashes;
        self.prev_page_paths = new_paths;
        self.prev_page_dims = new_dims;
        self.prev_ppi = ppi;

        CompileResponse {
            request_id,
            status: CompileStatus::Ok,
            pages,
            diagnostics,
            compile_us: Some(compile_us),
            render_us: Some(render_us),
            rendered_pages: Some(rendered_count),
        }
    }

    fn format_diagnostics<'a>(
        &self,
        diagnostics: impl IntoIterator<Item = &'a SourceDiagnostic>,
    ) -> Vec<DiagnosticInfo> {
        diagnostics
            .into_iter()
            .map(|diag| {
                let (file, line, column) = self.world.position(diag.span);
                DiagnosticInfo {
                    message: diag.message.to_string(),
                    severity: match diag.severity {
                        Severity::Error => "error",
                        Severity::Warning => "warning",
                    }
                    .to_string(),
                    file,
                    line,
                    column,
                }
            })
            .collect()
    }
}

fn write_pixmap_png(
    path: &std::path::Path,
    pixmap: &tiny_skia::Pixmap,
) -> Result<(), Box<dyn std::error::Error>> {
    let file = fs::File::create(path)?;
    let rgba = unpremultiply_to_rgba(pixmap);
    PngEncoder::new_with_quality(file, CompressionType::Fast, FilterType::NoFilter).write_image(
        &rgba,
        pixmap.width(),
        pixmap.height(),
        ColorType::Rgba8.into(),
    )?;
    Ok(())
}

fn unpremultiply_to_rgba(pixmap: &tiny_skia::Pixmap) -> Vec<u8> {
    let mut out = Vec::with_capacity(pixmap.data().len());
    for pixel in pixmap.pixels() {
        let alpha = pixel.alpha();
        if alpha == 0 {
            out.extend_from_slice(&[0, 0, 0, 0]);
        } else {
            out.push(unpremultiply(pixel.red(), alpha));
            out.push(unpremultiply(pixel.green(), alpha));
            out.push(unpremultiply(pixel.blue(), alpha));
            out.push(alpha);
        }
    }
    out
}

fn unpremultiply(channel: u8, alpha: u8) -> u8 {
    let value = (u16::from(channel) * 255 + u16::from(alpha) / 2) / u16::from(alpha);
    value.min(255) as u8
}
