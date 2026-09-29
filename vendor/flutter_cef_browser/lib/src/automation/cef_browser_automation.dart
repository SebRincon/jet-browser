import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../cef_browser_controller.dart';
import '../models/browser_state.dart';

typedef CefAutomationBeforeInput = FutureOr<void> Function(double x, double y);
typedef CefAutomationBeforeDispatch = FutureOr<CefAutomationDispatchPermit>
    Function();

enum CefAutomationDispatchState { started, completed }

final class CefAutomationDispatchPermit {
  CefAutomationDispatchPermit({
    required this.generation,
    required bool Function() isCurrent,
    void Function(CefAutomationDispatchState state)? onStateChanged,
  })  : _isCurrent = isCurrent,
        _onStateChanged = onStateChanged;

  factory CefAutomationDispatchPermit.unmanaged() =>
      CefAutomationDispatchPermit(generation: 0, isCurrent: () => true);

  final int generation;
  final bool Function() _isCurrent;
  final void Function(CefAutomationDispatchState state)? _onStateChanged;
  bool _started = false;

  bool get hasStarted => _started;

  void start() {
    if (!_isCurrent()) {
      throw const CefBrowserAutomationException('BROWSER_LEASE_PAUSED');
    }
    _started = true;
    _onStateChanged?.call(CefAutomationDispatchState.started);
  }

  void ensureCurrent() {
    if (!_isCurrent()) throw const _CefAutomationDispatchInterrupted();
  }

  void complete() {
    ensureCurrent();
    _onStateChanged?.call(CefAutomationDispatchState.completed);
  }
}

final class _CefAutomationDispatchInterrupted implements Exception {
  const _CefAutomationDispatchInterrupted();
}

final class CefBrowserAutomationException implements Exception {
  const CefBrowserAutomationException(this.code);

  final String code;

  @override
  String toString() => code;
}

final class CefAutomationBounds {
  const CefAutomationBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  double get centerX => x + width / 2;
  double get centerY => y + height / 2;

  Map<String, Object?> toJson() => <String, Object?>{
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
}

final class CefSemanticNode {
  const CefSemanticNode({
    required this.ref,
    required this.role,
    required this.states,
    required this.actions,
    this.parentRef,
    this.name,
    this.value,
    this.description,
    this.bounds,
  });

  final String ref;
  final String? parentRef;
  final String role;
  final String? name;
  final String? value;
  final String? description;
  final Map<String, Object?> states;
  final List<String> actions;
  final CefAutomationBounds? bounds;

  Map<String, Object?> toJson() => <String, Object?>{
        'ref': ref,
        'parentRef': parentRef,
        'role': role,
        'name': name,
        'value': value,
        'description': description,
        'states': states,
        'actions': actions,
        'bounds': bounds?.toJson(),
      };
}

final class CefSemanticSnapshot {
  const CefSemanticSnapshot({
    required this.snapshotId,
    required this.documentGeneration,
    required this.lifecycleGeneration,
    required this.viewportGeneration,
    required this.truncated,
    required this.nodes,
    this.rootRef,
  });

  final String snapshotId;
  final int documentGeneration;
  final int lifecycleGeneration;
  final int viewportGeneration;
  final bool truncated;
  final String? rootRef;
  final List<CefSemanticNode> nodes;

  Map<String, Object?> toJson() => <String, Object?>{
        'snapshotId': snapshotId,
        'documentGeneration': documentGeneration,
        'lifecycleGeneration': lifecycleGeneration,
        'viewportGeneration': viewportGeneration,
        'untrustedContent': true,
        'truncated': truncated,
        'rootRef': rootRef,
        'nodes': nodes.map((node) => node.toJson()).toList(growable: false),
      };
}

final class CefBrowserAutomationBroker {
  CefBrowserAutomationBroker({
    required this.controller,
    required int lifecycleGeneration,
    required double viewportWidth,
    required double viewportHeight,
    required double deviceScaleFactor,
    this.beforeInput,
    this.beforeDispatch,
  })  : _lifecycleGeneration = lifecycleGeneration,
        _viewportWidth = viewportWidth,
        _viewportHeight = viewportHeight,
        _deviceScaleFactor = deviceScaleFactor,
        _lastState = controller.state {
    _stateSubscription = controller.stateStream.listen(_onBrowserState);
  }

  static const int maxSnapshotNodes = 2000;
  static const int maxSnapshotDepth = 64;
  static const int maxNodeTextBytes = 256;
  static const int maxSnapshotUtf8Bytes = 2 * 1024 * 1024;
  static const int maxScreenshotDimension = 4096;
  static const int maxScreenshotBytes = 8 * 1024 * 1024;
  static const int maxScreenshotBase64Bytes = (maxScreenshotBytes * 4 ~/ 3) + 8;

  final CefBrowserController controller;
  final CefAutomationBeforeInput? beforeInput;
  final CefAutomationBeforeDispatch? beforeDispatch;
  late final StreamSubscription<BrowserState> _stateSubscription;
  BrowserState _lastState;
  int _documentGeneration = 1;
  int _lifecycleGeneration;
  int _viewportGeneration = 1;
  int _externalInputGeneration = 0;
  double _viewportWidth;
  double _viewportHeight;
  double _deviceScaleFactor;
  int _actionSequence = 0;
  bool _disposed = false;
  Completer<void> _nextStateChange = Completer<void>();
  final Map<String, _SnapshotRecord> _snapshots = <String, _SnapshotRecord>{};

  int get documentGeneration => _documentGeneration;
  int get lifecycleGeneration => _lifecycleGeneration;
  int get viewportGeneration => _viewportGeneration;

  /// Invalidates observations captured before physical user input reaches the
  /// page without changing the browser lease or navigation generations.
  void invalidateObservationsForExternalInput() {
    _externalInputGeneration += 1;
    _invalidateObservations();
  }

  void updateLifecycleGeneration(int generation) {
    if (generation == _lifecycleGeneration) return;
    _lifecycleGeneration = generation;
    _documentGeneration += 1;
    _invalidateObservations();
    _signalStateChange();
  }

  void updateViewport({
    required double width,
    required double height,
    required double deviceScaleFactor,
  }) {
    if (width == _viewportWidth &&
        height == _viewportHeight &&
        deviceScaleFactor == _deviceScaleFactor) {
      return;
    }
    _viewportWidth = width;
    _viewportHeight = height;
    _deviceScaleFactor = deviceScaleFactor;
    _viewportGeneration += 1;
  }

  Future<CefSemanticSnapshot> snapshot({
    int maxNodes = 1000,
    int maxDepth = 32,
    bool includeBounds = true,
  }) async {
    _ensureLive();
    final externalInputGeneration = _externalInputGeneration;
    if (maxNodes < 1 || maxNodes > maxSnapshotNodes) {
      throw const CefBrowserAutomationException('BROWSER_CONTENT_LIMIT');
    }
    if (maxDepth < 1 || maxDepth > maxSnapshotDepth) {
      throw const CefBrowserAutomationException('BROWSER_CONTENT_LIMIT');
    }
    final raw = await controller.evaluateJavaScript(
      _snapshotExpression(maxNodes: maxNodes, maxDepth: maxDepth),
    );
    _ensureLive();
    if (externalInputGeneration != _externalInputGeneration) {
      throw const CefBrowserAutomationException('BROWSER_STALE_SNAPSHOT');
    }
    if (raw == null || utf8.encode(raw).length > maxSnapshotUtf8Bytes) {
      throw const CefBrowserAutomationException('BROWSER_CONTENT_LIMIT');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const CefBrowserAutomationException('BROWSER_RESOURCE_UNAVAILABLE');
    }
    final payload = Map<String, dynamic>.from(decoded);
    final nodeValues = payload['nodes'];
    if (nodeValues is! List || nodeValues.length > maxNodes) {
      throw const CefBrowserAutomationException('BROWSER_CONTENT_LIMIT');
    }
    final snapshotId = _opaque('snap');
    final targets = <String, _NodeTarget>{};
    final nodes = <CefSemanticNode>[];
    for (final value in nodeValues.whereType<Map>()) {
      final node = Map<String, dynamic>.from(value);
      final ref = node['ref']?.toString() ?? '';
      final path = node['path']?.toString() ?? '';
      final bounds = _boundsFrom(node['bounds']);
      if (ref.isEmpty || path.isEmpty || bounds == null) continue;
      final rawStates = node['states'];
      final states = rawStates is Map
          ? Map<String, Object?>.from(rawStates)
          : const <String, Object?>{};
      final actions = node['actions'] is List
          ? (node['actions'] as List)
              .map((item) => item.toString())
              .where(_supportedSemanticActions.contains)
              .toList(growable: false)
          : const <String>[];
      final consequential = node['consequential'] == true;
      targets[ref] = _NodeTarget(
        path: path,
        signature: node['signature']?.toString() ?? '',
        role: node['role']?.toString() ?? 'generic',
        actions: Set<String>.unmodifiable(actions),
        bounds: bounds,
        secret: node['secret'] == true,
        editable: node['editable'] == true,
        typedValue: _optionalString(node['value']) ?? '',
        checked: states['checked'] == true,
        focused: states['focused'] == true,
        nativeSelect: node['nativeSelect'] == true,
        clickConsequential: consequential || node['clickConsequential'] == true,
        pressConsequential: consequential || node['pressConsequential'] == true,
      );
      nodes.add(
        CefSemanticNode(
          ref: ref,
          parentRef: _optionalString(node['parentRef']),
          role: node['role']?.toString() ?? 'generic',
          name: _optionalString(node['name']),
          value: _optionalString(node['value']),
          description: _optionalString(node['description']),
          states: states,
          actions: actions,
          bounds: includeBounds ? bounds : null,
        ),
      );
    }
    final result = CefSemanticSnapshot(
      snapshotId: snapshotId,
      documentGeneration: _documentGeneration,
      lifecycleGeneration: _lifecycleGeneration,
      viewportGeneration: _viewportGeneration,
      truncated: payload['truncated'] == true,
      rootRef: nodes.isEmpty ? null : nodes.first.ref,
      nodes: nodes,
    );
    _snapshots
      ..clear()
      ..[snapshotId] = _SnapshotRecord(
        documentGeneration: _documentGeneration,
        lifecycleGeneration: _lifecycleGeneration,
        targets: targets,
      );
    return result;
  }

  Future<Map<String, Object?>> point({
    required String snapshotId,
    required String ref,
  }) async {
    final target = await _semanticTarget(snapshotId, ref);
    await beforeInput?.call(target.bounds.centerX, target.bounds.centerY);
    return _completedActionResult();
  }

  Future<Map<String, Object?>> click({
    required String snapshotId,
    required String ref,
  }) async {
    var target = await _semanticTarget(snapshotId, ref);
    _requireAction(target, 'click');
    _rejectClick(target);
    target = await _prepareTargetForInput(target);
    _requireAction(target, 'click');
    _rejectClick(target);
    final x = target.bounds.centerX;
    final y = target.bounds.centerY;
    return _dispatchInput(
      x: x,
      y: y,
      dispatch: (ensureCurrent) async {
        ensureCurrent();
        await controller.setFocus(true);
        if (target.role == 'checkbox' || target.role == 'radio') {
          ensureCurrent();
          final raw = await controller.evaluateJavaScript(
            _activateToggleExpression(target.path, target.role),
          );
          ensureCurrent();
          if (raw == null) {
            throw const CefBrowserAutomationException(
              'BROWSER_ACTION_OUTCOME_UNKNOWN',
            );
          }
          final decoded = jsonDecode(raw);
          if (decoded is! Map || decoded['activated'] != true) {
            throw const CefBrowserAutomationException(
              'BROWSER_ACTION_OUTCOME_UNKNOWN',
            );
          }
        } else {
          ensureCurrent();
          await controller.sendMouseMove(x: x, y: y);
          ensureCurrent();
          await controller.sendMouseClick(x: x, y: y, mouseUp: false);
          ensureCurrent();
          await controller.sendMouseClick(x: x, y: y, mouseUp: true);
        }
        await _verifyClickOutcome(
          target: target,
          ensureCurrent: ensureCurrent,
        );
      },
    );
  }

  Future<Map<String, Object?>> type({
    required String snapshotId,
    required String ref,
    required String text,
    bool replace = false,
  }) async {
    if (text.isEmpty || utf8.encode(text).length > 64 * 1024) {
      throw const CefBrowserAutomationException('BROWSER_CONTENT_LIMIT');
    }
    var target = await _semanticTarget(snapshotId, ref);
    if (target.secret) {
      throw const CefBrowserAutomationException(
        'BROWSER_ACTION_CONFIRMATION_REQUIRED',
      );
    }
    _requireAction(target, 'type');
    if (!target.editable) {
      throw const CefBrowserAutomationException(
        'BROWSER_ACTION_UNSUPPORTED',
      );
    }
    target = await _prepareTargetForInput(target);
    if (target.secret) {
      throw const CefBrowserAutomationException(
        'BROWSER_ACTION_CONFIRMATION_REQUIRED',
      );
    }
    _requireAction(target, 'type');
    if (!target.editable) {
      throw const CefBrowserAutomationException(
        'BROWSER_ACTION_UNSUPPORTED',
      );
    }
    final x = target.bounds.centerX;
    final y = target.bounds.centerY;
    return _dispatchInput(
      x: x,
      y: y,
      dispatch: (ensureCurrent) async {
        ensureCurrent();
        await controller.setFocus(true);
        ensureCurrent();
        final focusRaw = await controller.evaluateJavaScript(
          _focusEditableExpression(target.path, replace: replace),
        );
        ensureCurrent();
        if (focusRaw == null) {
          throw const CefBrowserAutomationException(
            'BROWSER_ACTION_OUTCOME_UNKNOWN',
          );
        }
        final focusResult = jsonDecode(focusRaw);
        if (focusResult is! Map || focusResult['focused'] != true) {
          throw const CefBrowserAutomationException(
            'BROWSER_ACTION_OUTCOME_UNKNOWN',
          );
        }
        await _settleNativeInput(ensureCurrent);
        if (replace) {
          ensureCurrent();
          if (!await controller.selectAll()) {
            throw const CefBrowserAutomationException(
              'BROWSER_ACTION_OUTCOME_UNKNOWN',
            );
          }
        }
        ensureCurrent();
        await controller.imeCommitText(text);
        await _verifyTypedValue(
          target: target,
          text: text,
          replace: replace,
          ensureCurrent: ensureCurrent,
        );
      },
    );
  }

  Future<Map<String, Object?>> selectOption({
    required String snapshotId,
    required String ref,
    required String value,
  }) async {
    if (value.isEmpty || utf8.encode(value).length > maxNodeTextBytes) {
      throw const CefBrowserAutomationException('BROWSER_CONTENT_LIMIT');
    }
    var target = await _semanticTarget(snapshotId, ref);
    _requireAction(target, 'select');
    if (!target.nativeSelect) {
      throw const CefBrowserAutomationException(
        'BROWSER_ACTION_UNSUPPORTED',
      );
    }
    target = await _prepareTargetForInput(target);
    _requireAction(target, 'select');
    if (!target.nativeSelect) {
      throw const CefBrowserAutomationException(
        'BROWSER_ACTION_UNSUPPORTED',
      );
    }
    final x = target.bounds.centerX;
    final y = target.bounds.centerY;
    return _dispatchInput(
      x: x,
      y: y,
      dispatch: (ensureCurrent) async {
        ensureCurrent();
        await controller.setFocus(true);
        ensureCurrent();
        final raw = await controller.evaluateJavaScript(
          _selectOptionExpression(target.path, value),
        );
        ensureCurrent();
        if (raw == null) {
          throw const CefBrowserAutomationException(
            'BROWSER_ACTION_OUTCOME_UNKNOWN',
          );
        }
        final decoded = jsonDecode(raw);
        if (decoded is! Map || decoded['matched'] != true) {
          throw const CefBrowserAutomationException(
            'BROWSER_ACTION_OUTCOME_UNKNOWN',
          );
        }
        final selectedValue = decoded['selectedValue']?.toString() ?? '';
        if (selectedValue.isEmpty) {
          throw const CefBrowserAutomationException(
            'BROWSER_ACTION_OUTCOME_UNKNOWN',
          );
        }
        await _verifyTypedValue(
          target: target,
          text: selectedValue,
          replace: true,
          ensureCurrent: ensureCurrent,
        );
      },
    );
  }

  Future<Map<String, Object?>> press({
    required String snapshotId,
    required String ref,
    required String key,
  }) async {
    var target = await _semanticTarget(snapshotId, ref);
    _requireAction(target, 'press');
    _rejectPress(target, key);
    final codes = _keyCodes[key];
    if (codes == null) {
      throw const CefBrowserAutomationException('BROWSER_ACTION_UNSUPPORTED');
    }
    target = await _prepareTargetForInput(target);
    _requireAction(target, 'press');
    _rejectPress(target, key);
    final x = target.bounds.centerX;
    final y = target.bounds.centerY;
    return _dispatchInput(
      x: x,
      y: y,
      dispatch: (ensureCurrent) async {
        ensureCurrent();
        await controller.setFocus(true);
        ensureCurrent();
        final focusRaw = await controller.evaluateJavaScript(
          _focusPressTargetExpression(target.path),
        );
        ensureCurrent();
        if (focusRaw == null) {
          throw const CefBrowserAutomationException(
            'BROWSER_ACTION_OUTCOME_UNKNOWN',
          );
        }
        final focusResult = jsonDecode(focusRaw);
        if (focusResult is! Map || focusResult['focused'] != true) {
          throw const CefBrowserAutomationException(
            'BROWSER_ACTION_OUTCOME_UNKNOWN',
          );
        }
        await _settleNativeInput(ensureCurrent);
        ensureCurrent();
        await controller.sendKeyEvent(
          type: 'rawKeyDown',
          windowsKeyCode: codes.$1,
          nativeKeyCode: codes.$2,
        );
        if (codes.$3 != 0) {
          ensureCurrent();
          await controller.sendKeyEvent(
            type: 'char',
            windowsKeyCode: codes.$1,
            nativeKeyCode: codes.$2,
            character: codes.$3,
            unmodifiedCharacter: codes.$3,
          );
        }
        ensureCurrent();
        await controller.sendKeyEvent(
          type: 'keyUp',
          windowsKeyCode: codes.$1,
          nativeKeyCode: codes.$2,
        );
      },
    );
  }

  Future<Map<String, Object?>> scroll({
    required String snapshotId,
    required String ref,
    required double deltaX,
    required double deltaY,
  }) async {
    final target = await _semanticTarget(snapshotId, ref);
    _requireAction(target, 'scroll');
    final x = target.bounds.centerX;
    final y = target.bounds.centerY;
    final result = await _dispatchInput(
      x: x,
      y: y,
      dispatch: (ensureCurrent) async {
        ensureCurrent();
        await controller.sendMouseWheel(
          x: x,
          y: y,
          deltaX: deltaX,
          deltaY: deltaY,
        );
      },
    );
    _viewportGeneration += 1;
    return <String, Object?>{
      ...result,
      'viewportGeneration': _viewportGeneration,
    };
  }

  Future<Map<String, Object?>> navigate(String url) async {
    _ensureLive();
    return _dispatchInput(
      x: _viewportWidth / 2,
      y: 24,
      dispatch: (ensureCurrent) async {
        ensureCurrent();
        await controller.loadUrl(url);
      },
    );
  }

  Future<Map<String, Object?>> back() async {
    _ensureLive();
    return _dispatchInput(
      x: _viewportWidth / 2,
      y: 24,
      dispatch: (ensureCurrent) async {
        ensureCurrent();
        await controller.goBack();
      },
    );
  }

  Future<Map<String, Object?>> forward() async {
    _ensureLive();
    return _dispatchInput(
      x: _viewportWidth / 2,
      y: 24,
      dispatch: (ensureCurrent) async {
        ensureCurrent();
        await controller.goForward();
      },
    );
  }

  Future<Map<String, Object?>> reload() async {
    _ensureLive();
    return _dispatchInput(
      x: _viewportWidth / 2,
      y: 24,
      dispatch: (ensureCurrent) async {
        ensureCurrent();
        await controller.reload();
      },
    );
  }

  Future<Map<String, Object?>> screenshot({
    String format = 'png',
    int quality = 85,
  }) async {
    _ensureLive();
    if (!_viewportWidth.isFinite ||
        !_viewportHeight.isFinite ||
        _viewportWidth <= 0 ||
        _viewportHeight <= 0 ||
        _viewportWidth > maxScreenshotDimension ||
        _viewportHeight > maxScreenshotDimension) {
      throw const CefBrowserAutomationException('BROWSER_CONTENT_LIMIT');
    }
    final externalInputGeneration = _externalInputGeneration;
    final data = await controller.captureViewportScreenshot(
      format: format,
      quality: quality,
    );
    if (externalInputGeneration != _externalInputGeneration) {
      throw const CefBrowserAutomationException('BROWSER_STALE_SCREENSHOT');
    }
    if (data.length > maxScreenshotBase64Bytes) {
      throw const CefBrowserAutomationException('BROWSER_CONTENT_LIMIT');
    }
    final screenshotId = _opaque('shot');
    return <String, Object?>{
      'screenshotId': screenshotId,
      'format': format,
      'data': data,
      'width': _viewportWidth.round(),
      'height': _viewportHeight.round(),
      'deviceScaleFactor': _deviceScaleFactor,
      'documentGeneration': _documentGeneration,
      'lifecycleGeneration': _lifecycleGeneration,
      'viewportGeneration': _viewportGeneration,
      'untrustedContent': true,
    };
  }

  Future<Map<String, Object?>> wait({
    required Map<String, dynamic> condition,
    int? baselineDocumentGeneration,
    required Duration timeout,
    bool Function()? isCancelled,
  }) async {
    _ensureLive();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final stateChange = _nextStateChange.future;
      if (isCancelled?.call() ?? false) {
        throw const CefBrowserAutomationException('BROWSER_LEASE_REVOKED');
      }
      _ensureLive();
      if (await _conditionMatches(condition, baselineDocumentGeneration)) {
        return <String, Object?>{
          'kind': 'matched',
          'documentGeneration': _documentGeneration,
          'lifecycleGeneration': _lifecycleGeneration,
          'viewportGeneration': _viewportGeneration,
        };
      }
      final poll = Future<void>.delayed(const Duration(milliseconds: 125));
      if (condition['kind'] == 'documentChanged' ||
          condition['kind'] == 'loadState') {
        await Future.any<void>(<Future<void>>[stateChange, poll]);
      } else {
        await poll;
      }
    }
    return <String, Object?>{
      'kind': 'timeout',
      'documentGeneration': _documentGeneration,
      'lifecycleGeneration': _lifecycleGeneration,
      'viewportGeneration': _viewportGeneration,
    };
  }

  Future<bool> _conditionMatches(
    Map<String, dynamic> condition,
    int? baselineDocumentGeneration,
  ) async {
    switch (condition['kind']) {
      case 'documentChanged':
        return baselineDocumentGeneration != null &&
            _documentGeneration != baselineDocumentGeneration;
      case 'loadState':
        return condition['value'] == 'loading'
            ? controller.state.isLoading
            : !controller.state.isLoading;
      case 'textPresent':
        final text = condition['text']?.toString() ?? '';
        final result = await controller.evaluateJavaScript(
          '(function(){return JSON.stringify(document.body && document.body.innerText.includes(${jsonEncode(text)}));})()',
        );
        return result == 'true';
      case 'nodeState':
        final record = _snapshots[condition['snapshotId']?.toString()];
        final target = record?.targets[condition['ref']?.toString()];
        if (record == null || target == null) {
          throw const CefBrowserAutomationException('BROWSER_STALE_SNAPSHOT');
        }
        final result = await controller.evaluateJavaScript(
          _nodeStateExpression(
            target.path,
            condition['state']?.toString() ?? '',
          ),
        );
        if (result == null) {
          throw const CefBrowserAutomationException('BROWSER_TARGET_DETACHED');
        }
        return jsonDecode(result) == condition['value'];
      default:
        throw const CefBrowserAutomationException('BROWSER_ACTION_UNSUPPORTED');
    }
  }

  Future<_NodeTarget> _semanticTarget(String snapshotId, String ref) async {
    _ensureLive();
    final snapshot = _snapshots[snapshotId];
    if (snapshot == null ||
        snapshot.documentGeneration != _documentGeneration ||
        snapshot.lifecycleGeneration != _lifecycleGeneration) {
      throw const CefBrowserAutomationException('BROWSER_STALE_SNAPSHOT');
    }
    final target = snapshot.targets[ref];
    if (target == null) {
      throw const CefBrowserAutomationException('BROWSER_TARGET_DETACHED');
    }
    final raw = await controller.evaluateJavaScript(
      _structuralRevalidateExpression(target.path),
    );
    if (raw == null) {
      throw const CefBrowserAutomationException('BROWSER_TARGET_DETACHED');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['signature']?.toString() != target.signature) {
      throw const CefBrowserAutomationException('BROWSER_TARGET_DETACHED');
    }
    return _targetFromRevalidation(target, decoded);
  }

  Future<_NodeTarget> _prepareTargetForInput(_NodeTarget target) async {
    final externalInputGeneration = _externalInputGeneration;
    final raw = await controller.evaluateJavaScript(
      _scrollAndRevalidateExpression(target.path),
    );
    if (raw == null) {
      throw const CefBrowserAutomationException('BROWSER_TARGET_DETACHED');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['signature']?.toString() != target.signature) {
      throw const CefBrowserAutomationException('BROWSER_TARGET_DETACHED');
    }
    if (decoded['viewportChanged'] == true) {
      _viewportGeneration += 1;
      await Future<void>.delayed(_nativeInputSettleDelay);
      _ensureLive();
      if (externalInputGeneration != _externalInputGeneration) {
        throw const CefBrowserAutomationException('BROWSER_STALE_SNAPSHOT');
      }
      final settledRaw = await controller.evaluateJavaScript(
        _structuralRevalidateExpression(target.path),
      );
      if (settledRaw == null) {
        throw const CefBrowserAutomationException('BROWSER_TARGET_DETACHED');
      }
      final settled = jsonDecode(settledRaw);
      if (settled is! Map ||
          settled['signature']?.toString() != target.signature) {
        throw const CefBrowserAutomationException('BROWSER_TARGET_DETACHED');
      }
      return _targetFromRevalidation(target, settled);
    }
    return _targetFromRevalidation(target, decoded);
  }

  Future<void> _settleNativeInput(void Function() ensureCurrent) async {
    await Future<void>.delayed(_nativeInputSettleDelay);
    ensureCurrent();
  }

  _NodeTarget _targetFromRevalidation(
    _NodeTarget target,
    Map<dynamic, dynamic> decoded,
  ) {
    final currentBounds = _boundsFrom(decoded['bounds']);
    if (currentBounds == null ||
        currentBounds.width <= 0 ||
        currentBounds.height <= 0) {
      throw const CefBrowserAutomationException('BROWSER_TARGET_DETACHED');
    }
    return target.copyWith(
      bounds: currentBounds,
      role: decoded['role']?.toString(),
      actions: _semanticActionsFrom(decoded['actions']),
      secret: decoded['secret'] == true || target.secret,
      editable: decoded['editable'] == true,
      typedValue: decoded['typedValue']?.toString() ?? '',
      checked: decoded['checked'] == true,
      focused: decoded['focused'] == true,
      nativeSelect: decoded['nativeSelect'] == true,
      clickConsequential:
          decoded['clickConsequential'] == true || target.clickConsequential,
      pressConsequential:
          decoded['pressConsequential'] == true || target.pressConsequential,
    );
  }

  Future<void> _verifyClickOutcome({
    required _NodeTarget target,
    required void Function() ensureCurrent,
  }) async {
    final expected = switch (target.role) {
      'checkbox' => !target.checked,
      'radio' => true,
      _ => null,
    };
    if (expected == null) return;
    for (var attempt = 0; attempt < 8; attempt += 1) {
      ensureCurrent();
      final raw = await controller.evaluateJavaScript(
        _nodeStateExpression(target.path, 'checked'),
      );
      ensureCurrent();
      if (raw != null && jsonDecode(raw) == expected) return;
      if (attempt < 7) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    throw const CefBrowserAutomationException(
      'BROWSER_ACTION_OUTCOME_UNKNOWN',
    );
  }

  Future<void> _verifyTypedValue({
    required _NodeTarget target,
    required String text,
    required bool replace,
    required void Function() ensureCurrent,
  }) async {
    for (var attempt = 0; attempt < 8; attempt += 1) {
      ensureCurrent();
      final raw = await controller.evaluateJavaScript(
        _typedValueExpression(target.path),
      );
      ensureCurrent();
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final typedValue = decoded['typedValue']?.toString() ?? '';
          final verified = replace
              ? typedValue == text
              : typedValue != target.typedValue && typedValue.contains(text);
          if (verified) return;
        }
      }
      if (attempt < 7) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    throw const CefBrowserAutomationException(
      'BROWSER_ACTION_OUTCOME_UNKNOWN',
    );
  }

  void _rejectClick(_NodeTarget target) {
    if (target.secret || target.clickConsequential) {
      throw const CefBrowserAutomationException(
        'BROWSER_ACTION_CONFIRMATION_REQUIRED',
      );
    }
  }

  void _requireAction(_NodeTarget target, String action) {
    if (!target.actions.contains(action)) {
      throw const CefBrowserAutomationException('BROWSER_ACTION_UNSUPPORTED');
    }
  }

  void _rejectPress(_NodeTarget target, String key) {
    final activatesTarget = key == 'Enter' || key == 'Space';
    if (target.secret ||
        (!target.editable &&
            !target.nativeSelect &&
            (target.clickConsequential || target.pressConsequential)) ||
        (activatesTarget &&
            (target.clickConsequential || target.pressConsequential))) {
      throw const CefBrowserAutomationException(
        'BROWSER_ACTION_CONFIRMATION_REQUIRED',
      );
    }
    if (target.nativeSelect && _nativeSelectMutationKeys.contains(key)) {
      throw const CefBrowserAutomationException(
        'BROWSER_ACTION_UNSUPPORTED',
      );
    }
  }

  Future<Map<String, Object?>> _dispatchInput({
    required double x,
    required double y,
    required Future<void> Function(void Function() ensureCurrent) dispatch,
  }) async {
    await beforeInput?.call(x, y);
    final permit =
        await beforeDispatch?.call() ?? CefAutomationDispatchPermit.unmanaged();
    final actionId = _opaque('act');
    final sequence = ++_actionSequence;
    try {
      // This stays synchronous so a lease cannot change between validation and
      // marking the action as having reached native dispatch.
      permit.start();
      await dispatch(permit.ensureCurrent);
      permit.complete();
      return _actionResult(
        actionId: actionId,
        sequence: sequence,
        status: 'completed',
        dispatchState: 'completed',
        resultCode: 'OK',
        retryable: false,
      );
    } catch (_) {
      if (!permit.hasStarted) rethrow;
      return _actionResult(
        actionId: actionId,
        sequence: sequence,
        status: 'outcomeUnknown',
        dispatchState: 'started',
        resultCode: 'BROWSER_ACTION_OUTCOME_UNKNOWN',
        retryable: false,
      );
    }
  }

  Map<String, Object?> _completedActionResult() => _actionResult(
        actionId: _opaque('act'),
        sequence: ++_actionSequence,
        status: 'completed',
        dispatchState: 'completed',
        resultCode: 'OK',
        retryable: false,
      );

  Map<String, Object?> _actionResult({
    required String actionId,
    required int sequence,
    required String status,
    required String dispatchState,
    required String resultCode,
    required bool retryable,
  }) =>
      <String, Object?>{
        'actionId': actionId,
        'sequence': sequence,
        'status': status,
        'dispatchState': dispatchState,
        'resultCode': resultCode,
        'retryable': retryable,
        'documentGeneration': _documentGeneration,
        'lifecycleGeneration': _lifecycleGeneration,
        'viewportGeneration': _viewportGeneration,
      };

  void _onBrowserState(BrowserState state) {
    final urlChanged = state.url.isNotEmpty && state.url != _lastState.url;
    final reloadStarted = state.isLoading && !_lastState.isLoading;
    _lastState = state;
    _signalStateChange();
    if (!urlChanged && !reloadStarted) return;
    _documentGeneration += 1;
    _viewportGeneration += 1;
    _invalidateObservations();
  }

  void _invalidateObservations() {
    _snapshots.clear();
  }

  void _signalStateChange() {
    final current = _nextStateChange;
    _nextStateChange = Completer<void>();
    if (!current.isCompleted) current.complete();
  }

  void _ensureLive() {
    if (_disposed || controller.isDisposed) {
      throw const CefBrowserAutomationException('BROWSER_TARGET_DETACHED');
    }
  }

  String _opaque(String prefix) {
    final bytes = List<int>.generate(18, (_) => _secureRandom.nextInt(256));
    return '${prefix}_${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _invalidateObservations();
    _signalStateChange();
    await _stateSubscription.cancel();
  }
}

final class _SnapshotRecord {
  const _SnapshotRecord({
    required this.documentGeneration,
    required this.lifecycleGeneration,
    required this.targets,
  });

  final int documentGeneration;
  final int lifecycleGeneration;
  final Map<String, _NodeTarget> targets;
}

final class _NodeTarget {
  const _NodeTarget({
    required this.path,
    required this.signature,
    required this.role,
    required this.actions,
    required this.bounds,
    required this.secret,
    required this.editable,
    required this.typedValue,
    required this.checked,
    required this.focused,
    required this.nativeSelect,
    required this.clickConsequential,
    required this.pressConsequential,
  });

  final String path;
  final String signature;
  final String role;
  final Set<String> actions;
  final CefAutomationBounds bounds;
  final bool secret;
  final bool editable;
  final String typedValue;
  final bool checked;
  final bool focused;
  final bool nativeSelect;
  final bool clickConsequential;
  final bool pressConsequential;

  _NodeTarget copyWith({
    required CefAutomationBounds bounds,
    String? role,
    Set<String>? actions,
    bool? secret,
    bool? editable,
    String? typedValue,
    bool? checked,
    bool? focused,
    bool? nativeSelect,
    bool? clickConsequential,
    bool? pressConsequential,
  }) =>
      _NodeTarget(
        path: path,
        signature: signature,
        role: role ?? this.role,
        actions: actions ?? this.actions,
        bounds: bounds,
        secret: secret ?? this.secret,
        editable: editable ?? this.editable,
        typedValue: typedValue ?? this.typedValue,
        checked: checked ?? this.checked,
        focused: focused ?? this.focused,
        nativeSelect: nativeSelect ?? this.nativeSelect,
        clickConsequential: clickConsequential ?? this.clickConsequential,
        pressConsequential: pressConsequential ?? this.pressConsequential,
      );
}

CefAutomationBounds? _boundsFrom(Object? raw) {
  if (raw is! Map) return null;
  final value = Map<String, dynamic>.from(raw);
  return CefAutomationBounds(
    x: (value['x'] as num?)?.toDouble() ?? 0,
    y: (value['y'] as num?)?.toDouble() ?? 0,
    width: (value['width'] as num?)?.toDouble() ?? 0,
    height: (value['height'] as num?)?.toDouble() ?? 0,
  );
}

String? _optionalString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

Set<String> _semanticActionsFrom(Object? raw) {
  if (raw is! List) return const <String>{};
  return Set<String>.unmodifiable(
    raw
        .map((item) => item.toString())
        .where(_supportedSemanticActions.contains),
  );
}

const Set<String> _supportedSemanticActions = <String>{
  'click',
  'type',
  'select',
  'press',
  'scroll',
};

const Map<String, (int, int, int)> _keyCodes = <String, (int, int, int)>{
  'Enter': (0x0D, 0x24, 0x0D),
  'Tab': (0x09, 0x30, 0x09),
  'Escape': (0x1B, 0x35, 0),
  'ArrowLeft': (0x25, 0x7B, 0),
  'ArrowUp': (0x26, 0x7E, 0),
  'ArrowRight': (0x27, 0x7C, 0),
  'ArrowDown': (0x28, 0x7D, 0),
  'Backspace': (0x08, 0x33, 0),
  'Delete': (0x2E, 0x75, 0),
  'Home': (0x24, 0x73, 0),
  'End': (0x23, 0x77, 0),
  'PageUp': (0x21, 0x74, 0),
  'PageDown': (0x22, 0x79, 0),
  'Space': (0x20, 0x31, 0x20),
};

const Set<String> _nativeSelectMutationKeys = <String>{
  'ArrowUp',
  'ArrowDown',
  'Home',
  'End',
  'PageUp',
  'PageDown',
};

const Duration _nativeInputSettleDelay = Duration(milliseconds: 50);

final Random _secureRandom = Random.secure();

String _snapshotExpression({required int maxNodes, required int maxDepth}) =>
    '''(function(){
  const limit=$maxNodes, depthLimit=$maxDepth;
  const out=[], refs=new Map();
  const encoder=new TextEncoder();
  const clean=(v)=>{const normalized=String(v||'').replace(/\\s+/g,' ').trim();let out='',used=0;for(const ch of normalized){const size=encoder.encode(ch).length;if(used+size>${CefBrowserAutomationBroker.maxNodeTextBytes})break;out+=ch;used+=size;}return out;};
  const path=(el)=>{const parts=[]; while(el&&el.nodeType===1){let p=el.tagName.toLowerCase(); if(el.id){p+='#'+CSS.escape(el.id);parts.unshift(p);break;} let i=1,s=el;while((s=s.previousElementSibling))if(s.tagName===el.tagName)i++;p+=':nth-of-type('+i+')';parts.unshift(p);el=el.parentElement;}return parts.join('>');};
  const depth=(el)=>{let d=0;while(el&&el.parentElement){d++;el=el.parentElement;}return d;};
  const role=(el)=>{const explicit=el.getAttribute('role');if(explicit)return clean(explicit);const t=el.tagName.toLowerCase();if(t==='a')return 'link';if(t==='button')return 'button';if(t==='input'){const k=(el.type||'text').toLowerCase();if(k==='checkbox')return 'checkbox';if(k==='radio')return 'radio';if(k==='submit'||k==='button')return 'button';return 'textbox';}if(t==='textarea')return 'textbox';if(t==='select')return 'combobox';if(t==='img')return 'image';if(/^h[1-6]\$/.test(t))return 'heading';if(t==='form')return 'form';if(t==='nav')return 'navigation';if(t==='main')return 'main';return 'generic';};
  const name=(el)=>clean(el.getAttribute('aria-label')||el.alt||el.title||(el.labels&&el.labels[0]&&el.labels[0].innerText)||el.innerText||el.value||'');
  const state=(el)=>({disabled:!!el.disabled||el.getAttribute('aria-disabled')==='true',focused:document.activeElement===el,checked:!!el.checked||el.getAttribute('aria-checked')==='true',selected:!!el.selected||el.getAttribute('aria-selected')==='true',expanded:el.getAttribute('aria-expanded')==='true'});
  const editable=(el)=>{const tag=el.tagName.toLowerCase(),type=(el.type||'text').toLowerCase();return !el.disabled&&!el.readOnly&&(el.isContentEditable||tag==='textarea'||(tag==='input'&&['text','search','email','url','tel','number'].includes(type)));};
  const typedValue=(el)=>el.isContentEditable?(el.innerText||el.textContent||''):(el.value||'');
  const sensitive=(el,type,n)=>{const autocomplete=clean(el.getAttribute('autocomplete')).toLowerCase().split(/\\s+/),identity=(n+' '+clean(el.name)+' '+clean(el.id)).toLowerCase();return type==='password'||autocomplete.some((v)=>v==='one-time-code'||v==='webauthn'||v.startsWith('cc-'))||/password|passcode|otp|one.time|card|cvv|cvc/.test(identity);};
  const action=(el,r,secret)=>{const a=[],tag=el.tagName.toLowerCase(),disabled=!!el.disabled||el.getAttribute('aria-disabled')==='true',canEdit=editable(el);if(!disabled&&!secret&&(r==='button'||r==='link'||r==='checkbox'||r==='radio'||r==='combobox'))a.push('click');if(!disabled&&!secret&&canEdit){a.push('type');a.push('press');}if(!disabled&&!secret&&tag==='select'){a.push('select');if(!a.includes('press'))a.push('press');}if(el.scrollHeight>el.clientHeight||el.scrollWidth>el.clientWidth)a.push('scroll');return a;};
  const risk=(el,r,type,secret)=>{const tag=el.tagName.toLowerCase(),form=!!el.form||!!el.closest('form'),href=clean(el.getAttribute('href')),scheme=href&&href.includes(':')?href.split(':',1)[0].toLowerCase():'';const submit=type==='submit'||type==='image'||(tag==='button'&&type!=='button'&&type!=='reset')||!!el.getAttribute('formaction');const download=type==='file'||el.hasAttribute('download');const navigation=r==='link'||tag==='a'||(scheme&&scheme!=='http'&&scheme!=='https');const uncertainActivation=r==='button'||el.hasAttribute('onclick');return {clickConsequential:secret||submit||download||navigation||uncertainActivation,pressConsequential:secret||submit||download||navigation||uncertainActivation||(form&&(r==='textbox'||r==='combobox'))};};
  const elements=[document.documentElement,...document.documentElement.querySelectorAll('*')];
  let truncated=false;
  for(const el of elements){if(out.length>=limit){truncated=true;break;}if(depth(el)>depthLimit)continue;const rect=el.getBoundingClientRect();const style=getComputedStyle(el);if(style.display==='none'||style.visibility==='hidden'||rect.width<=0||rect.height<=0)continue;const ref='n'+(out.length+1);refs.set(el,ref);let parent=el.parentElement;while(parent&&!refs.has(parent))parent=parent.parentElement;const r=role(el),n=name(el),type=(el.type||'').toLowerCase(),tag=el.tagName.toLowerCase();const secret=sensitive(el,type,n),structural=risk(el,r,type,secret),canEdit=editable(el);out.push({ref,parentRef:parent?refs.get(parent):null,role:r,name:n||null,value:((canEdit||tag==='select')&&!secret)?clean(typedValue(el))||null:null,description:clean(el.getAttribute('aria-description'))||null,states:state(el),actions:action(el,r,secret),bounds:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},path:path(el),signature:[tag,type,r,n].join('|'),secret:secret,editable:canEdit,nativeSelect:tag==='select',clickConsequential:structural.clickConsequential,pressConsequential:structural.pressConsequential});}
  return JSON.stringify({nodes:out,truncated});
})()''';

String _structuralRevalidateExpression(String path) =>
    _revalidateExpression(path, scrollIntoView: false);

String _scrollAndRevalidateExpression(String path) =>
    _revalidateExpression(path, scrollIntoView: true);

String _revalidateExpression(
  String path, {
  required bool scrollIntoView,
}) =>
    '''(function(){
  const el=document.querySelector(${jsonEncode(path)});
  if(!el)return null;
  const beforeRect=el.getBoundingClientRect();
  const beforeX=window.scrollX,beforeY=window.scrollY;
  ${scrollIntoView ? "el.scrollIntoView({block:'center',inline:'center',behavior:'auto'});" : ''}
  const encoder=new TextEncoder();
  const clean=(v)=>{const normalized=String(v||'').replace(/\\s+/g,' ').trim();let out='',used=0;for(const ch of normalized){const size=encoder.encode(ch).length;if(used+size>${CefBrowserAutomationBroker.maxNodeTextBytes})break;out+=ch;used+=size;}return out;};
  const role=(el)=>{const explicit=el.getAttribute('role');if(explicit)return clean(explicit);const t=el.tagName.toLowerCase();if(t==='a')return 'link';if(t==='button')return 'button';if(t==='input'){const k=(el.type||'text').toLowerCase();if(k==='checkbox')return 'checkbox';if(k==='radio')return 'radio';if(k==='submit'||k==='button')return 'button';return 'textbox';}if(t==='textarea')return 'textbox';if(t==='select')return 'combobox';return 'generic';};
  const name=clean(el.getAttribute('aria-label')||el.alt||el.title||(el.labels&&el.labels[0]&&el.labels[0].innerText)||el.innerText||el.value||'');
  const r=role(el),rect=el.getBoundingClientRect(),type=(el.type||'').toLowerCase(),tag=el.tagName.toLowerCase();
  const editable=!el.disabled&&!el.readOnly&&(el.isContentEditable||tag==='textarea'||(tag==='input'&&['text','search','email','url','tel','number'].includes(type)));
  const typedValue=el.isContentEditable?(el.innerText||el.textContent||''):(el.value||'');
  const form=!!el.form||!!el.closest('form'),href=clean(el.getAttribute('href')),scheme=href&&href.includes(':')?href.split(':',1)[0].toLowerCase():'';
  const autocomplete=clean(el.getAttribute('autocomplete')).toLowerCase().split(/\\s+/),identity=(name+' '+clean(el.name)+' '+clean(el.id)).toLowerCase();
  const secret=type==='password'||autocomplete.some((v)=>v==='one-time-code'||v==='webauthn'||v.startsWith('cc-'))||/password|passcode|otp|one.time|card|cvv|cvc/.test(identity),submit=type==='submit'||type==='image'||(tag==='button'&&type!=='button'&&type!=='reset')||!!el.getAttribute('formaction');
  const download=type==='file'||el.hasAttribute('download'),navigation=r==='link'||tag==='a'||(scheme&&scheme!=='http'&&scheme!=='https'),uncertainActivation=r==='button'||el.hasAttribute('onclick');
  const clickConsequential=secret||submit||download||navigation||uncertainActivation;
  const pressConsequential=clickConsequential||(form&&(r==='textbox'||r==='combobox'));
  const checked=!!el.checked||el.getAttribute('aria-checked')==='true';
  const disabled=!!el.disabled||el.getAttribute('aria-disabled')==='true',actions=[];if(!disabled&&!secret&&(r==='button'||r==='link'||r==='checkbox'||r==='radio'||r==='combobox'))actions.push('click');if(!disabled&&!secret&&editable){actions.push('type');actions.push('press');}if(!disabled&&!secret&&tag==='select'){actions.push('select');if(!actions.includes('press'))actions.push('press');}if(el.scrollHeight>el.clientHeight||el.scrollWidth>el.clientWidth)actions.push('scroll');
  return JSON.stringify({signature:[tag,type,r,name].join('|'),role:r,actions:actions,bounds:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},secret:secret,editable:editable,typedValue:typedValue,checked:checked,focused:document.activeElement===el,nativeSelect:tag==='select',clickConsequential:clickConsequential,pressConsequential:pressConsequential,viewportChanged:beforeX!==window.scrollX||beforeY!==window.scrollY||beforeRect.x!==rect.x||beforeRect.y!==rect.y});
})()''';

String _focusPressTargetExpression(String path) =>
    '''(function(){const el=document.querySelector(${jsonEncode(path)});if(!el||el.disabled||el.getAttribute('aria-disabled')==='true')return JSON.stringify({focused:false});try{el.focus({preventScroll:true});}catch(_){el.focus();}return JSON.stringify({focused:document.activeElement===el});})()''';

String _typedValueExpression(String path) =>
    '''(function(){const el=document.querySelector(${jsonEncode(path)});if(!el)return null;const typedValue=el.isContentEditable?(el.innerText||el.textContent||''):(el.value||'');return JSON.stringify({typedValue:typedValue});})()''';

String _focusEditableExpression(String path, {required bool replace}) =>
    '''(function(){
  const el=document.querySelector(${jsonEncode(path)});
  const replace=${jsonEncode(replace)};
  if(!el)return JSON.stringify({focused:false});
  const tag=el.tagName.toLowerCase(),type=(el.type||'text').toLowerCase();
  const editable=!el.disabled&&!el.readOnly&&(el.isContentEditable||tag==='textarea'||(tag==='input'&&['text','search','email','url','tel','number'].includes(type)));
  if(!editable)return JSON.stringify({focused:false});
  try{el.focus({preventScroll:true});}catch(_){el.focus();}
  if(document.activeElement!==el)return JSON.stringify({focused:false});
  if(!replace){
    if(el.isContentEditable){
      const selection=window.getSelection(),range=document.createRange();
      range.selectNodeContents(el);range.collapse(false);
      selection.removeAllRanges();selection.addRange(range);
    }else if(typeof el.setSelectionRange==='function'){
      try{const end=String(el.value||'').length;el.setSelectionRange(end,end);}catch(_){}
    }
  }
  return JSON.stringify({focused:document.activeElement===el});
})()''';

String _activateToggleExpression(String path, String role) => '''(function(){
  const el=document.querySelector(${jsonEncode(path)});
  const expectedRole=${jsonEncode(role)};
  if(!el||el.tagName.toLowerCase()!=='input'||el.disabled)return JSON.stringify({activated:false});
  const type=(el.type||'').toLowerCase();
  if((expectedRole==='checkbox'&&type!=='checkbox')||(expectedRole==='radio'&&type!=='radio'))return JSON.stringify({activated:false});
  el.click();
  return JSON.stringify({activated:true});
})()''';

String _selectOptionExpression(String path, String value) => '''(function(){
  const el=document.querySelector(${jsonEncode(path)});
  if(!el||el.tagName.toLowerCase()!=='select'||el.disabled)return JSON.stringify({matched:false});
  const requested=${jsonEncode(value)};
  const clean=(v)=>String(v||'').replace(/\\s+/g,' ').trim();
  const options=Array.from(el.options||[]);
  const option=options.find((item)=>String(item.value)===requested)||options.find((item)=>clean(item.textContent)===requested);
  if(!option)return JSON.stringify({matched:false});
  el.focus();
  if(el.selectedIndex!==option.index){
    el.selectedIndex=option.index;
    el.dispatchEvent(new Event('input',{bubbles:true}));
    el.dispatchEvent(new Event('change',{bubbles:true}));
  }
  return JSON.stringify({matched:true,selectedValue:String(el.value||'')});
})()''';

String _nodeStateExpression(String path, String state) =>
    '''(function(){const el=document.querySelector(${jsonEncode(path)});if(!el)return null;const s=${jsonEncode(state)};let v=false;if(s==='disabled')v=!!el.disabled||el.getAttribute('aria-disabled')==='true';else if(s==='focused')v=document.activeElement===el;else if(s==='checked')v=!!el.checked||el.getAttribute('aria-checked')==='true';else if(s==='selected')v=!!el.selected||el.getAttribute('aria-selected')==='true';else if(s==='expanded')v=el.getAttribute('aria-expanded')==='true';return JSON.stringify(v);})()''';
