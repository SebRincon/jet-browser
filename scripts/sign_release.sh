#!/usr/bin/env bash
# Sign a packaged Jet Browser.app for distribution, inside out, with the hardened
# runtime and per-component entitlements (packaging/entitlements/), then optionally
# notarize and staple it.
#
#   JET_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/sign_release.sh [APP]
#   JET_SIGN_IDENTITY=- scripts/sign_release.sh [APP]      ad-hoc, for local structure checks
#   JET_NOTARY_PROFILE=<notarytool keychain profile>        also submit, wait and staple
#   scripts/sign_release.sh --list [APP]                    print what would be signed
#
# Notarization uploads the app to Apple. Run it only for a build you intend to publish.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="${ROOT}/packaging/entitlements"
LIST=0
if [[ "${1:-}" == "--list" ]]; then LIST=1; shift; fi
APP="$(cd "$(dirname "${1:-${ROOT}/dist/Jet Browser.app}")" && pwd)/$(basename "${1:-${ROOT}/dist/Jet Browser.app}")"
RUNTIME="${APP}/Contents/Resources/jet-runtime"

fail() { printf '[jet-sign] error: %s\n' "$*" >&2; exit 1; }
[[ -f "${RUNTIME}/bundle-manifest.json" ]] || fail "${APP} was not built by scripts/package_runtime.py"
if [[ "$LIST" == 0 ]]; then
  IDENTITY="${JET_SIGN_IDENTITY:-}"
  [[ -n "$IDENTITY" ]] || fail "set JET_SIGN_IDENTITY (a Developer ID Application identity, or - for ad hoc)"
  if [[ "$IDENTITY" == "-" ]]; then
    TIMESTAMP=(--timestamp=none)
    [[ -z "${JET_NOTARY_PROFILE:-}" ]] || fail "an ad-hoc signature cannot be notarized"
  else
    TIMESTAMP=(--timestamp)
  fi
fi

sign() {  # sign <path> [entitlements-file]
  if [[ "$LIST" == 1 ]]; then printf '%s\t%s\n' "${2:+$(basename "$2")}" "${1#"$APP"/}"; return; fi
  local args=(--force --options runtime "${TIMESTAMP[@]}" --sign "$IDENTITY")
  [[ -n "${2:-}" ]] && args+=(--entitlements "$2")
  /usr/bin/codesign "${args[@]}" "$1"
}

is_macho() { /usr/bin/file -b "$1" | grep -q '^Mach-O'; }

# 1. Loose Mach-O files in the bundled runtime (python extensions, dylibs, tools),
#    deepest paths first. Entitlements attach only to executables that need them.
# Bundle paths contain spaces but never newlines.
while IFS= read -r file; do
  is_macho "$file" || continue
  case "$file" in
    "${RUNTIME}/python/bin/python3.12") sign "$file" "${ENTITLEMENTS}/python.plist" ;;
    "${RUNTIME}/bin/JetWorkflow") sign "$file" "${ENTITLEMENTS}/jit.plist" ;;
    "${RUNTIME}/bin/grok") sign "$file" "${ENTITLEMENTS}/grok.plist" ;;
    *) sign "$file" ;;
  esac
done < <(find "$RUNTIME" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) |
         awk '{print length($0) "\t" $0}' | sort -rn | cut -f2-)

# 2. Chromium Embedded Framework: its libraries, then the versioned bundle.
CEF="${APP}/Contents/Frameworks/Chromium Embedded Framework.framework"
for lib in "${CEF}/Versions/A/Libraries/"*.dylib; do sign "$lib"; done
sign "$CEF"

# 3. CEF helper apps: executable, then bundle. They JIT JavaScript and load CEF.
for helper in "${APP}/Contents/Frameworks/"*Helper*.app; do
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${helper}/Contents/Info.plist")"
  sign "${helper}/Contents/MacOS/${executable}" "${ENTITLEMENTS}/jit.plist"
  sign "$helper" "${ENTITLEMENTS}/jit.plist"
done

# 4. Remaining frameworks (Flutter, App, plugins).
for framework in "${APP}/Contents/Frameworks/"*.framework; do
  [[ "$framework" == "$CEF" ]] && continue
  sign "$framework"
done

# 5. The launcher execs into the Flutter/CEF host; both carry the app entitlements.
for executable in "${APP}/Contents/MacOS/"*; do
  sign "$executable" "${ROOT}/app/macos/Runner/Release.entitlements"
done
sign "$APP" "${ROOT}/app/macos/Runner/Release.entitlements"
[[ "$LIST" == 1 ]] && exit 0

/usr/bin/codesign --verify --deep --strict --verbose=1 "$APP"
printf '[jet-sign] signed %s\n' "$APP"

if [[ -n "${JET_NOTARY_PROFILE:-}" ]]; then
  archive="$(mktemp -d "${TMPDIR:-/tmp}/jet-notary.XXXXXX")/Jet Browser.zip"
  /usr/bin/ditto -c -k --keepParent "$APP" "$archive"
  xcrun notarytool submit "$archive" --keychain-profile "$JET_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
  rm -rf -- "$(dirname "$archive")"
fi
