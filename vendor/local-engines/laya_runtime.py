import os
"""Pinned native Laya-MLX runtime and transparent prompt-budget audit.

API and formatting: https://github.com/mizorewww/laya-mlx/tree/0a859518634112655cb97c745dbf04f5191aaf13
No inference source changes, calibration overrides, or model-key access.
"""
import argparse
import json
from pathlib import Path
import time

ROOT = Path(os.environ.get("JET_DATA_ROOT", Path(__file__).resolve().parents[2]))
MODEL_ID = "aac6fef/laya-mlx"
REVISION = "047678560251f28113ee8f5df4be82102c7bf336"


def load_agent():
    import laya_mlx
    return laya_mlx.load(ROOT / "models/laya-english", dtype="float16", device="gpu",
                         batch_size=16, compile=False, cache_prompts=False)


def audit_prompt(agent, state, questions):
    """Measure removed state/instruction/option tokens without changing model input.

    Compare original token sequences with the author's actual prefix. The audit
    is performed outside inference timing and includes the 48-token option cap.
    """
    from laya_mlx.common import build_prefix, render_options, serialize_state
    audits = {}
    tok = agent.tok
    state_ids = tok(serialize_state(state).replace(tok.mask_token, " "))["input_ids"]
    for key, definition in questions.items():
        question = agent._to_internal(definition)
        prefix, markers = build_prefix(tok, question, agent.cfg["head_max_len"])
        instruction_ids = tok(f"{question['t']} question: {question['ins'].replace(tok.mask_token, ' ')}")["input_ids"]
        instruction_kept = markers[0] - 2
        options = []
        for i, text in enumerate(render_options(question)):
            original = tok(" " + text.replace(tok.mask_token, " "))["input_ids"]
            end = markers[i+1] if i+1 < len(markers) else len(prefix)-1
            kept = prefix[markers[i]+1:end]
            assert original[:len(kept)] == kept
            options.append({"original": len(original), "kept": len(kept)})
        room = max(0, agent.cfg["max_len"]-len(prefix)-1)
        state_kept = min(len(state_ids), room)
        state_cut = state_kept < len(state_ids)
        instruction_cut = instruction_kept < len(instruction_ids)
        option_cut = any(o["original"] > o["kept"] for o in options)
        audits[key] = {"max_len": agent.cfg["max_len"], "head_max_len": agent.cfg["head_max_len"],
                       "prefix_tokens": len(prefix), "input_tokens": len(prefix)+state_kept+1,
                       "state_tokens_original": len(state_ids), "state_tokens_kept": state_kept,
                       "instruction_tokens_original": len(instruction_ids), "instruction_tokens_kept": instruction_kept,
                       "options": options, "state_truncated": state_cut,
                       "instructions_truncated": instruction_cut, "options_truncated": option_cut,
                       "truncated": state_cut or instruction_cut or option_cut}
    return audits


def schema_questions(schema):
    questions = {}
    for key, spec in schema["properties"].items():
        question = {"type": "noul" if spec["type"] == "boolean" else "choice",
                    "instructions": spec["description"]}
        if spec["type"] != "boolean":
            question["criteria"] = dict.fromkeys(spec["enum"])
        questions[key] = question
    return questions


def schema_output(response):
    return {key: (value["noul"] >= 0.5 if value["type"] == "noul" else value["choice"])
            for key, value in response["answers"].items()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("text", nargs="?", default="I was billed twice. Please refund the duplicate. No hurry.")
    parser.add_argument("--schema", type=Path)
    args = parser.parse_args()
    schema = json.loads(args.schema.read_text()) if args.schema else {
        "properties": {"department": {"type":"string", "enum":["billing","technical","sales"],"description":"Which department should handle this request?"},
                       "refund": {"type":"boolean", "description":"Does the customer request a refund?"},
                       "urgent": {"type":"boolean", "description":"Is immediate action explicitly requested?"}}}
    agent = load_agent()
    questions = schema_questions(schema)
    audit = audit_prompt(agent, args.text, questions)
    started = time.perf_counter()
    result = agent.predict(args.text, questions)
    elapsed = (time.perf_counter()-started)*1000
    print(json.dumps({"model": MODEL_ID, "revision": REVISION, "latency_ms": elapsed,
                      "output": schema_output(result), "response": result, "context_audit": audit}, indent=2))
