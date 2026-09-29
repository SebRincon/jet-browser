/// Browser-parity event types emitted by the native OSR texture pipeline.
///
/// These cover the surfaces a texture-rendered browser must forward to the
/// host UI because no AppKit view exists to handle them natively.
enum CefParityEventType {
  tooltip,
  jsDialog,
  fullscreenModeChange,
  imeCompositionRangeChanged,
  textInputStateChanged,
  devToolsClosed,
  inspectElementRequested,
  devToolsShortcut,
  contextMenu,
  dragStarted,
  dragEnded,
  swipeNavigation,
  sitePermissionRequest,
  statusMessage,
  zoomChanged;

  static CefParityEventType? fromChannelName(String? name) {
    for (final value in CefParityEventType.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

enum CefSitePermissionKind {
  camera,
  microphone,
  location,
  notifications,
  clipboard,
  desktopAudio,
  screenCapture,
  unknown;

  static CefSitePermissionKind? fromChannelName(String? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// Validated cross-language contract for a CEF permission callback retained
/// by native code until Dart explicitly allows or blocks it.
class CefSitePermissionRequest {
  const CefSitePermissionRequest({
    required this.browserId,
    required this.promptId,
    required this.origin,
    required this.permissions,
  });

  final int browserId;
  final String promptId;
  final String origin;
  final List<CefSitePermissionKind> permissions;

  static CefSitePermissionRequest? fromEvent(CefParityEvent event) {
    if (event.type != CefParityEventType.sitePermissionRequest) return null;
    final promptId = event.data['promptId'];
    final origin = event.data['origin'];
    final rawPermissions = event.data['permissions'];
    if (promptId is! String ||
        promptId.isEmpty ||
        origin is! String ||
        origin.isEmpty ||
        rawPermissions is! List) {
      return null;
    }
    final permissions = rawPermissions
        .whereType<String>()
        .map(CefSitePermissionKind.fromChannelName)
        .whereType<CefSitePermissionKind>()
        .toList(growable: false);
    if (permissions.length != rawPermissions.length || permissions.isEmpty) {
      return null;
    }
    return CefSitePermissionRequest(
      browserId: event.browserId,
      promptId: promptId,
      origin: origin,
      permissions: permissions,
    );
  }
}

/// A single parity event scoped to one browser.
class CefParityEvent {
  const CefParityEvent({
    required this.type,
    required this.browserId,
    required this.data,
  });

  final CefParityEventType type;
  final int browserId;
  final Map<String, dynamic> data;

  /// Returns `null` when the map is not a parity event (unknown type or
  /// missing browser id) so callers can fall through to other event kinds.
  static CefParityEvent? fromMap(Map<String, dynamic> map) {
    final type = CefParityEventType.fromChannelName(map['type'] as String?);
    final browserId = map['browserId'];
    if (type == null || browserId is! int) return null;
    return CefParityEvent(type: type, browserId: browserId, data: map);
  }
}
