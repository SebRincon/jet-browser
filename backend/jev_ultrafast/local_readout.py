"""Experimental native categorical readout; no text generation or schema completion."""

import time


def lfm_choice_logits(runtime, request):
    if runtime.mode != "lfm_rlcd":
        raise ValueError("LFM readout requires the LFM checkpoint")
    import torch

    engine = runtime.engine
    start = time.perf_counter()
    prepared = []
    calibrated = request.get("readout") == "lfm_choice_calibrated"
    for key, question in request["questions"].items():
        choices = question["criteria"]
        if question["type"] != "choice" or not 2 <= len(choices) <= 26:
            raise ValueError("Native letter readout needs 2–26 choice options")
        letters = [chr(65 + i) for i in range(len(choices))]
        options = "\n".join(
            f"{letter}. {description or label}" for letter, (label, description) in zip(letters, choices.items())
        )
        messages = [
            {
                "role": "system",
                "content": (
                    "Select the best answer to the question using the supplied evidence. Reply with only its letter."
                ),
            },
            {
                "role": "user",
                "content": f"{request['state']}\n\nQUESTION: {question['instructions']}\nOPTIONS:\n{options}",
            },
        ]
        prompt = engine.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        ids = engine.encode(prompt)
        slots = [engine.encode(letter) for letter in letters]
        if any(len(slot) != 1 or engine.encode(prompt + letter) != ids + slot for letter, slot in zip(letters, slots)):
            raise ValueError("Letter readout token boundary is not exact")
        if len(ids) + 1 > engine.model.config.max_position_embeddings:
            raise ValueError("Native letter prompt exceeds context limit")
        null_ids = None
        if calibrated:
            messages[1]["content"] = (
                f"No evidence provided.\n\nQUESTION: {question['instructions']}\nOPTIONS:\n{options}"
            )
            null_ids = engine.encode(
                engine.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
            )
        prepared.append((key, list(choices), ids, [slot[0] for slot in slots], null_ids))
    prepare_ms = (time.perf_counter() - start) * 1000
    start = time.perf_counter()
    answers, raw, audit = {}, {}, {}
    with torch.inference_mode():
        for key, labels, ids, slots, null_ids in prepared:
            logits = engine.model(engine.tensor([ids]), use_cache=False, logits_to_keep=1).logits[0, -1].float()
            selected = logits[engine.tensor(slots)]
            original_scores = selected.cpu().tolist()
            null_scores = None
            if null_ids is not None:
                prior = (
                    engine.model(engine.tensor([null_ids]), use_cache=False, logits_to_keep=1)
                    .logits[0, -1]
                    .float()[engine.tensor(slots)]
                )
                null_scores = prior.cpu().tolist()
                selected = selected - prior
            scores = selected.cpu().tolist()
            probabilities = selected.softmax(-1).cpu().tolist()
            answer = labels[max(range(len(labels)), key=scores.__getitem__)]
            answers[key] = {
                "valid": True,
                "label": answer,
                "probabilities": dict(zip(labels, probabilities)),
                "confidence": None,
            }
            raw[key] = {
                "option_logits": dict(zip(labels, scores)),
                "original_logits": original_scores,
                "null_logits": null_scores,
                "readout": "native next-token letter logits" + (" minus null-evidence logits" if calibrated else ""),
                "confidence": "uncalibrated",
            }
            audit[key] = {
                "input_tokens": len(ids),
                "max_len": engine.model.config.max_position_embeddings,
                "truncated": False,
            }
    engine.sync()
    return {
        "model": runtime.model,
        "answers": answers,
        "raw": raw,
        "context_audit": audit,
        "prepare_ms": prepare_ms,
        "latency_ms": (time.perf_counter() - start) * 1000,
        "forward_calls": len(prepared) * (2 if calibrated else 1),
    }
