#!/bin/bash
# Build the four isolated local-engine environments from hash-pinned locks.
# Locks record environments that passed real model checks; see scripts/lock_engines.sh.
set -euo pipefail
JET_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JET_ROOT"
LOCKS=vendor/local-engines/locks
mkdir -p .runtime/envs
for JET_ENV in lfm laya semif text; do
  if [ ! -x ".runtime/envs/$JET_ENV/bin/python" ]; then
    uv venv --python 3.12 ".runtime/envs/$JET_ENV"
  fi
  # sync (not install) removes anything the lock does not list.
  uv pip sync --python ".runtime/envs/$JET_ENV/bin/python" --require-hashes "$LOCKS/$JET_ENV.txt"
done
# Git packages cannot carry wheel hashes; they are pinned to exact commits instead. Their dependencies are already
# locked above, so they are installed without resolving anything new.
uv pip install --python .runtime/envs/laya/bin/python --no-deps \
  'laya-mlx @ git+https://github.com/mizorewww/laya-mlx@0a859518634112655cb97c745dbf04f5191aaf13'
uv pip install --python .runtime/envs/semif/bin/python --no-deps \
  'mlx-lm @ git+https://github.com/ml-explore/mlx-lm.git@a63e24c389382619eb6d9af656e3b46024be217a'
