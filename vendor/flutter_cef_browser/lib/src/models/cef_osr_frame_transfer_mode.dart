/// Requested CEF off-screen frame transfer strategy.
///
/// The native implementation may temporarily use a safer path while a
/// capability handshake completes. Read [CefOsrPerformanceStats] to compare
/// [requestedFrameTransferMode] with [frameTransferMode].
enum CefOsrFrameTransferMode {
  /// Existing compatibility path. CEF's IOSurface is copied into a plugin
  /// owned buffer before Flutter samples it.
  copied('copied'),

  /// Keep the CEF producer surface leased until an asynchronous Metal blit
  /// finishes, then publish the plugin-owned destination.
  leasedAsyncBlit('leased_async_blit'),

  /// Let Flutter sample CEF's IOSurface directly and release the producer
  /// lease only after all consuming GPU command buffers complete.
  leasedDirect('leased_direct');

  const CefOsrFrameTransferMode(this.channelName);

  final String channelName;

  static CefOsrFrameTransferMode fromChannelName(String? value) {
    return CefOsrFrameTransferMode.values.firstWhere(
      (mode) => mode.channelName == value,
      orElse: () => CefOsrFrameTransferMode.copied,
    );
  }
}
