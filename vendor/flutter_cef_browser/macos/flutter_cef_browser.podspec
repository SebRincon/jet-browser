Pod::Spec.new do |s|
  s.name             = 'flutter_cef_browser'
  s.version          = '0.1.0'
  s.summary          = 'Flutter CEF Browser plugin with native window rendering'
  s.description      = <<-DESC
A Flutter plugin for macOS that provides a native CEF-based browser
with direct GPU rendering using sibling-view architecture.
                       DESC
  s.homepage         = 'https://github.com/example/flutter_cef_browser'
  s.license          = { :type => 'BSD', :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m,mm}'
  s.public_header_files = 'Classes/FlutterCefBrowserPlugin.h'
  s.dependency 'FlutterMacOS'
  # NOTE: Removed webview_cef dependency - this plugin is standalone

  s.platform = :osx, '12.0'
  s.osx.deployment_target = '12.0'

  s.frameworks = 'Cocoa', 'CoreVideo', 'IOSurface', 'Metal', 'QuartzCore', 'UniformTypeIdentifiers'

  # Vendor CEF framework directly from plugin's Frameworks folder
  s.vendored_frameworks = 'Frameworks/Chromium Embedded Framework.framework'
  s.vendored_libraries = 'Frameworks/libcef_dll_wrapper.a'

  s.xcconfig = {
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks',
  }

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Frameworks/include" "${PODS_TARGET_SRCROOT}/Frameworks"',
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Frameworks"',
    'LIBRARY_SEARCH_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Frameworks"',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) USING_CEF_SHARED=1',
    'ARCHS' => 'arm64',
    'VALID_ARCHS' => 'arm64',
    'EXCLUDED_ARCHS[sdk=macosx*]' => 'x86_64',
    # Link CEF directly - no webview_cef dependency
    'OTHER_LDFLAGS' => '-lcef_dll_wrapper -framework FlutterMacOS -framework Cocoa',
  }

  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=macosx*]' => 'x86_64'
  }

  # Build helper bundles for CEF multi-process mode on macOS.
  #
  # CEF expects a helper app bundle at:
  #   <App>.app/Contents/Frameworks/webview_cef Helper.app/...
  # plus the GPU/Renderer/Plugin variants alongside it.
  #
  # The Runner target must copy the built helper bundles into the app bundle.
  s.script_phase = {
    :name => 'Build CEF Helpers (flutter_cef_browser)',
    :input_files => [
      '${PODS_TARGET_SRCROOT}/Helper/main.mm',
      '${PODS_TARGET_SRCROOT}/Helper/Info.plist',
      '${PODS_TARGET_SRCROOT}/Frameworks/libcef_dll_wrapper.a',
      '${PODS_TARGET_SRCROOT}/Frameworks/include/cef_api_hash.h',
      '${PODS_TARGET_SRCROOT}/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework',
    ],
    :output_files => [
      '${BUILT_PRODUCTS_DIR}/webview_cef_helpers/webview_cef Helper',
      '${BUILT_PRODUCTS_DIR}/webview_cef_helpers/webview_cef Helper.app/Contents/MacOS/webview_cef Helper',
      '${BUILT_PRODUCTS_DIR}/webview_cef_helpers/webview_cef Helper (GPU).app/Contents/MacOS/webview_cef Helper (GPU)',
      '${BUILT_PRODUCTS_DIR}/webview_cef_helpers/webview_cef Helper (Renderer).app/Contents/MacOS/webview_cef Helper (Renderer)',
      '${BUILT_PRODUCTS_DIR}/webview_cef_helpers/webview_cef Helper (Plugin).app/Contents/MacOS/webview_cef Helper (Plugin)',
    ],
    :script => %q(
set -e

HELPER_SRC="${PODS_TARGET_SRCROOT}/Helper"
CEF_DIR="${PODS_TARGET_SRCROOT}/Frameworks"
HELPER_BUILD_DIR="${BUILT_PRODUCTS_DIR}/webview_cef_helpers"

if [ ! -f "${HELPER_SRC}/main.mm" ]; then
  echo "warning: Helper source not found at ${HELPER_SRC}/main.mm - skipping helper build"
  exit 0
fi

echo "Building CEF helpers..."
mkdir -p "${HELPER_BUILD_DIR}"

clang++ -std=c++20 -stdlib=libc++ -arch arm64 \
  -mmacosx-version-min=12.0 \
  -framework Cocoa \
  -framework "Chromium Embedded Framework" \
  -F"${CEF_DIR}" \
  -I"${CEF_DIR}" \
  -L"${CEF_DIR}" \
  -lcef_dll_wrapper \
  -o "${HELPER_BUILD_DIR}/webview_cef Helper" \
  "${HELPER_SRC}/main.mm"

# Fix CEF framework path in helper binary.
install_name_tool -change \
  "@executable_path/../Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework" \
  "@executable_path/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework" \
  "${HELPER_BUILD_DIR}/webview_cef Helper"

# Create base helper bundle.
HELPER_APP="${HELPER_BUILD_DIR}/webview_cef Helper.app"
mkdir -p "${HELPER_APP}/Contents/MacOS"
cp "${HELPER_BUILD_DIR}/webview_cef Helper" "${HELPER_APP}/Contents/MacOS/"
cp "${HELPER_SRC}/Info.plist" "${HELPER_APP}/Contents/"

# Create variant helpers (GPU, Renderer, Plugin).
for variant in "GPU" "Renderer" "Plugin"; do
  VARIANT_NAME="webview_cef Helper (${variant})"
  VARIANT_APP="${HELPER_BUILD_DIR}/${VARIANT_NAME}.app"

  mkdir -p "${VARIANT_APP}/Contents/MacOS"
  cp "${HELPER_BUILD_DIR}/webview_cef Helper" "${VARIANT_APP}/Contents/MacOS/${VARIANT_NAME}"
  cp "${HELPER_SRC}/Info.plist" "${VARIANT_APP}/Contents/"

  /usr/libexec/PlistBuddy -c "Set :CFBundleName ${VARIANT_NAME}" "${VARIANT_APP}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${VARIANT_NAME}" "${VARIANT_APP}/Contents/Info.plist"
done

# Ensure all helper bundles are code-signed so GPU/Renderer subprocesses can
# launch under modern macOS code-signing validation.
HELPER_APPS=(
  "${HELPER_BUILD_DIR}/webview_cef Helper.app"
  "${HELPER_BUILD_DIR}/webview_cef Helper (GPU).app"
  "${HELPER_BUILD_DIR}/webview_cef Helper (Renderer).app"
  "${HELPER_BUILD_DIR}/webview_cef Helper (Plugin).app"
)

for HELPER_APP_PATH in "${HELPER_APPS[@]}"; do
  HELPER_EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${HELPER_APP_PATH}/Contents/Info.plist")"
  /usr/bin/codesign --force --sign - --timestamp=none \
    "${HELPER_APP_PATH}/Contents/MacOS/${HELPER_EXE}"
  /usr/bin/codesign --force --sign - --timestamp=none \
    "${HELPER_APP_PATH}"
  /usr/bin/codesign --verify --deep --strict "${HELPER_APP_PATH}"
done

echo "CEF helpers built successfully at ${HELPER_BUILD_DIR}"
),
    :execution_position => :before_compile,
    :shell_path => '/bin/bash'
  }
end
