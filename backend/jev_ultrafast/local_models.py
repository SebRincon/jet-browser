"""Serial local native inference using the existing isolated model environments."""

import atexit
import json
import os
import selectors
import subprocess
import threading
import time
from copy import deepcopy
from pathlib import Path

from jet_browser.paths import DATA_ROOT as ROOT
from jet_browser.paths import RESOURCE_ROOT

WORKSPACE = RESOURCE_ROOT / "vendor/local-engines"
MODELS = {
    "jev_hosted": {"title": "Jev 1.13.0 · hosted", "python": None},
    "lfm_rlcd": {"title": "LFM RLCD · 350M · local", "python": ROOT / ".runtime/envs/lfm/bin/python"},
    "qwen4b_semif_shared": {
        "title": "SemIf / Qwen3.5 · 4B · local",
        "python": ROOT / ".runtime/envs/semif/bin/python",
    },
    "laya_mlx": {"title": "Laya MLX · 421M · local", "python": ROOT / ".runtime/envs/laya/bin/python"},
    "laya_typed": {
        "title": "Laya Typed · 421M · 1,024 context · local",
        "python": ROOT / ".runtime/envs/laya/bin/python",
    },
}


class NativeWorker:
    def __init__(self):
        self.lock = threading.RLock()
        self.trace = None
        self.process = None
        self.mode = None
        self.metadata = {}
        self.records = []

    def _emit(self, event, **attributes):
        if self.trace:
            try:
                self.trace(event, **attributes)
            except Exception:
                pass

    def close(self):
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
            self.process.stdin.close()
            self.process.stdout.close()
        self.process, self.mode, self.metadata = None, None, {}

    def receive(self, timeout=90):
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(timeout):
                self.close()
                raise TimeoutError("Local inference timed out; no browser action executed")
        line = self.process.stdout.readline()
        if not line:
            self.close()
            raise RuntimeError("Local model process stopped. See artifacts/native-models.log")
        result = json.loads(line)
        if result.get("error"):
            raise ValueError("Local model: " + result["error"])
        return result

    def start(self, mode):
        warm = self.mode == mode and self.process and self.process.poll() is None
        started = time.perf_counter()
        self._emit('model.load.start', model=mode, warm=bool(warm))
        try:
            result = self._start(mode)
            self._emit('model.load.end', model=mode, warm=bool(warm), status='ok',
                       duration_ms=round((time.perf_counter() - started) * 1000, 2))
            return result
        except Exception as error:
            self._emit('model.load.error', model=mode, level='error', error_type=type(error).__name__)
            raise

    def _start(self, mode):
        if mode not in MODELS:
            raise ValueError("Unknown decision model")
        if self.mode == mode and self.process and self.process.poll() is None:
            return self.metadata
        self.close()
        if mode == "jev_hosted":
            return {}
        portable = RESOURCE_ROOT / "python/bin/python3.12"
        python = portable if portable.is_file() else MODELS[mode]["python"]
        if not python.is_file():
            raise ValueError("Local model environment is missing: " + MODELS[mode]["title"])
        directory = {"lfm_rlcd": "lfm350m", "qwen4b_semif_shared": "qwen4b", "laya_mlx": "laya-english", "laya_typed": "laya-typed"}[mode]
        if portable.is_file() and not (ROOT / "models" / directory / "config.json").is_file():
            raise ValueError("Download " + MODELS[mode]["title"] + " in Models and setup first")
        env = {k: v for k, v in os.environ.items() if not k.startswith(("TYPESAFE_", "TEXT_MODEL_"))}
        if portable.is_file():
            engine = {"lfm_rlcd": "lfm", "qwen4b_semif_shared": "semif", "laya_mlx": "laya", "laya_typed": "laya"}[mode]
            env["PYTHONPATH"] = os.pathsep.join([str(RESOURCE_ROOT / "packages" / engine), str(RESOURCE_ROOT / "backend"), str(WORKSPACE)])
            env["PYTHONNOUSERSITE"] = "1"
            env["HF_HUB_OFFLINE"] = "1"
            env["TRANSFORMERS_OFFLINE"] = "1"
        (ROOT / ".runtime").mkdir(exist_ok=True)
        with (ROOT / ".runtime/native-models.log").open("ab") as log:
            self.process = subprocess.Popen(
                [str(python), str(Path(__file__).with_name("native_worker.py")), mode],
                cwd=WORKSPACE,
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=log,
                text=True,
                bufsize=1,
            )
        self.mode = mode
        try:
            self.metadata = self.receive(timeout=120)
        except Exception:
            self.close()
            raise
        return self.metadata

    def predict(self, mode, request):
        self.start(mode)
        started = time.perf_counter()
        result = {}
        self._emit('model.inference.start', model=mode, input_chars=len(str(request.get('state', ''))),
                   candidate_count=sum(len(q.get('criteria', {})) for q in request.get('questions', {}).values()))
        try:
            self.process.stdin.write(
                json.dumps({k: request[k] for k in ("state", "questions", "readout") if k in request}) + "\n"
            )
            self.process.stdin.flush()
            result = self.receive()
            return deepcopy(result)
        except (ValueError, RuntimeError, TimeoutError, OSError) as error:
            result = {"error": str(error)}
            raise
        finally:
            self._emit('model.inference.end', model=mode, status='error' if result.get('error') else 'ok',
                       duration_ms=round((time.perf_counter() - started) * 1000, 2))
            self.records.append(
                {
                    "request": request,
                    "result": result,
                    "backend": mode,
                    "latency_ms": (time.perf_counter() - started) * 1000,
                }
            )
            del self.records[:-256]


    def summarize(self, mode, text):
        if mode != "qwen4b_semif_shared" or not isinstance(text, str) or len(text) > 7200:
            raise ValueError("Local summaries require SemIf 4B and bounded text")
        self.start(mode)
        started = time.perf_counter()
        self.process.stdin.write(json.dumps({"operation": "summarize", "text": text}) + "\n")
        self.process.stdin.flush()
        result = self.receive()
        self._emit('model.summary.end', model=mode, duration_ms=round((time.perf_counter()-started)*1000, 2))
        return result


WORKER = NativeWorker()
atexit.register(WORKER.close)
