"""python -m rlcd.benchmark --device mps --output results/m2-max.json"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
import platform
import random
import statistics
import subprocess
import time
from pathlib import Path
import jsonschema
import numpy as np
import torch
from .engine import Engine, MODEL_ID, REVISION
from .tasks import CASES


def evaluate(text, schema, expected):
    try:
        obj = json.loads(text, parse_constant=lambda s: (_ for _ in ()).throw(ValueError(s)))
        syntax = True
    except (ValueError, TypeError):
        obj, syntax = None, False
    compliant = syntax and jsonschema.Draft202012Validator(schema).is_valid(obj)
    correct = sum(type(obj.get(k)) is type(v) and obj.get(k) == v for k, v in expected.items()) if isinstance(obj, dict) else 0
    return {"syntax_valid": syntax, "schema_compliant": compliant, "correct_fields": correct,
            "field_count": len(expected), "exact_match": compliant and correct == len(expected)}


def metadata(engine):
    info = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(),
            "all_dependencies": {d.metadata["Name"]:d.version for d in importlib.metadata.distributions()},
            "platform": platform.platform(), "python": platform.python_version(),
            "versions": {k: importlib.metadata.version(k) for k in ["torch", "transformers", "accelerate", "huggingface-hub", "jsonschema", "modal"]},
            "device": engine.device, "dtype": engine.dtype, "attention": "eager", "quantization": None,
            "model": MODEL_ID, "revision": REVISION, "cuda_runtime": torch.version.cuda,
            "mps_available": torch.backends.mps.is_available(),
            "source_sha256": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path(__file__).parent.glob("*.py"))}}
    if engine.device == "mps":
        info["hardware"] = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip()
        info["memory_bytes"] = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))
    if engine.device.startswith("cuda"):
        info["hardware"] = torch.cuda.get_device_name()
        info["gpu_info"] = subprocess.check_output(["nvidia-smi", "--query-gpu=name,driver_version,memory.total", "--format=csv,noheader"], text=True).strip()
        info["tf32_matmul"] = torch.backends.cuda.matmul.allow_tf32
    return info


def summarize(rows):
    result = {}
    for method in ["constrained", "autoregressive"]:
        selected = [r for r in rows if r["method"] == method]
        times = [r["latency_ms"] for r in selected]
        result[method] = {"n": len(times), "latency_mean_ms": statistics.mean(times),
                          "latency_median_ms": statistics.median(times), "latency_p95_ms": float(np.percentile(times, 95)),
                          "syntax_valid_rate": statistics.mean(r["syntax_valid"] for r in selected),
                          "schema_compliant_rate": statistics.mean(r["schema_compliant"] for r in selected),
                          "field_accuracy": sum(r["correct_fields"] for r in selected) / sum(r["field_count"] for r in selected),
                          "exact_match_rate": statistics.mean(r["exact_match"] for r in selected)}
    result["speedup_ratio_of_mean_latency"] = result["autoregressive"]["latency_mean_ms"] / result["constrained"]["latency_mean_ms"]
    return result


def run(device="mps", dtype="float16", warmups=2, repeats=3, limit=None, suite="diagnostic", max_new_tokens=192):
    torch.manual_seed(42)
    torch.set_num_threads(4)
    engine = Engine(device, dtype)
    if warmups < 1 or repeats < 2:
        raise ValueError("Use at least one warmup and two measured repetitions")
    from .stress_tasks import CASES as STRESS_CASES
    all_cases = CASES if suite == "diagnostic" else STRESS_CASES
    cases = all_cases[:limit] if limit else all_cases
    def invoke(method, context, schema):
        kwargs = {"max_new_tokens": max_new_tokens} if method == "autoregressive" else {}
        return getattr(engine, method)(context, schema, **kwargs)
    # Warm every case and both methods, then discard timings.
    for _ in range(warmups):
        for _, schema, context, _ in cases:
            for method in ["constrained", "autoregressive"]:
                invoke(method, context, schema)
        engine.sync()
    rows = []
    for rep in range(repeats):
        order = list(cases)
        random.Random(42 + rep).shuffle(order)
        for case_id, schema, context, expected in order:
            methods = ["constrained", "autoregressive"]
            if (rep + all_cases.index(next(c for c in all_cases if c[0] == case_id))) % 2:
                methods.reverse()
            for method in methods:
                engine.sync()
                started = time.perf_counter()
                output = invoke(method, context, schema)
                engine.sync()
                latency = (time.perf_counter() - started) * 1000
                row = {"case": case_id, "repeat": rep, "method": method, "latency_ms": latency,
                       **output, **evaluate(output["text"], schema, expected)}
                rows.append(row)
                print(f'{device} {rep} {case_id} {method}: {latency:.1f}ms exact={row["exact_match"]}', flush=True)
    return {"metadata": metadata(engine), "protocol": {"warmups_per_case_per_method": warmups, "repeats": repeats,
            "seed": 42, "max_new_tokens": max_new_tokens, "suite": suite, "timing": "synchronized end-to-end request; includes tokenization, cache copy, model calls, scoring, decode/assembly; excludes model load and validation",
            "cases": len(cases), "order": "seeded shuffled cases; alternating paired method order", "batch_size_requests": 1},
            "summary": summarize(rows), "rows": rows}

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--device", default="mps")
    p.add_argument("--dtype", default="float16", choices=["float16", "bfloat16", "float32"])
    p.add_argument("--warmups", type=int, default=2)
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--limit", type=int)
    p.add_argument("--suite", choices=["diagnostic", "stress"], default="diagnostic")
    p.add_argument("--max-new-tokens", type=int, default=192)
    p.add_argument("--output", default="results/m2-max.json")
    args = vars(p.parse_args())
    output = Path(args.pop("output"))
    result = run(**args)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))
