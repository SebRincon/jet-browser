"""Overlapping-tag diagnostic for workflow model.classify with a local model.

Runs Jet's real WorkflowCapabilities.model_classify over the synthetic corpus in
backend/tests/fixtures/tagging/, recording each tag's yes-probability. It reports the
shipped decision (the model's own yes/no label), chooses one yes-probability threshold
on the calibration split only, then scores the frozen held-out split once with both.
No browser, no remote provider, no user data. Loads local weights (SemIf 4B by default).

    python scripts/eval_tagging.py [--model qwen4b_semif_shared] [--output PATH]
"""

import argparse
import asyncio
import json
import os
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
# Development engine subprocesses import jet_browser; the dev launcher normally sets this.
os.environ["PYTHONPATH"] = os.pathsep.join(filter(None, [str(ROOT / "backend"), os.environ.get("PYTHONPATH")]))

from jet_browser.workflow_capabilities import WorkflowCapabilities
from jev_ultrafast.local_models import NativeWorker

CORPUS = ROOT / "backend/tests/fixtures/tagging/bookmarks-tags-v1.json"
START_URL = "https://x.com/i/bookmarks"


class RecordingWorker:
    """Passes calls to the real worker and keeps each question's yes-probability."""

    def __init__(self, worker):
        self.worker = worker
        self.lock = worker.lock
        self.probabilities = {}

    def predict(self, mode, request):
        result = self.worker.predict(mode, request)
        for question, answer in (result.get("answers") or {}).items():
            yes = (answer.get("probabilities") or {}).get("yes")
            if yes is not None:
                # A tag is positive if any chunk says yes, so keep the maximum.
                self.probabilities[question] = max(yes, self.probabilities.get(question, 0.0))
        return result


def capability(model, taxonomy, worker):
    tab = {"id": "tab", "url": START_URL}
    bridge = SimpleNamespace(host_id="eval", tabs=[tab], tab=lambda _tid: tab)
    service = SimpleNamespace(store=SimpleNamespace(current_id="eval"), bridge=bridge)
    cap = WorkflowCapabilities(service, None, "eval", "0" * 32, threading.Event(),
                               lambda *_args: None, worker=worker)
    cap.definition = {"model": model, "categories": taxonomy}
    cap.tab_id, cap.start_url, cap._host = "tab", START_URL, "eval"
    return cap


def scores(rows, tags, decide):
    tp = {tag: 0 for tag in tags}
    fp = dict(tp)
    fn = dict(tp)
    exact = 0
    for row in rows:
        predicted = {tag for tag in tags if decide(row, tag)}
        gold = set(row["gold"])
        exact += predicted == gold
        for tag in tags:
            tp[tag] += tag in predicted and tag in gold
            fp[tag] += tag in predicted and tag not in gold
            fn[tag] += tag not in predicted and tag in gold

    def f1(t, p, n):
        return 2 * t / (2 * t + p + n) if t + p + n else 1.0

    per_tag = {tag: {"precision": round(tp[tag] / (tp[tag] + fp[tag]), 3) if tp[tag] + fp[tag] else None,
                     "recall": round(tp[tag] / (tp[tag] + fn[tag]), 3) if tp[tag] + fn[tag] else None,
                     "f1": round(f1(tp[tag], fp[tag], fn[tag]), 3)} for tag in tags}
    total_tp, total_fp, total_fn = sum(tp.values()), sum(fp.values()), sum(fn.values())
    return {"items": len(rows), "exact_match": round(exact / len(rows), 3),
            "micro_precision": round(total_tp / (total_tp + total_fp), 3) if total_tp + total_fp else None,
            "micro_recall": round(total_tp / (total_tp + total_fn), 3) if total_tp + total_fn else None,
            "micro_f1": round(f1(total_tp, total_fp, total_fn), 3),
            "macro_f1": round(sum(v["f1"] for v in per_tag.values()) / len(tags), 3),
            "false_positive_tags": total_fp, "missed_tags": total_fn, "per_tag": per_tag}


async def run(model):
    corpus = json.loads(CORPUS.read_text())
    taxonomy = corpus["taxonomy"]
    tags = [category["id"] for category in taxonomy]
    native = NativeWorker()
    rows = []
    try:
        for case in corpus["cases"]:
            worker = RecordingWorker(native)
            cap = capability(model, taxonomy, worker)
            cap._items[case["id"]] = {"id": case["id"], "text": case["text"], "url": START_URL}
            started = time.perf_counter()
            result = await cap.model_classify({"item_id": case["id"]})
            rows.append({"id": case["id"], "split": case["split"], "gold": case["tags"], "tags": result["tags"],
                         "yes": {tag: round(worker.probabilities.get(tag, 0.0), 4) for tag in tags},
                         "unknown_tags": result["unknown_tags"], "model": result["model"],
                         "ms": round((time.perf_counter() - started) * 1000, 1)})
            print(case["id"], "gold", case["tags"], "got", result["tags"], flush=True)
    finally:
        native.close()

    split = {name: [row for row in rows if row["split"] == name] for name in ("development", "calibration", "held_out")}
    shipped = lambda row, tag: tag in row["tags"]
    thresholds = [round(0.05 * step, 2) for step in range(1, 20)]
    sweep = {t: scores(split["calibration"], tags, lambda row, tag, t=t: row["yes"][tag] >= t)["micro_f1"]
             for t in thresholds}
    best = max(thresholds, key=lambda t: (sweep[t], -abs(t - 0.5)))
    report = {
        "kind": "synthetic overlapping-tag diagnostic; not user data and not a whole-browser benchmark",
        "corpus": str(CORPUS.relative_to(ROOT)), "model": model,
        "model_identity": rows[0]["model"] if rows else None,
        "shipped_decision": {name: scores(items, tags, shipped) for name, items in split.items()},
        "calibration_threshold_sweep_micro_f1": sweep,
        "selected_threshold": best,
        "held_out_with_selected_threshold": scores(split["held_out"], tags,
                                                   lambda row, tag: row["yes"][tag] >= best),
        "warm_median_ms": sorted(row["ms"] for row in rows[1:])[len(rows[1:]) // 2] if len(rows) > 1 else None,
        "rows": rows,
    }
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default="qwen4b_semif_shared")
    parser.add_argument("--output", type=Path,
                        default=ROOT / ".runtime/artifacts" / ("tagging-" + time.strftime("%Y%m%d-%H%M%S") + ".json"))
    args = parser.parse_args()
    report = asyncio.run(run(args.model))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=1) + "\n")
    summary = {key: report[key] for key in ("model", "selected_threshold", "warm_median_ms")}
    summary["shipped"] = {name: {k: v[k] for k in ("exact_match", "micro_f1", "macro_f1", "false_positive_tags", "missed_tags")}
                          for name, v in report["shipped_decision"].items()}
    tuned = report["held_out_with_selected_threshold"]
    summary["held_out_tuned"] = {k: tuned[k] for k in ("exact_match", "micro_f1", "macro_f1", "false_positive_tags", "missed_tags")}
    print(json.dumps(summary, indent=1))
    print("REPORT", args.output)


if __name__ == "__main__":
    main()
