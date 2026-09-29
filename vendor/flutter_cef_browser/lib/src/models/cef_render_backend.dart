/// Selects how CEF presents a browser surface.
enum CefRenderBackend {
  /// Existing macOS native child-view path (`CefWindowInfo::SetAsChild`).
  nativeView('nativeView'),

  /// Experimental off-screen rendering path backed by a Flutter texture.
  osrTexture('osrTexture'),

  /// GPU-accelerated OSR copied into an app-owned Flutter texture.
  acceleratedOsrTexture('acceleratedOsrTexture');

  const CefRenderBackend(this.channelName);

  final String channelName;

  static CefRenderBackend fromChannelName(String? value) {
    for (final backend in CefRenderBackend.values) {
      if (backend.channelName == value) return backend;
    }
    return CefRenderBackend.nativeView;
  }
}
