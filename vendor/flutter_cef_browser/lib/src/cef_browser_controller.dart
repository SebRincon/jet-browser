import 'dart:async';
import 'package:flutter/services.dart';
import 'models/browser_state.dart';
import 'models/console_entry.dart';
import 'models/cef_parity_event.dart';
import 'models/cef_render_backend.dart';
import 'models/cef_osr_frame_transfer_mode.dart';
import 'models/cef_osr_performance_stats.dart';
import 'models/network_request.dart';

/// Controller for a single CEF browser instance
class CefBrowserController {
  final int browserId;
  final MethodChannel _channel;
  final CefRenderBackend renderBackend;
  final int? textureId;

  // State stream
  final _stateController = StreamController<BrowserState>.broadcast();
  Stream<BrowserState> get stateStream => _stateController.stream;

  // Console log stream
  final _consoleController = StreamController<ConsoleEntry>.broadcast();
  Stream<ConsoleEntry> get consoleStream => _consoleController.stream;

  // Network request stream
  final _networkController = StreamController<NetworkRequest>.broadcast();
  Stream<NetworkRequest> get networkStream => _networkController.stream;

  // Browser-parity event stream (tooltips, dialogs, IME, fullscreen, ...)
  final _parityController = StreamController<CefParityEvent>.broadcast();
  Stream<CefParityEvent> get parityEvents => _parityController.stream;

  // Current state
  BrowserState _state;
  BrowserState get state => _state;

  bool _disposed = false;
  bool get isDisposed => _disposed;

  CefBrowserController({
    required this.browserId,
    required MethodChannel channel,
    this.renderBackend = CefRenderBackend.nativeView,
    this.textureId,
  }) : _channel = channel,
       _state = BrowserState(browserId: browserId);

  /// Update state from native event
  void updateState(BrowserState newState) {
    if (_disposed) return;
    _state = newState;
    _stateController.add(_state);
  }

  /// Add console entry from native event
  void addConsoleEntry(ConsoleEntry entry) {
    if (_disposed) return;
    _consoleController.add(entry);
  }

  /// Add network request from native event
  void addNetworkRequest(NetworkRequest request) {
    if (_disposed) return;
    _networkController.add(request);
  }

  /// Add a parity event from the native event surface
  void addParityEvent(CefParityEvent event) {
    if (_disposed) return;
    _parityController.add(event);
  }

  // Navigation methods

  /// Load a URL
  Future<void> loadUrl(String url) async {
    await _channel.invokeMethod('loadUrl', {'id': browserId, 'url': url});
  }

  /// Reload the current page
  Future<void> reload({bool ignoreCache = false}) async {
    await _channel.invokeMethod('reload', {
      'id': browserId,
      'ignoreCache': ignoreCache,
    });
  }

  /// Stop loading
  Future<void> stop() async {
    await _channel.invokeMethod('stop', {'id': browserId});
  }

  /// Returns bounded transfer counters for texture-backed renderers.
  Future<CefOsrPerformanceStats> getOsrPerformanceStats() async {
    final value = await _channel.invokeMethod<Object?>(
      'getOsrPerformanceStats',
      <String, Object?>{'id': browserId},
    );
    if (value is Map) {
      return CefOsrPerformanceStats.fromMap(Map<String, Object?>.from(value));
    }
    return CefOsrPerformanceStats.fromMap(const <String, Object?>{});
  }

  /// Changes the OSR frame transfer strategy without recreating the browser.
  ///
  /// Native code fails closed to [CefOsrFrameTransferMode.copied] when the
  /// custom CEF lease API is unavailable. Direct mode may initially publish
  /// leased asynchronous blits until the custom Flutter engine's
  /// GPU-completion handshake has been observed.
  Future<CefOsrFrameTransferMode> setOsrFrameTransferMode(
    CefOsrFrameTransferMode mode,
  ) async {
    final value = await _channel.invokeMethod<String>(
      'setOsrFrameTransferMode',
      <String, Object?>{
        'id': browserId,
        'mode': mode.channelName,
      },
    );
    return CefOsrFrameTransferMode.fromChannelName(value);
  }

  /// Go back in history
  Future<void> goBack() async {
    await _channel.invokeMethod('goBack', {'id': browserId});
  }

  /// Go forward in history
  Future<void> goForward() async {
    await _channel.invokeMethod('goForward', {'id': browserId});
  }

  /// Find text in the current page using Chromium's native find session.
  Future<void> findInPage({
    required String query,
    bool forward = true,
    bool findNext = false,
    bool matchCase = false,
  }) async {
    await _channel.invokeMethod('findInPage', {
      'id': browserId,
      'query': query,
      'forward': forward,
      'findNext': findNext,
      'matchCase': matchCase,
    });
  }

  /// Stop the current native find session and reset its result counters.
  Future<void> stopFinding({bool clearSelection = true}) async {
    await _channel.invokeMethod('stopFinding', {
      'id': browserId,
      'clearSelection': clearSelection,
    });
    updateState(state.copyWith(findMatchCount: 0, findActiveMatchOrdinal: 0));
  }

  // JavaScript execution

  /// Execute JavaScript for side effects only.
  Future<void> executeJavaScript(String code) async {
    await _channel.invokeMethod<void>('executeJavaScript', {
      'id': browserId,
      'code': code,
    });
  }

  /// Evaluate a JavaScript expression and return a string result or `null`.
  ///
  /// Non-string result types are surfaced as native errors so callers have an
  /// explicit contract instead of relying on lossy coercion.
  Future<String?> evaluateJavaScript(String expression) async {
    return await _channel.invokeMethod<String>('evaluateJavaScript', {
      'id': browserId,
      'expression': expression,
    });
  }

  /// Captures the current visible viewport through Chromium's in-process
  /// DevTools API. The result is bounded base64 image data; no temporary file
  /// or remote-debugging endpoint is involved.
  Future<String> captureViewportScreenshot({
    String format = 'png',
    int quality = 85,
  }) async {
    final result = await _channel.invokeMethod<String>(
      'captureViewportScreenshot',
      <String, Object?>{'id': browserId, 'format': format, 'quality': quality},
    );
    if (result == null || result.isEmpty) {
      throw StateError('CEF screenshot returned no data');
    }
    return result;
  }

  /// Fixed input-only in-process Chromium dispatch. No remote CDP endpoint.
  Future<void> dispatchInput(String method, Map<String, dynamic> params) async {
    if (!const {'Input.dispatchMouseEvent', 'Input.dispatchKeyEvent', 'Input.insertText'}.contains(method)) {
      throw ArgumentError.value(method, 'method', 'Unsupported Chromium input');
    }
    await _channel.invokeMethod<void>('dispatchInput', {
      'id': browserId, 'method': method, 'params': params,
    });
  }

  Future<void> insertText(String text) => dispatchInput('Input.insertText', {'text': text});

  // Editing

  /// Perform a browser edit command in the focused frame.
  ///
  /// Supported commands are: `undo`, `redo`, `cut`, `copy`, `paste`,
  /// `selectAll`, and `delete`.
  Future<bool> performEditCommand(String command) async {
    return await _channel.invokeMethod<bool>('performEditCommand', {
          'id': browserId,
          'command': command,
        }) ??
        false;
  }

  Future<bool> undo() => performEditCommand('undo');
  Future<bool> redo() => performEditCommand('redo');
  Future<bool> cut() => performEditCommand('cut');
  Future<bool> copy() => performEditCommand('copy');
  Future<bool> paste() => performEditCommand('paste');
  Future<bool> selectAll() => performEditCommand('selectAll');
  Future<bool> delete() => performEditCommand('delete');

  // Focus management

  /// Set focus state
  Future<void> setFocus(bool focused) async {
    await _channel.invokeMethod('setFocus', {
      'id': browserId,
      'focused': focused,
    });
  }

  /// Toggle the native browser container visibility without changing geometry.
  Future<void> setVisible(bool visible) async {
    await _channel.invokeMethod('setVisible', {
      'id': browserId,
      'visible': visible,
    });
  }

  /// Pace a windowless (texture) browser to the hosting display.
  ///
  /// [targetFps] should follow the display's refresh rate; [visible] false
  /// parks frame production entirely (`WasHidden`). Safe no-op for
  /// native-view browsers and unknown ids.
  Future<void> setFramePacing({
    required int targetFps,
    required bool visible,
    bool backgroundActivityExempt = false,
  }) async {
    await _channel.invokeMethod('setFramePacing', {
      'id': browserId,
      'targetFps': targetFps,
      'visible': visible,
      'backgroundActivityExempt': backgroundActivityExempt,
    });
  }

  // Off-screen rendering input

  /// Send a mouse move event to an off-screen-rendered browser.
  Future<void> sendMouseMove({
    required double x,
    required double y,
    int modifiers = 0,
    bool mouseLeave = false,
  }) async {
    await _channel.invokeMethod('sendMouseMove', {
      'id': browserId,
      'x': x,
      'y': y,
      'modifiers': modifiers,
      'mouseLeave': mouseLeave,
    });
  }

  /// Send a mouse click event to an off-screen-rendered browser.
  Future<void> sendMouseClick({
    required double x,
    required double y,
    String button = 'left',
    required bool mouseUp,
    int clickCount = 1,
    int modifiers = 0,
  }) async {
    await _channel.invokeMethod('sendMouseClick', {
      'id': browserId,
      'x': x,
      'y': y,
      'button': button,
      'mouseUp': mouseUp,
      'clickCount': clickCount,
      'modifiers': modifiers,
    });
  }

  /// Send a mouse wheel/trackpad scroll event to an off-screen-rendered browser.
  Future<void> sendMouseWheel({
    required double x,
    required double y,
    required double deltaX,
    required double deltaY,
    int modifiers = 0,
  }) async {
    await _channel.invokeMethod('sendMouseWheel', {
      'id': browserId,
      'x': x,
      'y': y,
      'deltaX': deltaX,
      'deltaY': deltaY,
      'modifiers': modifiers,
    });
  }

  /// Send a keyboard event to an off-screen-rendered browser.
  Future<void> sendKeyEvent({
    required String type,
    required int windowsKeyCode,
    required int nativeKeyCode,
    int character = 0,
    int unmodifiedCharacter = 0,
    int modifiers = 0,
    bool isSystemKey = false,
  }) async {
    await _channel.invokeMethod('sendKeyEvent', {
      'id': browserId,
      'type': type,
      'windowsKeyCode': windowsKeyCode,
      'nativeKeyCode': nativeKeyCode,
      'character': character,
      'unmodifiedCharacter': unmodifiedCharacter,
      'modifiers': modifiers,
      'isSystemKey': isSystemKey,
    });
  }

  // View management

  /// Update view frame (position and size)
  Future<void> setViewFrame({
    required double x,
    required double y,
    required double width,
    required double height,
    double? viewWidth,
    double? viewHeight,
    double? deviceScaleFactor,
  }) async {
    await _channel.invokeMethod('setViewFrame', <String, Object?>{
      'id': browserId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      if (viewWidth != null) 'viewWidth': viewWidth,
      if (viewHeight != null) 'viewHeight': viewHeight,
      if (deviceScaleFactor != null) 'deviceScaleFactor': deviceScaleFactor,
    });
  }

  // DevTools

  /// Show DevTools panel
  Future<void> showDevTools({
    bool docked = true,
    String position = 'bottom',
  }) async {
    await _channel.invokeMethod('showDevTools', {
      'id': browserId,
      'docked': docked,
      'position': position,
    });
  }

  /// Hide DevTools panel
  Future<void> hideDevTools() async {
    await _channel.invokeMethod('hideDevTools', {'id': browserId});
  }

  // Logging

  /// Enable network logging (CDP Network domain)
  Future<void> enableNetworkLogging() async {
    await _channel.invokeMethod('enableNetworkLogging', {'id': browserId});
  }

  /// Enable console logging (CDP Runtime/Log domains)
  Future<void> enableConsoleLogging() async {
    await _channel.invokeMethod('enableConsoleLogging', {'id': browserId});
  }

  /// Get response body for a request
  Future<Map<String, dynamic>?> getResponseBody(String requestId) async {
    final result = await _channel.invokeMethod<Map>('getResponseBody', {
      'id': browserId,
      'requestId': requestId,
    });
    if (result == null) return null;
    return Map<String, dynamic>.from(result);
  }

  // Print

  /// Show print dialog
  Future<void> print() async {
    await _channel.invokeMethod('print', {'id': browserId});
  }

  /// Export page to PDF
  Future<bool> printToPdf(String path) async {
    return await _channel.invokeMethod<bool>('printToPdf', {
          'id': browserId,
          'path': path,
        }) ??
        false;
  }

  /// Close the browser
  Future<void> close({bool force = false}) async {
    if (_disposed) return;
    await _channel.invokeMethod('closeBrowser', {
      'id': browserId,
      'force': force,
    });
    dispose();
  }

  /// Override the page color scheme. Pass "light", "dark", "no-preference",
  /// or null to clear the override (use system default).
  Future<void> setColorScheme(String? scheme) async {
    await _channel.invokeMethod('setColorScheme', {
      'id': browserId,
      'scheme': scheme,
    });
  }

  // Browser-parity long tail (spec 016 Phases 7-8)

  /// Set the page zoom level. CEF zoom-level semantics: 0.0 is 100% and each
  /// whole level is one Chromium zoom step (factor 1.2). Safe no-op for
  /// unknown ids.
  Future<void> setZoomLevel(double level) async {
    await _channel.invokeMethod('setZoomLevel', {
      'id': browserId,
      'level': level,
    });
  }

  /// Magnify the visual viewport (trackpad-pinch zoom, like Safari/Chrome)
  /// around the view-space focal point ([x], [y]). [scale] is the cumulative
  /// gesture factor where 1.0 means no zoom.
  Future<void> pinchZoom({
    required double scale,
    required double x,
    required double y,
  }) async {
    await _channel.invokeMethod('pinchZoom', {
      'id': browserId,
      'scale': scale,
      'x': x,
      'y': y,
    });
  }

  /// Replace the active IME composition (marked text) in the focused
  /// editable. [selectionStart]/[selectionEnd] are relative to [text].
  Future<void> imeSetComposition({
    required String text,
    required int selectionStart,
    required int selectionEnd,
  }) async {
    await _channel.invokeMethod('imeSetComposition', {
      'id': browserId,
      'text': text,
      'selStart': selectionStart,
      'selEnd': selectionEnd,
    });
  }

  /// Commit [text] to the focused editable, ending any active composition.
  Future<void> imeCommitText(String text) async {
    await _channel.invokeMethod('imeCommitText', {
      'id': browserId,
      'text': text,
    });
  }

  /// Complete the current composition with its current text.
  Future<void> imeFinishComposing({bool keepSelection = false}) async {
    await _channel.invokeMethod('imeFinishComposing', {
      'id': browserId,
      'keepSelection': keepSelection,
    });
  }

  /// Cancel the current composition, removing any marked text.
  Future<void> imeCancelComposition() async {
    await _channel.invokeMethod('imeCancelComposition', {'id': browserId});
  }

  /// Resolve a JavaScript dialog surfaced through a `jsDialog` parity event.
  /// A stale [callbackId] is a safe native no-op (tab teardown races).
  Future<void> resolveJsDialog({
    required int callbackId,
    required bool success,
    String? userInput,
  }) async {
    await _channel.invokeMethod('resolveJsDialog', <String, Object?>{
      'id': browserId,
      'callbackId': callbackId,
      'success': success,
      if (userInput != null) 'userInput': userInput,
    });
  }

  /// Resolves a retained native CEF permission callback. Native validates
  /// both this browser id and [promptId]; stale or foreign ids are safe no-ops.
  Future<void> resolvePermissionPrompt({
    required String promptId,
    required bool allow,
  }) async {
    await _channel.invokeMethod('resolvePermissionPrompt', <String, Object?>{
      'id': browserId,
      'promptId': promptId,
      'allow': allow,
    });
  }

  /// Select a command from a Chromium context menu surfaced to Flutter.
  /// A stale [menuId] is a safe native no-op (dismiss/teardown races).
  Future<void> resolveContextMenu({
    required int menuId,
    required int commandId,
  }) async {
    await _channel.invokeMethod('resolveContextMenu', <String, Object?>{
      'id': browserId,
      'menuId': menuId,
      'commandId': commandId,
    });
  }

  /// Dismiss a Chromium context menu without executing a command.
  Future<void> cancelContextMenu({required int menuId}) async {
    await _channel.invokeMethod('cancelContextMenu', <String, Object?>{
      'id': browserId,
      'menuId': menuId,
    });
  }

  /// Dispose of controller resources
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stateController.close();
    _consoleController.close();
    _networkController.close();
    _parityController.close();
  }
}
