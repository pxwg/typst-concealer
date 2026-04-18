#!/usr/bin/env bash
# Benchmark: typst-concealer-service incremental compile latency.
#
# Generates a multi-page Typst document (simulating many formulas),
# then sends it to the service twice — first cold, then incremental
# (one formula changed). Also benchmarks typst compile for reference.
#
# Usage:  bash tests/bench.sh [NUM_PAGES]

set -euo pipefail

SERVICE="./service/target/release/typst-concealer-service"
TYPST="${TYPST:-typst}"
NUM_PAGES="${1:-20}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== typst-concealer-service benchmark ==="
echo "  pages: $NUM_PAGES"
echo "  tmpdir: $TMPDIR"
echo ""

# Generate a document with NUM_PAGES pages, each a simple math formula.
generate_doc() {
  local vary="$1"  # if non-empty, modify page 1
  echo '#set page(width: 400pt, height: auto, margin: 0pt)'
  for i in $(seq 1 "$NUM_PAGES"); do
    if [ "$i" -eq 1 ] && [ -n "$vary" ]; then
      echo "#pagebreak(weak: true)"
      echo "\$ alpha + beta + gamma + delta + ${vary} \$"
    else
      echo "#pagebreak(weak: true)"
      echo "\$ alpha^${i} + sin(x_${i}) + integral_0^1 f(t) dif t \$"
    fi
  done
}

OUTPUT_DIR="$TMPDIR/out"
mkdir -p "$OUTPUT_DIR"

# --- Service benchmark ---
echo "--- Service: cold compile ($NUM_PAGES pages) ---"

# Start service in background, feeding requests through a named pipe.
FIFO="$TMPDIR/fifo"
mkfifo "$FIFO"
RESP="$TMPDIR/resp"

"$SERVICE" < "$FIFO" > "$RESP" &
SVC_PID=$!

# Helper: send a compile request and measure time.
send_request() {
  local req_id="$1"
  local doc="$2"
  local json
  json=$(python3 -c "
import json, sys
doc = sys.stdin.read()
print(json.dumps({
    'type': 'compile',
    'request_id': '$req_id',
    'source_text': doc,
    'root': '$TMPDIR',
    'inputs': {},
    'output_dir': '$OUTPUT_DIR',
    'ppi': 144
}))
" <<< "$doc")

  local t0
  t0=$(python3 -c "import time; print(int(time.monotonic_ns()))")
  echo "$json" > "$FIFO"

  # Read response line
  local resp_line
  resp_line=$(head -1 "$RESP")
  local t1
  t1=$(python3 -c "import time; print(int(time.monotonic_ns()))")

  local wall_ms
  wall_ms=$(python3 -c "print(f'{($t1 - $t0) / 1e6:.1f}')")

  # Extract timing from response
  local compile_us render_us rendered_pages
  compile_us=$(echo "$resp_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('compile_us','?'))")
  render_us=$(echo "$resp_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('render_us','?'))")
  rendered_pages=$(echo "$resp_line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('rendered_pages','?'))")

  echo "  request=$req_id  wall=${wall_ms}ms  compile=${compile_us}μs  render=${render_us}μs  rendered=${rendered_pages}/${NUM_PAGES}"
}

# Use a subprocess to manage the FIFO writes
{
  # Cold compile
  DOC_COLD=$(generate_doc "")
  send_request "cold" "$DOC_COLD"

  echo ""
  echo "--- Service: incremental compile (1 page changed) ---"

  # Incremental: change only page 1
  for i in $(seq 1 5); do
    DOC_INC=$(generate_doc "epsilon_${i}")
    send_request "inc_${i}" "$DOC_INC"
  done

  echo ""
  echo "--- Service: no-change compile (0 pages changed) ---"

  # No change: send same document again
  DOC_SAME=$(generate_doc "epsilon_5")
  for i in $(seq 1 3); do
    send_request "noop_${i}" "$DOC_SAME"
  done

  # Shutdown
  echo '{"type":"shutdown"}' > "$FIFO"
}

wait $SVC_PID 2>/dev/null || true

echo ""
echo "--- typst compile reference (cold) ---"

# Write a reference document
generate_doc "" > "$TMPDIR/bench.typ"
t0=$(python3 -c "import time; print(int(time.monotonic_ns()))")
"$TYPST" compile "$TMPDIR/bench.typ" "$TMPDIR/bench-{n}.png" --ppi 144 2>/dev/null
t1=$(python3 -c "import time; print(int(time.monotonic_ns()))")
echo "  wall=$(python3 -c "print(f'{($t1 - $t0) / 1e6:.1f}')")ms"

echo ""
echo "--- typst compile reference (incremental via typst compile) ---"
generate_doc "epsilon_1" > "$TMPDIR/bench.typ"
t0=$(python3 -c "import time; print(int(time.monotonic_ns()))")
"$TYPST" compile "$TMPDIR/bench.typ" "$TMPDIR/bench-{n}.png" --ppi 144 2>/dev/null
t1=$(python3 -c "import time; print(int(time.monotonic_ns()))")
echo "  wall=$(python3 -c "print(f'{($t1 - $t0) / 1e6:.1f}')")ms  (no comemo - fresh process)"

echo ""
echo "Done."
