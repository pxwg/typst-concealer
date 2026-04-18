#!/usr/bin/env python3
"""Benchmark: typst-concealer-service incremental compile latency.

Generates a multi-page Typst document (simulating many formulas),
then sends it to the service: first cold, then incremental (one changed).

Usage:  python3 tests/bench_service.py [NUM_PAGES]
"""

import json
import os
import subprocess
import sys
import tempfile
import time

SERVICE = os.path.join(os.path.dirname(__file__), "..", "service", "target", "release", "typst-concealer-service")
TYPST = os.environ.get("TYPST", "typst")
NUM_PAGES = int(sys.argv[1]) if len(sys.argv) > 1 else 20


def build_stable_main(num_pages: int) -> str:
    lines = ['#include "/.typst-concealer/bench/full/context.typ"']
    for i in range(1, num_pages + 1):
        if i > 1:
            lines.append("#pagebreak()")
        lines.append(f'#include "/.typst-concealer/bench/full/slots/slot-{i:06d}.typ"')
    return "\n".join(lines)


def write_if_changed(path: str, text: str) -> None:
    try:
        with open(path, "r") as f:
            if f.read() == text:
                return
    except FileNotFoundError:
        pass
    with open(path, "w") as f:
        f.write(text)


def write_sidecars(root: str, num_pages: int, vary: str = "") -> str:
    full_dir = os.path.join(root, ".typst-concealer", "bench", "full")
    slots_dir = os.path.join(full_dir, "slots")
    os.makedirs(slots_dir, exist_ok=True)
    write_if_changed(
        os.path.join(full_dir, "context.typ"),
        "#set page(width: 400pt, height: auto, margin: 0pt)\n",
    )
    for i in range(1, num_pages + 1):
        path = os.path.join(slots_dir, f"slot-{i:06d}.typ")
        if i == 1 and vary:
            text = f"$ alpha + beta + gamma + delta + {vary} $\n"
        else:
            text = f"$ alpha^{i} + sin(x_{i}) + integral_0^1 f(t) dif t $\n"
        write_if_changed(path, text)
    return build_stable_main(num_pages)


def main():
    with tempfile.TemporaryDirectory() as tmpdir:
        output_dir = os.path.join(tmpdir, "out")
        os.makedirs(output_dir)

        print(f"=== typst-concealer-service benchmark ===")
        print(f"  pages: {NUM_PAGES}")
        print(f"  service: {SERVICE}")
        print()

        # Start service
        proc = subprocess.Popen(
            [SERVICE],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        def send_request(req_id: str, doc: str) -> dict:
            req = json.dumps({
                "type": "compile",
                "request_id": req_id,
                "source_text": doc,
                "root": tmpdir,
                "inputs": {},
                "output_dir": output_dir,
                "ppi": 144,
            })
            t0 = time.monotonic_ns()
            proc.stdin.write((req + "\n").encode())
            proc.stdin.flush()
            line = proc.stdout.readline()
            t1 = time.monotonic_ns()
            resp = json.loads(line)
            resp["_wall_ns"] = t1 - t0
            return resp

        def fmt_us(us):
            if us is None:
                return "N/A"
            if us >= 1_000_000:
                return f"{us / 1_000_000:.1f}s"
            if us >= 1000:
                return f"{us / 1000:.1f}ms"
            return f"{us}μs"

        def print_result(label, resp):
            wall_us = resp["_wall_ns"] // 1000
            compile_us = resp.get("compile_us")
            render_us = resp.get("render_us")
            rendered = resp.get("rendered_pages", "?")
            total = len(resp.get("pages", []))
            overhead_us = wall_us - (compile_us or 0) - (render_us or 0)
            print(f"  {label:20s}  wall={fmt_us(wall_us):>10s}  compile={fmt_us(compile_us):>10s}  render={fmt_us(render_us):>10s}  overhead={fmt_us(overhead_us):>10s}  rendered={rendered}/{total}")

        # --- Cold compile ---
        print(f"--- Cold compile ({NUM_PAGES} pages) ---")
        doc_cold = write_sidecars(tmpdir, NUM_PAGES)
        r = send_request("cold", doc_cold)
        print_result("cold", r)

        # --- Incremental: change 1 page ---
        print(f"\n--- Incremental compile (1 page changed out of {NUM_PAGES}) ---")
        for i in range(1, 11):
            doc_inc = write_sidecars(tmpdir, NUM_PAGES, f"epsilon_{i}")
            r = send_request(f"inc_{i}", doc_inc)
            print_result(f"incremental_{i}", r)

        # --- No change ---
        print(f"\n--- No-op compile (0 pages changed) ---")
        doc_same = write_sidecars(tmpdir, NUM_PAGES, "epsilon_10")
        for i in range(1, 6):
            r = send_request(f"noop_{i}", doc_same)
            print_result(f"noop_{i}", r)

        # Shutdown
        proc.stdin.write(b'{"type":"shutdown"}\n')
        proc.stdin.flush()
        proc.wait(timeout=5)

        # --- typst compile reference ---
        print(f"\n--- typst compile reference (cold, separate process) ---")
        bench_path = os.path.join(tmpdir, "bench.typ")
        with open(bench_path, "w") as f:
            f.write(build_stable_main(NUM_PAGES))
        t0 = time.monotonic_ns()
        subprocess.run(
            [TYPST, "compile", bench_path, os.path.join(tmpdir, "bench-{n}.png"), "--ppi", "144"],
            capture_output=True,
        )
        t1 = time.monotonic_ns()
        print(f"  {'typst compile':20s}  wall={fmt_us((t1 - t0) // 1000):>10s}  (no comemo, fresh process)")

        print("\nDone.")


if __name__ == "__main__":
    main()
