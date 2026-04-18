use std::collections::HashMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum IncomingMessage {
    #[serde(rename = "compile")]
    Compile(CompileRequest),
    #[serde(rename = "shutdown")]
    Shutdown,
}

#[derive(Debug, Deserialize)]
pub struct CompileRequest {
    pub request_id: String,
    #[serde(default)]
    pub cache_key: Option<String>,
    pub source_text: String,
    pub root: PathBuf,
    #[serde(default)]
    pub inputs: HashMap<String, String>,
    pub output_dir: PathBuf,
    pub ppi: u32,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum OutgoingMessage {
    #[serde(rename = "compile_result")]
    CompileResult(CompileResponse),
}

#[derive(Debug, Serialize)]
pub struct CompileResponse {
    pub request_id: String,
    pub status: CompileStatus,
    pub pages: Vec<PageResult>,
    pub diagnostics: Vec<DiagnosticInfo>,
    /// Microseconds spent in typst::compile().
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compile_us: Option<u64>,
    /// Microseconds spent rendering pages to PNG.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub render_us: Option<u64>,
    /// Number of pages that were re-rendered (not cached).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rendered_pages: Option<usize>,
}

#[derive(Debug, Serialize)]
pub enum CompileStatus {
    #[serde(rename = "ok")]
    Ok,
    #[serde(rename = "error")]
    Error,
}

#[derive(Debug, Serialize)]
pub struct PageResult {
    pub page_index: usize,
    pub path: PathBuf,
    pub width_px: u32,
    pub height_px: u32,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub cached: bool,
}

#[derive(Debug, Serialize)]
pub struct DiagnosticInfo {
    pub message: String,
    pub severity: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<PathBuf>,
    pub line: Option<usize>,
    pub column: Option<usize>,
}
