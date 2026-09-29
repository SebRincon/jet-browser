import 'cef_render_backend.dart';

/// Bounded native counters for a CEF off-screen rendering texture.
class CefOsrPerformanceStats {
  const CefOsrPerformanceStats({
    required this.backend,
    required this.frameCount,
    required this.acceleratedFrameCount,
    required this.cpuFrameCount,
    required this.textureReadCount,
    this.uniqueTextureReadCount = 0,
    this.textureReadAttemptCount = 0,
    required this.droppedFrameCount,
    required this.coalescedFrameCount,
    required this.width,
    required this.height,
    required this.totalCopyDurationMicros,
    required this.maxCopyDurationMicros,
    required this.lastCopyDurationMicros,
    required this.lastError,
    required this.copiedBytes,
    required this.fullFrameCopies,
    required this.partialCopies,
    required this.averageDamageCoverage,
    required this.targetFps,
    required this.effectiveScale,
    this.zeroCopyFrameCount = 0,
    this.leasedAsyncBlitFrameCount = 0,
    this.staleAsyncLeaseDropCount = 0,
    this.frameLeaseFallbackCount = 0,
    this.frameTransferMode = 'copied',
    this.requestedFrameTransferMode = 'copied',
    this.frameLeaseApiAvailable = false,
    this.gpuCompletionApiObserved = false,
    this.quarantineDepth = 0,
    this.quarantinePoolsHeld = 0,
    this.quarantineReleasedTotal = 0,
    this.quarantineForcedReleases = 0,
    this.sourceFenceLastMicros = 0,
    this.sourceFenceMaxMicros = 0,
    this.sourceFenceFailures = 0,
  });

  final CefRenderBackend backend;
  final int frameCount;
  final int acceleratedFrameCount;
  final int cpuFrameCount;
  final int textureReadCount;

  /// Texture reads that observed a newly published CEF frame. Unlike
  /// [textureReadCount], repeated Flutter reads of the same copied buffer are
  /// counted only once, so this is comparable with one-shot direct leases.
  final int uniqueTextureReadCount;

  /// Calls from Flutter that attempted to populate this external texture,
  /// including attempts that found no newly leased frame.
  final int textureReadAttemptCount;
  final int droppedFrameCount;
  final int coalescedFrameCount;
  final int width;
  final int height;
  final int totalCopyDurationMicros;
  final int maxCopyDurationMicros;
  final int lastCopyDurationMicros;
  final String lastError;

  /// Total bytes transferred into published pixel buffers.
  final int copiedBytes;

  /// Frames published with a full-backing-store copy.
  final int fullFrameCopies;

  /// Frames published copying only accumulated damage regions.
  final int partialCopies;

  /// Mean fraction (0-1) of the backing store copied per published frame.
  final double averageDamageCoverage;

  /// Windowless frame-rate target currently applied to the browser.
  final int targetFps;

  /// Backing scale the OSR surface is currently allocated at.
  final double effectiveScale;

  /// Frames imported from CEF's IOSurface without the plugin's Metal blit.
  final int zeroCopyFrameCount;

  /// Frames copied asynchronously while a CEF producer lease kept the source
  /// IOSurface alive beyond the accelerated-paint callback.
  final int leasedAsyncBlitFrameCount;

  /// Completed asynchronous copies intentionally discarded because a resize,
  /// teardown, or newer leased frame made them stale.
  final int staleAsyncLeaseDropCount;

  /// Lease offers that used the compatibility copy path instead.
  final int frameLeaseFallbackCount;

  /// Most recently published transfer path: `copied`, `leased_async_blit`, or
  /// `leased_direct`.
  final String frameTransferMode;

  /// Transfer path selected by the runtime control. This may differ from
  /// [frameTransferMode] while direct mode awaits its Flutter handshake.
  final String requestedFrameTransferMode;

  /// Whether this process is linked against the experimental CEF frame-lease
  /// API. False guarantees that frames remain on the copied path.
  final bool frameLeaseApiAvailable;

  /// Whether the running Flutter engine advertised and invoked the
  /// GPU-completion handoff API required for safe direct IOSurface leasing.
  final bool gpuCompletionApiObserved;

  /// IOSurface quarantine (diagonal-shear resize fix): retired buffers currently
  /// held past the engine's composition read, superseded pools held, total
  /// released normally, and forced early releases (pool-starvation signal — a
  /// healthy fix keeps this at 0).
  final int quarantineDepth;
  final int quarantinePoolsHeld;
  final int quarantineReleasedTotal;
  final int quarantineForcedReleases;

  /// Source-write fence (diagonal-shear fix): time spent waiting out the GPU
  /// process's in-flight write to the delivered IOSurface before blitting.
  final int sourceFenceLastMicros;
  final int sourceFenceMaxMicros;
  final int sourceFenceFailures;

  int get averageCopyDurationMicros {
    final copiedFrameCount = fullFrameCopies + partialCopies;
    return copiedFrameCount == 0
        ? 0
        : totalCopyDurationMicros ~/ copiedFrameCount;
  }

  int pixelRateBytesPerSecond(int framesPerSecond) {
    if (width <= 0 || height <= 0 || framesPerSecond <= 0) return 0;
    return width * height * 4 * framesPerSecond;
  }

  factory CefOsrPerformanceStats.fromMap(Map<String, Object?> map) {
    return CefOsrPerformanceStats(
      backend: CefRenderBackend.fromChannelName(map['backend'] as String?),
      frameCount: _intValue(map['frameCount']),
      acceleratedFrameCount: _intValue(map['acceleratedFrameCount']),
      cpuFrameCount: _intValue(map['cpuFrameCount']),
      textureReadCount: _intValue(map['textureReadCount']),
      uniqueTextureReadCount: _intValue(map['uniqueTextureReadCount']),
      textureReadAttemptCount: _intValue(map['textureReadAttemptCount']),
      droppedFrameCount: _intValue(map['droppedFrameCount']),
      coalescedFrameCount: _intValue(map['coalescedFrameCount']),
      width: _intValue(map['width']),
      height: _intValue(map['height']),
      totalCopyDurationMicros: _intValue(map['totalCopyDurationMicros']),
      maxCopyDurationMicros: _intValue(map['maxCopyDurationMicros']),
      lastCopyDurationMicros: _intValue(map['lastCopyDurationMicros']),
      lastError: map['lastError'] as String? ?? '',
      copiedBytes: _intValue(map['copiedBytes']),
      fullFrameCopies: _intValue(map['fullFrameCopies']),
      partialCopies: _intValue(map['partialCopies']),
      averageDamageCoverage: _doubleValue(map['averageDamageCoverage']),
      targetFps: _intValue(map['targetFps']),
      effectiveScale: _doubleValue(map['effectiveScale']),
      zeroCopyFrameCount: _intValue(map['zeroCopyFrameCount']),
      leasedAsyncBlitFrameCount: _intValue(
        map['leasedAsyncBlitFrameCount'],
      ),
      staleAsyncLeaseDropCount: _intValue(map['staleAsyncLeaseDropCount']),
      frameLeaseFallbackCount: _intValue(map['frameLeaseFallbackCount']),
      frameTransferMode: map['frameTransferMode'] as String? ?? 'copied',
      requestedFrameTransferMode:
          map['requestedFrameTransferMode'] as String? ?? 'copied',
      frameLeaseApiAvailable: _boolValue(map['frameLeaseApiAvailable']),
      gpuCompletionApiObserved: _boolValue(map['gpuCompletionApiObserved']),
      quarantineDepth: _intValue(map['quarantineDepth']),
      quarantinePoolsHeld: _intValue(map['quarantinePoolsHeld']),
      quarantineReleasedTotal: _intValue(map['quarantineReleasedTotal']),
      quarantineForcedReleases: _intValue(map['quarantineForcedReleases']),
      sourceFenceLastMicros: _intValue(map['sourceFenceLastMicros']),
      sourceFenceMaxMicros: _intValue(map['sourceFenceMaxMicros']),
      sourceFenceFailures: _intValue(map['sourceFenceFailures']),
    );
  }

  static int _intValue(Object? value) => value is num ? value.toInt() : 0;

  static double _doubleValue(Object? value) =>
      value is num ? value.toDouble() : 0;

  static bool _boolValue(Object? value) =>
      value == true || (value is num && value != 0);
}
