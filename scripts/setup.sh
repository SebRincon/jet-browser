#!/bin/bash
set -euo pipefail
JET_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JET_ROOT"
uv sync --project backend
bash scripts/setup_models.sh
cd app
flutter pub get
flutter build macos --release --dart-define="JET_ROOT=$JET_ROOT"
