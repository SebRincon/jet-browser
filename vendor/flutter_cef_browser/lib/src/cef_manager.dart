import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'cef_browser_controller.dart';
import 'models/download_item.dart';
import 'models/console_entry.dart';
import 'models/cef_parity_event.dart';
import 'models/cef_render_backend.dart';
import 'models/network_request.dart';
import 'models/runtime_contract.dart';

/// Browser event types
enum BrowserEventType {
  browserCreated,
  browserCreateFailed,
  browserClosed,
  titleChanged,
  urlChanged,
  loadingStateChanged,
  loadError,
  loadProgress,
  popupRequested,
  faviconChanged,
  authRequired,
  focusChanged,
  loadEnd,
  audioStateChanged,
}

/// Browser event data
class BrowserEvent {
  final BrowserEventType type;
  final int browserId;
  final Map<String, dynamic> data;

  const BrowserEvent({
    required this.type,
    required this.browserId,
    required this.data,
  });

  static BrowserEvent? fromMap(Map<String, dynamic> map) {
    final typeStr = map['type'] as String? ?? '';
    BrowserEventType type;
    switch (typeStr) {
      case 'browserCreated':
        type = BrowserEventType.browserCreated;
        break;
      case 'browserCreateFailed':
        type = BrowserEventType.browserCreateFailed;
        break;
      case 'browserClosed':
        type = BrowserEventType.browserClosed;
        break;
      case 'titleChanged':
        type = BrowserEventType.titleChanged;
        break;
      case 'urlChanged':
        type = BrowserEventType.urlChanged;
        break;
      case 'loadingStateChanged':
        type = BrowserEventType.loadingStateChanged;
        break;
      case 'loadError':
        type = BrowserEventType.loadError;
        break;
      case 'loadProgress':
        type = BrowserEventType.loadProgress;
        break;
      case 'popupRequested':
        type = BrowserEventType.popupRequested;
        break;
      case 'faviconChanged':
        type = BrowserEventType.faviconChanged;
        break;
      case 'authRequired':
        type = BrowserEventType.authRequired;
        break;
      case 'focusChanged':
        type = BrowserEventType.focusChanged;
        break;
      case 'loadEnd':
        type = BrowserEventType.loadEnd;
        break;
      case 'audioStateChanged':
        type = BrowserEventType.audioStateChanged;
        break;
      default:
        // Unknown event type — skip rather than misrouting as browserCreated.
        return null;
    }

    return BrowserEvent(
      type: type,
      browserId: map['browserId'] as int? ?? 0,
      data: Map<String, dynamic>.from(map),
    );
  }
}

/// Manages CEF framework lifecycle and browser instances
class CefManager {
  static CefManager? _instance;
  static CefManager get instance => _instance ??= CefManager._();
  static int _nextBrowserId = 1;

  /// Public constructor for creating instances
  factory CefManager() => instance;

  CefManager._();

  // Platform channel
  static const _methodChannel = MethodChannel('com.example/cef_browser');
  static const _browserEventsChannel =
      EventChannel('com.example/cef_browser/browser_events');
  static const _downloadsChannel =
      EventChannel('com.example/cef_browser/downloads');
  static const _consoleChannel =
      EventChannel('com.example/cef_browser/console');
  static const _networkChannel =
      EventChannel('com.example/cef_browser/network');

  // Browser controllers by ID
  final Map<int, CefBrowserController> _browsers = {};

  // Download items by ID
  final Map<int, DownloadItem> _downloads = {};

  // Stream subscriptions
  StreamSubscription? _browserEventsSubscription;
  StreamSubscription? _downloadsSubscription;
  StreamSubscription? _consoleSubscription;
  StreamSubscription? _networkSubscription;

  // Public streams
  final _browserEventController = StreamController<BrowserEvent>.broadcast();
  Stream<BrowserEvent> get browserEvents => _browserEventController.stream;

  final _downloadController = StreamController<DownloadItem>.broadcast();
  Stream<DownloadItem> get downloads => _downloadController.stream;
  Stream<DownloadItem> get downloadStream =>
      _downloadController.stream; // Alias

  final _consoleEntryController = StreamController<ConsoleEntry>.broadcast();
  Stream<ConsoleEntry> get consoleEntries => _consoleEntryController.stream;

  // Popup request stream for tab management
  final _popupController = StreamController<PopupRequest>.broadcast();
  Stream<PopupRequest> get popupStream => _popupController.stream;

  final _diagnosticController =
      StreamController<Map<String, Object?>>.broadcast();
  Stream<Map<String, Object?>> get diagnostics => _diagnosticController.stream;

  // Initialization state
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  int? _pluginInstanceId;
  bool _deterministicCreate = false;
  Duration _deterministicCreateTimeout = const Duration(seconds: 5);
  int _nextCreateRequestId = 1;
  final Map<String, _PendingCreateRequest> _pendingCreateRequestsByRequestId =
      <String, _PendingCreateRequest>{};
  final Map<int, _PendingCreateRequest> _pendingCreateRequestsByBrowserId =
      <int, _PendingCreateRequest>{};
  final Set<String> _abandonedCreateRequestIds = <String>{};
  final Set<int> _abandonedCreateBrowserIds = <int>{};

  /// Run native startup preflight using the exact config that will be used for
  /// initialization.
  Future<CefPreflightReport> runPreflight(CefRuntimeConfig config) async {
    try {
      final rawResult = await _methodChannel.invokeMethod<Object?>(
        'runPreflight',
        <String, Object?>{'config': config.toMap()},
      );
      if (rawResult is Map) {
        return CefPreflightReport.fromMap(rawResult);
      }
    } catch (error) {
      debugPrint('CefManager: Failed to run CEF preflight: $error');
    }

    return CefPreflightReport(
      status: 'failed',
      source: 'manager_fallback',
      capturedAt: DateTime.now(),
      config: config,
      warnings: const <CefPreflightIssue>[],
      failures: const <CefPreflightIssue>[
        CefPreflightIssue(
          code: 'native_preflight_unavailable',
          severity: CefPreflightIssueSeverity.failure,
          message: 'Native CEF preflight did not return a structured report',
        ),
      ],
    );
  }

  /// Initialize CEF framework.
  Future<CefInitializeResult> initialize({
    CefRuntimeConfig? config,
    String? cachePath,
    String? rootCachePath,
    String? userAgent,
    bool chromeRuntime = false,
    List<String> extensionPaths = const [],
    String cefProfile = 'prod-safe',
    Map<String, String?> profileSwitches = const <String, String?>{},
    Map<String, String?> extraSwitches = const <String, String?>{},
    List<String> removeSwitches = const <String>[],
    String closePolicy = 'graceful_then_force',
    int gracefulCloseTimeoutMs = 1200,
    String messagePumpMode = 'cef_sample_compatible',
    int maxPumpDelayMs = 33,
    bool enableMessagePumpFallbackTimer = true,
    bool deterministicCreate = false,
    int deterministicCreateTimeoutMs = 5000,
    bool requireHelper = true,
    bool useMockKeychain = false,
    bool enableWindowlessRendering = false,
    String launchMode = 'unknown',
    int remoteDebuggingPort = 0,
    String logFilePath = '',
    String crashDumpsPath = '',
    int uncaughtExceptionStackSize = 10,
  }) async {
    if (_isInitialized) {
      return CefInitializeResult(
        success: true,
        preflightReport: CefPreflightReport(
          status: 'already_initialized',
          source: 'manager',
          capturedAt: DateTime.now(),
          config: config ??
              CefRuntimeConfig(
                cachePath: cachePath ?? '',
                rootCachePath: rootCachePath ?? '',
                userAgent: userAgent,
                chromeRuntime: chromeRuntime,
                extensionPaths: extensionPaths,
                cefProfile: cefProfile,
                profileSwitches: profileSwitches,
                extraSwitches: extraSwitches,
                removeSwitches: removeSwitches,
                closePolicy: closePolicy,
                gracefulCloseTimeoutMs: gracefulCloseTimeoutMs,
                messagePumpMode: messagePumpMode,
                maxPumpDelayMs: maxPumpDelayMs,
                enableMessagePumpFallbackTimer: enableMessagePumpFallbackTimer,
                deterministicCreate: deterministicCreate,
                deterministicCreateTimeoutMs: deterministicCreateTimeoutMs,
                requireHelper: requireHelper,
                useMockKeychain: useMockKeychain,
                enableWindowlessRendering: enableWindowlessRendering,
                launchMode: launchMode,
                remoteDebuggingPort: remoteDebuggingPort,
                logFilePath: logFilePath,
                crashDumpsPath: crashDumpsPath,
                uncaughtExceptionStackSize: uncaughtExceptionStackSize,
              ),
          warnings: const <CefPreflightIssue>[],
          failures: const <CefPreflightIssue>[],
        ),
      );
    }

    final effectiveConfig = config ??
        CefRuntimeConfig(
          cachePath: cachePath ?? '',
          rootCachePath: rootCachePath ?? '',
          userAgent: userAgent,
          chromeRuntime: chromeRuntime,
          extensionPaths: extensionPaths,
          cefProfile: cefProfile,
          profileSwitches: profileSwitches,
          extraSwitches: extraSwitches,
          removeSwitches: removeSwitches,
          closePolicy: closePolicy,
          gracefulCloseTimeoutMs: gracefulCloseTimeoutMs,
          messagePumpMode: messagePumpMode,
          maxPumpDelayMs: maxPumpDelayMs,
          enableMessagePumpFallbackTimer: enableMessagePumpFallbackTimer,
          deterministicCreate: deterministicCreate,
          deterministicCreateTimeoutMs: deterministicCreateTimeoutMs,
          requireHelper: requireHelper,
          useMockKeychain: useMockKeychain,
          enableWindowlessRendering: enableWindowlessRendering,
          launchMode: launchMode,
          remoteDebuggingPort: remoteDebuggingPort,
          logFilePath: logFilePath,
          crashDumpsPath: crashDumpsPath,
          uncaughtExceptionStackSize: uncaughtExceptionStackSize,
        );

    _deterministicCreate = effectiveConfig.deterministicCreate;
    _deterministicCreateTimeout = Duration(
      milliseconds: effectiveConfig.deterministicCreateTimeoutMs,
    );

    try {
      final rawResult = await _methodChannel.invokeMethod<Object?>(
        'initialize',
        <String, Object?>{'config': effectiveConfig.toMap()},
      );
      final result = CefInitializeResult.fromMethodChannelResult(rawResult);

      if (result.success) {
        _isInitialized = true;
        _setupEventListeners();
        try {
          _pluginInstanceId =
              await _methodChannel.invokeMethod<int>('getInstanceId');
        } catch (_) {
          _pluginInstanceId = null;
        }
      }

      return result;
    } catch (e) {
      debugPrint('CefManager: Failed to initialize CEF: $e');
      return CefInitializeResult(
        success: false,
        failureStage: 'manager_exception',
        message: e.toString(),
      );
    }
  }

  /// Force-close every browser without waiting for unload handlers.
  ///
  /// Use on app quit so native `windowShouldClose` is not blocked for seconds
  /// while CEF drains. Does **not** call [CefShutdown] — process exit does.
  Future<void> closeAllBrowsersImmediately() async {
    if (!_isInitialized) return;
    _failAllPendingCreateRequests('closeAllBrowsersImmediately');
    _clearAbandonedCreateMarkers();
    _browsers.clear();
    try {
      await _methodChannel.invokeMethod('closeAllBrowsersImmediately');
    } catch (e) {
      debugPrint('CefManager: closeAllBrowsersImmediately failed: $e');
    }
  }

  /// Shutdown CEF framework
  Future<void> shutdown() async {
    if (!_isInitialized) return;

    _failAllPendingCreateRequests('shutdown');
    _clearAbandonedCreateMarkers();

    // Force-close first (fast); fall back only if channel lacks the method.
    try {
      await _methodChannel.invokeMethod('closeAllBrowsersImmediately');
    } catch (_) {
      for (final browser in _browsers.values.toList()) {
        try {
          await closeBrowser(browser.browserId);
        } catch (_) {}
      }
    }
    _browsers.clear();

    // Cancel subscriptions
    await _browserEventsSubscription?.cancel();
    await _downloadsSubscription?.cancel();
    await _consoleSubscription?.cancel();
    await _networkSubscription?.cancel();

    await _methodChannel.invokeMethod('shutdown');
    _isInitialized = false;
  }

  int _composeBrowserId(int localBrowserId) {
    final instanceId = _pluginInstanceId;
    if (instanceId == null || instanceId <= 0) return localBrowserId;

    // Encode instanceId into the high 16 bits so browserIds are unique across
    // multiple Flutter engines/windows in the same process.
    return (instanceId << 16) | (localBrowserId & 0xFFFF);
  }

  /// Create a new browser instance
  Future<CefBrowserController?> createBrowser({
    required String url,
    bool incognito = false,
    required double x,
    required double y,
    required double width,
    required double height,
    double? viewWidth,
    double? viewHeight,
    double? deviceScaleFactor,
    CefRenderBackend renderBackend = CefRenderBackend.nativeView,
  }) async {
    if (!_isInitialized) {
      debugPrint('CefManager: CEF not initialized');
      return null;
    }

    _PendingCreateRequest? pendingCreate;
    try {
      // Generate browserId unique across engines/windows.
      final localId = _nextBrowserId++;
      final id = _composeBrowserId(localId);
      final createRequestId =
          _deterministicCreate ? _nextDeterministicCreateRequestId(id) : null;
      pendingCreate = createRequestId == null
          ? null
          : _registerPendingCreateRequest(
              browserId: id,
              createRequestId: createRequestId,
            );

      final result = await _methodChannel
          .invokeMethod<Object?>('createBrowser', <String, Object?>{
        'id': id,
        'url': url,
        'incognito': incognito,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        if (viewWidth != null) 'viewWidth': viewWidth,
        if (viewHeight != null) 'viewHeight': viewHeight,
        if (deviceScaleFactor != null) 'deviceScaleFactor': deviceScaleFactor,
        'renderBackend': renderBackend.channelName,
        if (createRequestId != null) 'createRequestId': createRequestId,
      });

      final createResult = _BrowserCreateResult.fromNative(result);
      if (!createResult.success) {
        if (pendingCreate != null) {
          _completePendingCreateRequest(
            pendingCreate,
            success: false,
            reason: 'createBrowser returned false',
          );
        }
        return null;
      }

      if (_deterministicCreate && pendingCreate != null) {
        final acknowledged = await pendingCreate.completer.future;
        if (!acknowledged) {
          return null;
        }
      }

      final controller = CefBrowserController(
        browserId: id,
        channel: _methodChannel,
        renderBackend: createResult.renderBackend ?? renderBackend,
        textureId: createResult.textureId,
      );
      _browsers[id] = controller;
      final deferredCreatedEvent = pendingCreate?.browserCreatedEvent;
      if (deferredCreatedEvent != null && !_browserEventController.isClosed) {
        _browserEventController.add(deferredCreatedEvent);
      }
      return controller;
    } catch (e) {
      if (pendingCreate != null) {
        _completePendingCreateRequest(
          pendingCreate,
          success: false,
          reason: 'exception: $e',
        );
      }
      debugPrint('CefManager: Failed to create browser: $e');
      return null;
    }
  }

  /// Close a browser instance
  Future<void> closeBrowser(int browserId, {bool force = false}) async {
    final controller = _browsers.remove(browserId);
    controller?.dispose();

    await _methodChannel.invokeMethod('closeBrowser', {
      'id': browserId,
      'force': force,
    });
  }

  /// Opens Chrome DevTools for a texture-backed browser as its own
  /// windowless browser rendered through the same texture pipeline
  /// (spec 016 US4). Returns a controller for the DevTools surface, or
  /// `null` when unavailable (e.g. nativeView backend, which uses the
  /// legacy docked path natively).
  ///
  /// Pass [inspectX]/[inspectY] (view coordinates) to focus the DOM node at
  /// that point (right-click → Inspect Element).
  Future<CefBrowserController?> openDevTools(
    int ownerBrowserId, {
    int? inspectX,
    int? inspectY,
  }) async {
    final owner = _browsers[ownerBrowserId];
    try {
      final result = await _methodChannel.invokeMethod<Map>('openDevTools', {
        'id': ownerBrowserId,
        if (inspectX != null) 'inspectX': inspectX,
        if (inspectY != null) 'inspectY': inspectY,
      });
      if (result == null || result['devToolsBrowserId'] is! int) {
        return null;
      }
      final devToolsBrowserId = result['devToolsBrowserId'] as int;
      final existing = _browsers[devToolsBrowserId];
      if (existing != null && !existing.isDisposed) {
        return existing;
      }
      final controller = CefBrowserController(
        browserId: devToolsBrowserId,
        channel: _methodChannel,
        renderBackend: CefRenderBackend.fromChannelName(
          result['renderBackend'] as String? ??
              owner?.renderBackend.channelName,
        ),
        textureId: result['textureId'] as int?,
      );
      _browsers[devToolsBrowserId] = controller;
      return controller;
    } catch (e) {
      debugPrint('CefManager: Failed to open DevTools: $e');
      return null;
    }
  }

  /// Closes the DevTools surface associated with [ownerBrowserId], if any.
  Future<void> closeDevTools(int ownerBrowserId) async {
    await _methodChannel.invokeMethod('closeDevTools', {'id': ownerBrowserId});
  }

  /// Disposes the Dart-side controller for a DevTools surface after the
  /// native browser has closed (drives on the owner's `devToolsClosed`
  /// parity event or explicit pane teardown).
  void releaseDevToolsController(int devToolsBrowserId) {
    final controller = _browsers.remove(devToolsBrowserId);
    controller?.dispose();
  }

  /// Get browser controller by ID
  CefBrowserController? getBrowser(int browserId) {
    return _browsers[browserId];
  }

  /// Get all browser controllers
  List<CefBrowserController> get allBrowsers => _browsers.values.toList();

  /// Hide every native browser surface not listed in [keepVisibleBrowserIds].
  ///
  /// This is intentionally manager-scoped, not controller-scoped: desktop and
  /// workspace switches sometimes need to hide stale native surfaces before the
  /// old Flutter browser widget can run its normal inactive lifecycle.
  Future<Map<String, Object?>> hideStaleBrowsers({
    Iterable<int> keepVisibleBrowserIds = const <int>[],
    String reason = 'hideStaleBrowsers',
  }) async {
    final result = await _methodChannel.invokeMethod<Object?>(
      'hideStaleBrowsers',
      <String, Object?>{
        'keepVisibleBrowserIds': keepVisibleBrowserIds.toList(growable: false),
        'reason': reason,
      },
    );
    if (result is Map) {
      return result.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, Object?>{};
  }

  // Download management

  /// Pause a download
  Future<void> pauseDownload(int downloadId) async {
    await _methodChannel
        .invokeMethod('pauseDownload', {'downloadId': downloadId});
  }

  /// Resume a download
  Future<void> resumeDownload(int downloadId) async {
    await _methodChannel
        .invokeMethod('resumeDownload', {'downloadId': downloadId});
  }

  /// Cancel a download
  Future<void> cancelDownload(int downloadId) async {
    await _methodChannel
        .invokeMethod('cancelDownload', {'downloadId': downloadId});
  }

  /// Get download by ID
  DownloadItem? getDownload(int downloadId) {
    return _downloads[downloadId];
  }

  /// Get all active downloads
  List<DownloadItem> get activeDownloads {
    return _downloads.values
        .where((d) =>
            d.status == DownloadStatus.inProgress ||
            d.status == DownloadStatus.paused)
        .toList();
  }

  // Cookie management

  /// Clear all cookies
  Future<void> clearCookies({bool incognito = false}) async {
    await _methodChannel.invokeMethod('clearCookies', {
      'incognito': incognito,
    });
  }

  /// Get cookies for a URL
  Future<List<Map<String, dynamic>>> getCookies({
    String? url,
    bool incognito = false,
  }) async {
    final result = await _methodChannel.invokeMethod<List>('getCookies', {
      'url': url,
      'incognito': incognito,
    });
    if (result == null) return const [];
    return result
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  // Event handling

  void _setupEventListeners() {
    // Browser events
    _browserEventsSubscription = _browserEventsChannel
        .receiveBroadcastStream('browser_events')
        .listen(_handleBrowserEvent);

    // Download events
    _downloadsSubscription = _downloadsChannel
        .receiveBroadcastStream('downloads')
        .listen(_handleDownloadEvent);

    // Console events
    _consoleSubscription = _consoleChannel
        .receiveBroadcastStream('console')
        .listen(_handleConsoleEvent);

    // Network events
    _networkSubscription = _networkChannel
        .receiveBroadcastStream('network')
        .listen(_handleNetworkEvent);
  }

  void _handleBrowserEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);

    if (map['type'] == 'findResult') {
      final browserId = map['browserId'];
      final controller = browserId is int ? _browsers[browserId] : null;
      controller?.updateState(
        controller.state.copyWith(
          findMatchCount: map['count'] as int?,
          findActiveMatchOrdinal: map['activeMatchOrdinal'] as int?,
        ),
      );
      return;
    }

    final parityEvent = CefParityEvent.fromMap(map);
    if (parityEvent != null) {
      // Events for browsers this manager does not own are dropped silently:
      // tab teardown races make them normal, not errors.
      _browsers[parityEvent.browserId]?.addParityEvent(parityEvent);
      return;
    }

    final browserEvent = BrowserEvent.fromMap(map);
    if (browserEvent == null) return;

    final type = map['type'] as String?;
    final browserId = map['browserId'] as int?;

    final deferredPendingCreateEvent = _handlePendingCreateEvent(
      map,
      browserEvent,
    );
    if (!deferredPendingCreateEvent) {
      _browserEventController.add(browserEvent);
    }

    if (browserId == null) return;

    final controller = _browsers[browserId];

    switch (type) {
      case 'browserCreated':
      case 'browserCreateFailed':
      case 'browserClosed':
        break;
      case 'titleChanged':
        controller?.updateState(controller.state.copyWith(
          title: map['title'] as String?,
        ));
        break;
      case 'urlChanged':
        controller?.updateState(controller.state.copyWith(
          url: map['url'] as String?,
        ));
        break;
      case 'loadingStateChanged':
        controller?.updateState(controller.state.copyWith(
          isLoading: map['isLoading'] as bool?,
          canGoBack: map['canGoBack'] as bool?,
          canGoForward: map['canGoForward'] as bool?,
        ));
        break;
      case 'loadProgress':
        controller?.updateState(controller.state.copyWith(
          loadProgress: (map['progress'] as num?)?.toDouble(),
        ));
        break;
      case 'loadError':
        // Already emitted to browserEvents stream
        break;
      case 'popupRequested':
        _popupController.add(PopupRequest.fromMap(map));
        break;
      case 'faviconChanged':
        final urls = map['urls'];
        if (urls is List) {
          controller?.updateState(controller.state.copyWith(
            faviconUrls: urls.cast<String>(),
          ));
        }
        break;
      case 'audioStateChanged':
        controller?.updateState(controller.state.copyWith(
          isAudible: map['audible'] as bool?,
        ));
        break;
      case 'loadEnd':
        break;
    }
  }

  void _handleDownloadEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);

    final downloadItem = DownloadItem.fromMap(map);
    _downloads[downloadItem.downloadId] = downloadItem;
    _downloadController.add(downloadItem);
  }

  void _handleConsoleEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);

    final entry = ConsoleEntry.fromMap(map);

    // Emit to public stream
    _consoleEntryController.add(entry);

    final controller = _browsers[entry.browserId];
    controller?.addConsoleEntry(entry);
  }

  void _handleNetworkEvent(dynamic event) {
    if (event is! Map) return;
    final map = Map<String, dynamic>.from(event);

    final request = NetworkRequest.fromMap(map);
    final controller = _browsers[request.browserId];
    controller?.addNetworkRequest(request);
  }

  String _nextDeterministicCreateRequestId(int browserId) {
    final seq = _nextCreateRequestId++;
    return 'create_${browserId}_$seq';
  }

  void _emitDiagnostic(
    String type, {
    int? browserId,
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    if (_diagnosticController.isClosed) return;
    _diagnosticController.add(<String, Object?>{
      'type': type,
      if (browserId != null) 'browserId': browserId,
      ...details,
    });
  }

  _PendingCreateRequest _registerPendingCreateRequest({
    required int browserId,
    required String createRequestId,
  }) {
    _abandonedCreateRequestIds.remove(createRequestId);
    _abandonedCreateBrowserIds.remove(browserId);
    final request = _PendingCreateRequest(
      browserId: browserId,
      createRequestId: createRequestId,
      completer: Completer<bool>(),
    );
    request.timeoutTimer = Timer(_deterministicCreateTimeout, () {
      _emitDiagnostic(
        'cef_deterministic_create_timeout',
        browserId: browserId,
        details: <String, Object?>{
          'createRequestId': createRequestId,
          'timeoutMs': _deterministicCreateTimeout.inMilliseconds,
        },
      );
      _completePendingCreateRequest(
        request,
        success: false,
        reason: 'timeout',
        markAbandoned: true,
      );
    });
    _pendingCreateRequestsByRequestId[createRequestId] = request;
    _pendingCreateRequestsByBrowserId[browserId] = request;
    return request;
  }

  bool _handlePendingCreateEvent(
    Map<String, dynamic> event,
    BrowserEvent browserEvent,
  ) {
    final type = event['type'] as String?;
    if (type != 'browserCreated' &&
        type != 'browserCreateFailed' &&
        type != 'browserClosed') {
      return false;
    }

    final browserId = event['browserId'] as int?;
    final createRequestId = event['createRequestId'] as String?;
    if (_handleAbandonedCreateEvent(
      type: type,
      browserId: browserId,
      createRequestId: createRequestId,
    )) {
      return false;
    }
    final pending = _matchPendingCreateRequest(
      browserId: browserId,
      createRequestId: createRequestId,
    );
    if (pending == null) return false;

    switch (type) {
      case 'browserCreated':
        pending.browserCreatedEvent = browserEvent;
        _completePendingCreateRequest(pending, success: true);
        return true;
      case 'browserCreateFailed':
        _completePendingCreateRequest(
          pending,
          success: false,
          reason: event['reason'] as String? ?? 'browserCreateFailed',
        );
        return false;
      case 'browserClosed':
        _completePendingCreateRequest(
          pending,
          success: false,
          reason: 'browserClosed before create ack',
        );
        return false;
    }
    return false;
  }

  _PendingCreateRequest? _matchPendingCreateRequest({
    required int? browserId,
    required String? createRequestId,
  }) {
    if (createRequestId != null && createRequestId.isNotEmpty) {
      final byRequestId = _pendingCreateRequestsByRequestId[createRequestId];
      if (byRequestId != null) return byRequestId;
    }
    if (browserId != null) {
      return _pendingCreateRequestsByBrowserId[browserId];
    }
    return null;
  }

  void _completePendingCreateRequest(
    _PendingCreateRequest request, {
    required bool success,
    String? reason,
    bool markAbandoned = false,
  }) {
    _pendingCreateRequestsByRequestId.remove(request.createRequestId);
    final byBrowserId = _pendingCreateRequestsByBrowserId[request.browserId];
    if (identical(byBrowserId, request)) {
      _pendingCreateRequestsByBrowserId.remove(request.browserId);
    }

    request.timeoutTimer?.cancel();
    request.timeoutTimer = null;
    if (request.completer.isCompleted) {
      return;
    }

    if (markAbandoned && _deterministicCreate) {
      _abandonedCreateRequestIds.add(request.createRequestId);
      _abandonedCreateBrowserIds.add(request.browserId);
    } else {
      _abandonedCreateRequestIds.remove(request.createRequestId);
      _abandonedCreateBrowserIds.remove(request.browserId);
    }

    if (!success && reason != null) {
      debugPrint(
        'CefManager: createBrowser failed for ${request.browserId} '
        '(${request.createRequestId}): $reason',
      );
    }
    request.completer.complete(success);
  }

  void _failAllPendingCreateRequests(String reason) {
    final pending = _pendingCreateRequestsByRequestId.values.toList(
      growable: false,
    );
    _pendingCreateRequestsByRequestId.clear();
    _pendingCreateRequestsByBrowserId.clear();
    for (final request in pending) {
      request.timeoutTimer?.cancel();
      request.timeoutTimer = null;
      _abandonedCreateRequestIds.remove(request.createRequestId);
      _abandonedCreateBrowserIds.remove(request.browserId);
      if (!request.completer.isCompleted) {
        request.completer.complete(false);
      }
      debugPrint(
        'CefManager: abandoning pending create for ${request.browserId} '
        '(${request.createRequestId}): $reason',
      );
    }
  }

  bool _handleAbandonedCreateEvent({
    required String? type,
    required int? browserId,
    required String? createRequestId,
  }) {
    final matchesAbandonedRequest = createRequestId != null &&
        createRequestId.isNotEmpty &&
        _abandonedCreateRequestIds.contains(createRequestId);
    final matchesAbandonedBrowser =
        browserId != null && _abandonedCreateBrowserIds.contains(browserId);
    if (!matchesAbandonedRequest && !matchesAbandonedBrowser) {
      return false;
    }

    if (type == 'browserCreated' && browserId != null) {
      debugPrint(
        'CefManager: force-closing late-created browser $browserId '
        '(requestId=${createRequestId ?? '<none>'}) after deterministic timeout',
      );
      _emitDiagnostic(
        'cef_deterministic_create_late_orphan_closed',
        browserId: browserId,
        details: <String, Object?>{
          'createRequestId': createRequestId,
          'reason': 'late_create_after_timeout',
        },
      );
      unawaited(
        closeBrowser(browserId, force: true).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          debugPrint(
            'CefManager: failed to close late-created orphan browser '
            '$browserId: $error',
          );
        }),
      );
    }

    if (createRequestId != null && createRequestId.isNotEmpty) {
      _abandonedCreateRequestIds.remove(createRequestId);
    }
    if (browserId != null) {
      _abandonedCreateBrowserIds.remove(browserId);
    }
    return true;
  }

  void _clearAbandonedCreateMarkers() {
    _abandonedCreateRequestIds.clear();
    _abandonedCreateBrowserIds.clear();
  }

  /// Dispose of all resources
  void dispose() {
    _failAllPendingCreateRequests('dispose');
    _clearAbandonedCreateMarkers();
    for (final controller in _browsers.values) {
      controller.dispose();
    }
    _browsers.clear();

    _browserEventController.close();
    _downloadController.close();
    _consoleEntryController.close();
    _popupController.close();
    _diagnosticController.close();

    _browserEventsSubscription?.cancel();
    _downloadsSubscription?.cancel();
    _consoleSubscription?.cancel();
    _networkSubscription?.cancel();

    _instance = null;
  }
}

/// Export PopupRequest for external use
class PopupRequest {
  final int browserId;
  final String source;
  final String targetUrl;
  final String targetFrameName;
  final int? popupId;
  final int? targetDisposition;
  final String targetDispositionName;
  final bool userGesture;
  final PopupFeatures popupFeatures;

  const PopupRequest({
    required this.browserId,
    this.source = 'beforePopup',
    required this.targetUrl,
    this.targetFrameName = '',
    this.popupId,
    this.targetDisposition,
    this.targetDispositionName = 'unknown',
    this.userGesture = false,
    this.popupFeatures = const PopupFeatures(),
  });

  factory PopupRequest.fromMap(Map<String, dynamic> map) {
    return PopupRequest(
      browserId: map['browserId'] as int? ?? 0,
      source: map['source'] as String? ?? 'beforePopup',
      targetUrl: (map['targetUrl'] ?? map['url'] ?? '') as String,
      targetFrameName: map['targetFrameName'] as String? ?? '',
      popupId: _intFromValue(map['popupId']),
      targetDisposition: _intFromValue(map['targetDisposition']),
      targetDispositionName: map['targetDispositionName'] as String? ??
          _dispositionNameForValue(map['targetDisposition']),
      userGesture: map['userGesture'] as bool? ?? false,
      popupFeatures: PopupFeatures.fromMap(
        Map<String, dynamic>.from(
          map['popupFeatures'] as Map? ?? const <String, dynamic>{},
        ),
      ),
    );
  }

  bool get isPopup => popupFeatures.isPopup;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'browserId': browserId,
      'source': source,
      'targetUrl': targetUrl,
      'targetFrameName': targetFrameName,
      if (popupId != null) 'popupId': popupId,
      if (targetDisposition != null) 'targetDisposition': targetDisposition,
      'targetDispositionName': targetDispositionName,
      'userGesture': userGesture,
      'popupFeatures': popupFeatures.toMap(),
    };
  }

  static String _dispositionNameForValue(Object? value) {
    final disposition = _intFromValue(value);
    return switch (disposition) {
      1 => 'currentTab',
      2 => 'singletonTab',
      3 => 'newForegroundTab',
      4 => 'newBackgroundTab',
      5 => 'newPopup',
      6 => 'newWindow',
      7 => 'saveToDisk',
      8 => 'offTheRecord',
      9 => 'ignoreAction',
      10 => 'switchToTab',
      11 => 'newPictureInPicture',
      _ => 'unknown',
    };
  }

  static int? _intFromValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

class PopupFeatures {
  final int x;
  final bool xSet;
  final int y;
  final bool ySet;
  final int width;
  final bool widthSet;
  final int height;
  final bool heightSet;
  final bool isPopup;

  const PopupFeatures({
    this.x = 0,
    this.xSet = false,
    this.y = 0,
    this.ySet = false,
    this.width = 0,
    this.widthSet = false,
    this.height = 0,
    this.heightSet = false,
    this.isPopup = false,
  });

  factory PopupFeatures.fromMap(Map<String, dynamic> map) {
    return PopupFeatures(
      x: _intFromValue(map['x']) ?? 0,
      xSet: map['xSet'] as bool? ?? false,
      y: _intFromValue(map['y']) ?? 0,
      ySet: map['ySet'] as bool? ?? false,
      width: _intFromValue(map['width']) ?? 0,
      widthSet: map['widthSet'] as bool? ?? false,
      height: _intFromValue(map['height']) ?? 0,
      heightSet: map['heightSet'] as bool? ?? false,
      isPopup: map['isPopup'] as bool? ?? false,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'x': x,
      'xSet': xSet,
      'y': y,
      'ySet': ySet,
      'width': width,
      'widthSet': widthSet,
      'height': height,
      'heightSet': heightSet,
      'isPopup': isPopup,
    };
  }

  static int? _intFromValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

class _BrowserCreateResult {
  const _BrowserCreateResult({
    required this.success,
    this.renderBackend,
    this.textureId,
  });

  final bool success;
  final CefRenderBackend? renderBackend;
  final int? textureId;

  factory _BrowserCreateResult.fromNative(Object? value) {
    if (value is bool) {
      return _BrowserCreateResult(success: value);
    }
    if (value is Map) {
      final map = Map<String, Object?>.from(value);
      return _BrowserCreateResult(
        success: map['success'] as bool? ?? false,
        renderBackend: CefRenderBackend.fromChannelName(
          map['renderBackend'] as String?,
        ),
        textureId: _intFromValue(map['textureId']),
      );
    }
    return const _BrowserCreateResult(success: false);
  }

  static int? _intFromValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

class _PendingCreateRequest {
  _PendingCreateRequest({
    required this.browserId,
    required this.createRequestId,
    required this.completer,
  });

  final int browserId;
  final String createRequestId;
  final Completer<bool> completer;
  BrowserEvent? browserCreatedEvent;
  Timer? timeoutTimer;
}
