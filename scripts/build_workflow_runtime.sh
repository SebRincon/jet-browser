#!/bin/zsh
set -eu
root_dir="${0:A:h:h}"
output_path="${1:-$root_dir/.runtime/bin/jet-workflow}"
mkdir -p "${output_path:h}"
xcrun swiftc -O -framework JavaScriptCore "$root_dir/native/JetWorkflow/main.swift" -o "$output_path"
if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$output_path"
fi
