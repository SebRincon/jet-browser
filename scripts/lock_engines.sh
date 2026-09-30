#!/usr/bin/env bash
# Regenerate hash-pinned locks for the four local model engines.
#
# Locks come from environments that already passed real model checks, not from a
# fresh resolve, so they record what was verified. Git and local packages cannot be
# hash-locked; setup_models.sh installs them separately at a fixed commit/path with
# --no-deps. After changing an engine, rebuild its env, rerun the model checks in
# docs/development.md, then run this script.
#
#   scripts/lock_engines.sh [ENV_ROOT]   (default: .runtime/envs)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_ROOT="${1:-${ROOT}/.runtime/envs}"
OUT="${ROOT}/vendor/local-engines/locks"
mkdir -p "$OUT"
work="$(mktemp -d "${TMPDIR:-/tmp}/jet-engine-lock.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

for engine in lfm laya semif text; do
  python="${ENV_ROOT}/${engine}/bin/python"
  [[ -x "$python" ]] || { echo "missing ${python}; run scripts/setup_models.sh" >&2; exit 1; }
  # Only exact index pins are lockable; laya-mlx and mlx-lm come from pinned git commits.
  uv pip freeze --color never --python "$python" 2>/dev/null | grep -E '^[A-Za-z0-9_.-]+==' > "${work}/${engine}.in"
  # torch 2.14 publishes macOS arm64 wheels for 14.0+ only; Jet's engines target that floor.
  MACOSX_DEPLOYMENT_TARGET=14.0 uv pip compile "${work}/${engine}.in" --color never --quiet --generate-hashes --no-deps \
    --python-version 3.12 --python-platform aarch64-apple-darwin \
    --custom-compile-command "scripts/lock_engines.sh" \
    --output-file "${OUT}/${engine}.txt"
  printf '%s: %s packages\n' "$engine" "$(grep -cE '^[A-Za-z0-9_.-]+==' "${OUT}/${engine}.txt")"
done
