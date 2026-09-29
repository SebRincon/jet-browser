#!/bin/bash
set -euo pipefail
JET_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JET_ROOT"
if [[ "${1:-}" == "--dev" ]]; then
  shift
  exec backend/.venv/bin/python scripts/launch.py "$@"
fi
if [[ -d "dist/Jet Browser.app" && $# -eq 0 ]]; then
  exec open "dist/Jet Browser.app"
fi
exec backend/.venv/bin/python scripts/launch.py "$@"
