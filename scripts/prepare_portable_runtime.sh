#!/bin/bash
set -euo pipefail
JET_BUILD_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JET_BUILD_ROOT"
uv python install 3.12.13 --install-dir .runtime/portable-python
uv export --project backend --no-dev --no-emit-project --format requirements-txt --output-file .runtime/portable-service-requirements.txt > /dev/null
uv pip install --python .runtime/portable-python/cpython-3.12.13-macos-aarch64-none/bin/python3.12 --target .runtime/portable-packages/service --require-hashes -r .runtime/portable-service-requirements.txt
