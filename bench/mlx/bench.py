# /// script
# requires-python = ">=3.11"
# dependencies = ["mlx-lm>=0.28"]
# ///
"""Замер MLX: инференс и LoRA на одной машине (хост или macOS VM).

Запуск:  uv run bench/mlx/bench.py --label host --out results/host.json
Сравнение: uv run bench/mlx/compare.py results/*.json
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

DEFAULT_MODEL = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
PROMPT = "Explain, step by step, how a CPU cache hierarchy works and why it matters for performance."


def sysctl(name: str) -> str:
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def environment() -> dict:
    import mlx.core as mx

    info = mx.device_info() if mx.metal.is_available() else {}
    return {
        "chip": sysctl("machdep.cpu.brand_string"),
        "cpus": sysctl("hw.ncpu"),
        "memory_gb": round(int(sysctl("hw.memsize") or 0) / 2**30, 1),
        "macos": platform.mac_ver()[0],
        # 1 внутри гостя Virtualization.framework / Hypervisor.framework.
        "virtualized": sysctl("kern.hv_vmm_present") == "1",
        "metal": mx.metal.is_available(),
        "gpu": info.get("device_name", ""),
        "mlx": mx.__version__,
    }


def bench_inference(model_id: str, max_tokens: int, runs: int) -> dict:
    import mlx.core as mx
    from mlx_lm import load, stream_generate

    t0 = time.perf_counter()
    model, tokenizer = load(model_id)
    load_s = time.perf_counter() - t0

    prompt = tokenizer.apply_chat_template(
        [{"role": "user", "content": PROMPT}], add_generation_prompt=True, tokenize=False
    )
    # Прогрев: компиляция шейдеров и первые аллокации не должны попадать в замер.
    for _ in stream_generate(model, tokenizer, prompt, max_tokens=16):
        pass

    samples = []
    for _ in range(runs):
        mx.reset_peak_memory()
        last = None
        for last in stream_generate(model, tokenizer, prompt, max_tokens=max_tokens):
            pass
        samples.append(
            {
                "prompt_tps": last.prompt_tps,
                "generation_tps": last.generation_tps,
                "generated_tokens": last.generation_tokens,
                "peak_memory_gb": last.peak_memory,
            }
        )

    best = max(samples, key=lambda s: s["generation_tps"])
    return {"load_s": round(load_s, 2), "runs": samples, "best": best}


def write_dataset(path: Path, n_train: int = 200, n_valid: int = 20) -> None:
    # Синтетический датасет: содержание не важно, важна стабильная длина последовательностей.
    line = "The quick brown fox jumps over the lazy dog while the compiler links object files. "
    for name, n in (("train", n_train), ("valid", n_valid)):
        with open(path / f"{name}.jsonl", "w") as f:
            for i in range(n):
                f.write(json.dumps({"text": f"Example {i}: " + line * 6}) + "\n")


ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
# mlx-lm < 0.30: "Iter 10: Train loss 2.345, …, It/sec 3.210, Tokens/sec 1234.5, …, Peak mem 1.234 GB"
LEGACY_ITER_RE = re.compile(r"Iter (\d+): Train loss ([\d.]+).*?It/sec ([\d.]+), Tokens/sec ([\d.]+)")
# mlx-lm >= 0.30 prints a table: "  10    0.605 ▼    699    4.1k" (iter, loss, tok/s, trained tokens).
TABLE_ITER_RE = re.compile(r"^\s*(\d+)\s+([\d.]+)\s+[▼▲=]?\s*([\d,.]+)\s+([\d.]+k?)\s*$", re.M)
# /usr/bin/time -l: physical footprint includes Metal buffers, unlike max RSS.
FOOTPRINT_RE = re.compile(r"(\d+)\s+peak memory footprint")


def parse_tokens(text: str) -> float:
    return float(text[:-1]) * 1000 if text.endswith("k") else float(text)


def parse_lora_reports(output: str, batch_size: int) -> list[dict]:
    output = ANSI_RE.sub("", output)
    reports = [
        {"iter": int(m[1]), "loss": float(m[2]), "it_per_s": float(m[3]), "tokens_per_s": float(m[4])}
        for m in LEGACY_ITER_RE.finditer(output)
    ]
    if reports:
        return reports
    prev_iter, prev_tokens = 0, 0.0
    for m in TABLE_ITER_RE.finditer(output):
        it, tokens_per_s, tokens = int(m[1]), float(m[3].replace(",", "")), parse_tokens(m[4])
        tokens_per_iter = (tokens - prev_tokens) / max(it - prev_iter, 1)
        reports.append({
            "iter": it,
            "loss": float(m[2]),
            "it_per_s": round(tokens_per_s / tokens_per_iter, 3) if tokens_per_iter else 0.0,
            "tokens_per_s": tokens_per_s,
        })
        prev_iter, prev_tokens = it, tokens
    return reports


def bench_lora(model_id: str, iters: int, batch_size: int, num_layers: int) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        data = Path(tmp) / "data"
        data.mkdir()
        write_dataset(data)
        cmd = [
            "/usr/bin/time", "-l",
            sys.executable, "-m", "mlx_lm", "lora",
            "--model", model_id,
            "--train",
            "--data", str(data),
            "--iters", str(iters),
            "--batch-size", str(batch_size),
            "--num-layers", str(num_layers),
            "--steps-per-report", "10",
            "--steps-per-eval", str(iters * 10),
            "--val-batches", "1",
            "--adapter-path", str(Path(tmp) / "adapters"),
        ]
        t0 = time.perf_counter()
        proc = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, "NO_COLOR": "1"})
        wall_s = time.perf_counter() - t0
        if proc.returncode != 0:
            raise RuntimeError(f"mlx_lm lora failed:\n{proc.stdout}\n{proc.stderr}")

    output = proc.stdout + proc.stderr
    reports = parse_lora_reports(output, batch_size)
    if not reports:
        raise RuntimeError(f"no iteration reports in mlx_lm output:\n{proc.stdout}\n{proc.stderr}")
    # Первый отчёт включает прогрев, в среднее его не берём.
    steady = reports[1:] or reports
    return {
        "iters": iters,
        "batch_size": batch_size,
        "num_layers": num_layers,
        "wall_s": round(wall_s, 1),
        "reports": reports,
        "it_per_s": round(sum(r["it_per_s"] for r in steady) / len(steady), 3),
        "tokens_per_s": round(sum(r["tokens_per_s"] for r in steady) / len(steady), 1),
        "peak_memory_gb": round(int(m[1]) / 2**30, 2) if (m := FOOTPRINT_RE.search(output)) else None,
    }


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--label", required=True, help="имя прогона в таблице, например host или vm")
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--max-tokens", type=int, default=256)
    p.add_argument("--runs", type=int, default=3)
    p.add_argument("--lora-iters", type=int, default=60)
    p.add_argument("--lora-batch-size", type=int, default=4)
    p.add_argument("--lora-layers", type=int, default=8)
    p.add_argument("--skip-lora", action="store_true")
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()

    result = {
        "label": args.label,
        "model": args.model,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "env": environment(),
    }
    print(f"[{args.label}] inference…", file=sys.stderr)
    result["inference"] = bench_inference(args.model, args.max_tokens, args.runs)
    if not args.skip_lora:
        print(f"[{args.label}] lora…", file=sys.stderr)
        result["lora"] = bench_lora(args.model, args.lora_iters, args.lora_batch_size, args.lora_layers)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(f"[{args.label}] → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
