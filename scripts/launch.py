"""Start Jet's own sidecars before its native CEF process. Never prints tokens."""

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / ".runtime"


def health(url):
    try:
        with urllib.request.urlopen(url, timeout=1) as response:
            return json.load(response)
    except (OSError, ValueError):
        return None


def free(port):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def pid(name, marker):
    path = RUNTIME / (name + ".pid")
    if not path.exists():
        return None
    value = int(path.read_text())
    command = subprocess.run(["ps", "-p", str(value), "-o", "command="], capture_output=True, text=True, check=False).stdout
    if not command:
        return None
    if marker not in command:
        raise RuntimeError("Saved process identity changed; refusing to stop or reuse it")
    return value


def start(name, argv, cwd, env):
    with (RUNTIME / (name + ".log")).open("ab") as output:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=output, stderr=output, start_new_session=True)
    (RUNTIME / (name + ".pid")).write_text(str(process.pid))
    return process


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-app", action="store_true")
    parser.add_argument("--restart-service", action="store_true")
    args = parser.parse_args()
    RUNTIME.mkdir(exist_ok=True, mode=0o700)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("VTEN_", "VIBECODER_", "BU_", "TYPESAFE_"))}
    env["JET_ROOT"] = str(ROOT)
    service_health = health("http://127.0.0.1:9148/health")
    if service_health and service_health.get("application") != "jet-browser":
        raise RuntimeError("Port 9148 belongs to another application")
    if args.restart_service and service_health:
        request = urllib.request.Request('http://127.0.0.1:9148/state', headers={
            'Authorization': 'Bearer ' + (RUNTIME / 'token').read_text().strip()})
        with urllib.request.urlopen(request, timeout=2) as response:
            current = json.load(response)
        if current.get('busy', current.get('provider', {}).get('status') not in {'ready', 'error'}):
            raise RuntimeError('A chat or browser task is active; the service was not restarted')
        service_pid = pid("service", "jet_browser.service")
        if service_pid is None:
            raise RuntimeError("This service was not started by Jet's launcher")
        os.kill(service_pid, signal.SIGTERM)
        for _ in range(100):
            if free(9148):
                break
            time.sleep(0.1)
        service_health = None
    helper_python = ROOT / ".runtime/envs/text/bin/python"
    helper_path = ROOT / "models/qwen08b"
    if not pid("text", str(helper_path)):
        if not free(9149):
            raise RuntimeError("Port 9149 belongs to another text helper; nothing was changed")
        start("text", [str(helper_python), "-m", "mlx_lm", "server", "--model", str(helper_path),
                       "--host", "127.0.0.1", "--port", "9149", "--chat-template-args",
                       '{"enable_thinking":false}', "--temp", "0", "--max-tokens", "1024",
                       "--log-level", "WARNING"], ROOT, env)
    for _ in range(180):
        if health("http://127.0.0.1:9149/health"):
            break
        time.sleep(0.2)
    else:
        raise RuntimeError("Local typing helper did not start; see .runtime/text.log")
    env.update(TEXT_MODEL_API_KEY="local-only", TEXT_MODEL="default_model",
               TEXT_MODEL_LABEL="Qwen3.5 0.8B · local", TEXT_MODEL_BASE_URL="http://127.0.0.1:9149/v1",
               TEXT_MODEL_REASONING="none")
    if not service_health:
        if not free(9148):
            raise RuntimeError("Port 9148 is occupied; no service was replaced")
        start("service", [str(ROOT / "backend/.venv/bin/python"), "-m", "jet_browser.service"], ROOT / "backend", env)
        for _ in range(100):
            if health("http://127.0.0.1:9148/health"):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Jet Browser service did not start; see .runtime/service.log")
    if not args.no_app:
        bundle = ROOT / "app/build/macos/Build/Products/Release/Jet Browser.app"
        if not bundle.is_dir():
            raise RuntimeError("Build the app with scripts/setup.sh first")
        subprocess.run(["open", str(bundle)], check=True, env=env)
    print("Jet Browser is ready. Service: 127.0.0.1:9148. Typing helper: 127.0.0.1:9149.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
