mod compiler;
mod protocol;
mod world;

use std::collections::HashMap;
use std::io::{self, BufRead, Write};

use compiler::Compiler;
use protocol::{IncomingMessage, OutgoingMessage};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout());
    let mut compilers: HashMap<String, Compiler> = HashMap::new();

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
                let compiler = compilers.entry(cache_key).or_insert_with(Compiler::new);
                let resp = compiler.compile(req);
                serde_json::to_writer(&mut stdout, &OutgoingMessage::CompileResult(resp))?;
                stdout.write_all(b"\n")?;
                stdout.flush()?;
            }
            IncomingMessage::Shutdown => break,
        }
    }

    Ok(())
}
