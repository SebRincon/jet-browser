#!/bin/bash
set -euo pipefail
JET_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$JET_ROOT"
mkdir -p .runtime/envs
for JET_ENV in lfm laya semif text; do
  if [ ! -x ".runtime/envs/$JET_ENV/bin/python" ]; then
    uv venv --python 3.12 ".runtime/envs/$JET_ENV"
  fi
done
uv pip install --python .runtime/envs/lfm/bin/python -r vendor/local-engines/lfm-requirements.txt
uv pip install --python .runtime/envs/laya/bin/python ./vendor/local-engines/laya-mlx 'mlx==0.32.2' 'numpy==2.5.3' 'tokenizers==0.23.2'
uv pip install --python .runtime/envs/semif/bin/python -r vendor/local-engines/semif-requirements.txt
uv pip install --python .runtime/envs/text/bin/python -r vendor/local-engines/text-requirements.txt
