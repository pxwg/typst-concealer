mod compiler;
mod protocol;
mod world;

use std::collections::HashMap;
use std::io::{self, BufRead, Write};

use compiler::Compiler;
use protocol::{IncomingMessage, OutgoingMessage};

const MAX_COMPILERS: usize = 16;

struct CachedCompiler {
    compiler: Compiler,
    last_used: u64,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout());
    let mut compilers: HashMap<String, CachedCompiler> = HashMap::new();
    let mut use_clock: u64 = 0;

    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let msg: IncomingMessage = match serde_json::from_str(&line) {
            Ok(msg) => msg,
            Err(err) => {
                eprintln!("failed to decode request: {err}");
                continue;
            }
        };

        match msg {
            IncomingMessage::Compile(req) => {
                let cache_key = req
                    .cache_key
                    .clone()
                    .unwrap_or_else(|| "default".to_string());
                use_clock = use_clock.saturating_add(1);
                let compiler = compilers.entry(cache_key.clone()).or_insert_with(|| CachedCompiler {
                    compiler: Compiler::new(),
                    last_used: use_clock,
                });
                compiler.last_used = use_clock;
                let resp = compiler.compiler.compile(req);
                evict_stale_compilers(&mut compilers, &cache_key);
                serde_json::to_writer(&mut stdout, &OutgoingMessage::CompileResult(resp))?;
                stdout.write_all(b"\n")?;
                stdout.flush()?;
            }
            IncomingMessage::Shutdown => break,
        }
    }

    Ok(())
}

fn evict_stale_compilers(compilers: &mut HashMap<String, CachedCompiler>, active_key: &str) {
    while compilers.len() > MAX_COMPILERS {
        let Some(evict_key) = compilers
            .iter()
            .filter(|(key, _)| key.as_str() != active_key)
            .min_by_key(|(_, compiler)| compiler.last_used)
            .map(|(key, _)| key.clone())
        else {
            break;
        };
        compilers.remove(&evict_key);
    }
}
