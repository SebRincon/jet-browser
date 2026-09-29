#!/usr/bin/env bash
# Install or check the pinned CEF assets in vendor/flutter_cef_browser/macos/Frameworks.
#
# Jet uses the same CEF artifact as vten (packaging/pins.json). Sources, in order:
#   JET_CEF_ARCHIVE=/path/to/vten-cef-...tar.gz   a local copy of the release archive
#   JET_CEF_FROM=/path/to/vten/deps/webview_cef   a vten checkout with the artifact installed
#   otherwise: the private vten GitHub release through an authenticated `gh`
# Every source is verified against the pinned hashes before anything is replaced.
#
#   scripts/install_cef.sh           install, then verify
#   scripts/install_cef.sh --check   verify the installed assets only; exit 1 on mismatch
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS="${ROOT}/packaging/pins.json"
TARGET="${ROOT}/vendor/flutter_cef_browser/macos/Frameworks"
LICENSES="${ROOT}/vendor/flutter_cef_browser/licenses"
FRAMEWORK="Chromium Embedded Framework.framework"

fail() { printf '[jet-cef] error: %s\n' "$*" >&2; exit 1; }
pin() { /usr/bin/plutil -extract "cef.$1" raw -o - "$PINS"; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
tree_sha256() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s  %s\n' "$(shasum -a 256 "$file" | awk '{print $1}')" "$file"
  done | shasum -a 256 | awk '{print $1}')
}

# Prints one line per mismatch; returns 1 if any asset differs from the pins.
verify_dir() {
  local dir="$1" problems=0
  [[ "$(sha256 "${dir}/${FRAMEWORK}/Chromium Embedded Framework" 2>/dev/null)" == "$(pin framework_binary_sha256)" ]] ||
    { printf '[jet-cef] framework binary differs from the pin\n'; problems=1; }
  [[ "$(sha256 "${dir}/libcef_dll_wrapper.a" 2>/dev/null)" == "$(pin wrapper_sha256)" ]] ||
    { printf '[jet-cef] libcef_dll_wrapper.a differs from the pin\n'; problems=1; }
  [[ -d "${dir}/include" && "$(tree_sha256 "${dir}/include")" == "$(pin include_tree_sha256)" ]] ||
    { printf '[jet-cef] include/ differs from the pin\n'; problems=1; }
  return "$problems"
}

# The release archive holds a flat bundle; Xcode embeds only versioned macOS
# frameworks. Same conversion as vten's scripts/sync_cef_macos.sh, and the seal moves
# too: its paths are relative to the version directory, so it stays valid.
normalize_framework() {
  local bundle="$1" name="Chromium Embedded Framework" item
  [[ -d "${bundle}/Versions" ]] && return
  mkdir -p "${bundle}/Versions/A"
  for item in "$name" Resources Libraries _CodeSignature; do
    [[ -e "${bundle}/${item}" ]] && mv "${bundle}/${item}" "${bundle}/Versions/A/${item}"
  done
  ln -s A "${bundle}/Versions/Current"
  for item in "$name" Resources Libraries; do
    [[ -e "${bundle}/Versions/A/${item}" ]] && ln -s "Versions/Current/${item}" "${bundle}/${item}"
  done
  [[ -f "${bundle}/Versions/A/Resources/Info.plist" ]] || fail "framework has no Resources/Info.plist"
}

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || fail "the pinned artifact is macOS arm64-only"
[[ -f "$PINS" ]] || fail "missing ${PINS}"

if [[ "${1:-}" == "--check" ]]; then
  status=0
  verify_dir "$TARGET" || status=1
  [[ "$(sha256 "${TARGET}/LICENSE.txt" 2>/dev/null)" == "$(pin license_sha256)" ]] ||
    { printf '[jet-cef] LICENSE.txt missing or different\n'; status=1; }
  [[ "$(sha256 "${TARGET}/CREDITS.html" 2>/dev/null)" == "$(pin credits_sha256)" ]] ||
    { printf '[jet-cef] CREDITS.html missing or different\n'; status=1; }
  if [[ "$status" == 0 ]]; then
    printf '[jet-cef] installed assets match %s\n' "$(pin release_tag)"
  else
    printf '[jet-cef] run scripts/install_cef.sh to install %s\n' "$(pin release_tag)"
  fi
  exit "$status"
fi
[[ -z "${1:-}" ]] || fail "unknown argument: $1"

work="$(mktemp -d "${TMPDIR:-/tmp}/jet-cef.XXXXXX")"
staged="${TARGET}.install.$$"
backup="${TARGET}.backup.$$"
# The replaced install is kept (one generation) because an older local CEF build
# may not be reproducible from any published source.
previous="${TARGET}.previous"
committed=0
cleanup() {
  if [[ "$committed" != 1 && -d "$backup" ]]; then
    rm -rf -- "$TARGET"
    mv "$backup" "$TARGET"
  fi
  rm -rf -- "$work" "$staged"
  if [[ "$committed" == 1 && -d "$backup" ]]; then
    rm -rf -- "$previous"
    mv "$backup" "$previous"
    printf '[jet-cef] previous install kept at %s\n' "$previous"
  fi
}
trap cleanup EXIT

source_dir="${work}/extract"
mkdir -p "$source_dir"
if [[ -n "${JET_CEF_ARCHIVE:-}" || -z "${JET_CEF_FROM:-}" ]]; then
  archive="${JET_CEF_ARCHIVE:-${work}/$(pin archive)}"
  if [[ -z "${JET_CEF_ARCHIVE:-}" ]]; then
    command -v gh >/dev/null 2>&1 ||
      fail "install and authenticate gh for $(pin release_repo), or set JET_CEF_ARCHIVE or JET_CEF_FROM"
    printf '[jet-cef] downloading %s %s\n' "$(pin release_repo)" "$(pin release_tag)"
    gh release download "$(pin release_tag)" --repo "$(pin release_repo)" \
      --pattern "$(pin archive)" --output "$archive" ||
      fail "download failed; the release is private: check gh access to $(pin release_repo)"
  fi
  [[ -f "$archive" ]] || fail "archive not found: ${archive}"
  [[ "$(sha256 "$archive")" == "$(pin archive_sha256)" ]] || fail "archive SHA-256 differs from the pin"
  tar -xzf "$archive" -C "$source_dir"
else
  from="${JET_CEF_FROM%/}/macos/third/cef"
  [[ -d "$from" ]] || fail "no installed CEF at ${from}"
  # ditto keeps the framework's internal relative symlinks; -L resolves vten's
  # top-level include/wrapper symlinks into real files.
  /usr/bin/ditto "${from}/${FRAMEWORK}" "${source_dir}/${FRAMEWORK}"
  cp -L "${from}/libcef_dll_wrapper.a" "${source_dir}/libcef_dll_wrapper.a"
  cp -RL "${from}/include" "${source_dir}/include"
fi
verify_dir "$source_dir" ||
  fail "source does not match $(pin release_tag); a vten checkout may need its own cef_build/install_prebuilt_cef_147_macos_arm64.sh"

normalize_framework "${source_dir}/${FRAMEWORK}"
/usr/bin/codesign --verify "${source_dir}/${FRAMEWORK}" 2>/dev/null ||
  printf '[jet-cef] note: framework seal is not valid after layout conversion; Xcode re-signs it when embedding\n'
mkdir -p "$staged"
mv "${source_dir}/${FRAMEWORK}" "${source_dir}/libcef_dll_wrapper.a" "${source_dir}/include" "$staged/"
cp "${LICENSES}/CEF-LICENSE.txt" "${staged}/LICENSE.txt"
xz -dc "${LICENSES}/CEF-CREDITS.html.xz" > "${staged}/CREDITS.html"
cp "$PINS" "${staged}/jet-cef-pins.json"
verify_dir "$staged" || fail "staged install failed verification"

if [[ -e "$TARGET" ]]; then
  mv "$TARGET" "$backup"
fi
mv "$staged" "$TARGET"
committed=1
"${BASH_SOURCE[0]}" --check
