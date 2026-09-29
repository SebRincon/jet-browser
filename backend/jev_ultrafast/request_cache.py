"""Per-run exact native-request reuse, with original evidence and fresh label mapping."""

import hashlib
import json
import time
from copy import deepcopy


class RequestCache:
    def __init__(self, worker, entries):
        self.worker = worker
        self.entries = entries
        self.records = worker.records

    def predict(self, mode, request):
        metadata = self.worker.start(mode)
        native = {k: request[k] for k in ("state", "questions", "readout") if k in request}
        digest = hashlib.sha256(
            json.dumps([mode, metadata.get("model"), native], sort_keys=True, ensure_ascii=False).encode()
        ).hexdigest()
        started = time.perf_counter()
        if digest in self.entries:
            saved, source = self.entries[digest]
            result = deepcopy(saved)
            # Original distributions remain evidence from that inference, not a new forward pass.
            result.update(
                forward_calls=0,
                latency_ms=0,
                prepare_ms=0,
                cache_hit=True,
                cache_source_record=source,
                cache_request_sha256=digest,
            )
            self.records.append(
                {
                    "request": deepcopy(request),
                    "result": deepcopy(result),
                    "backend": mode,
                    "latency_ms": (time.perf_counter() - started) * 1000,
                }
            )
            return result
        source = len(self.records)
        result = self.worker.predict(mode, request)
        answers = result.get("answers", {})
        valid = not result.get("error") and all(
            answers.get(key, {}).get("valid") and answers[key].get("label") in question["criteria"]
            for key, question in native["questions"].items()
        )
        if valid and result.get("forward_calls", 1) != 0:
            self.entries[digest] = (deepcopy(result), source)
        return result
