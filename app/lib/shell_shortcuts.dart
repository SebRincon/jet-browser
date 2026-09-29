import 'package:flutter/services.dart';

/// Native macOS key equivalents call this channel. Flutter [Shortcuts] use the
/// same action names so a swallowed NSEvent and a widget-test key agree.
const shellShortcutChannel = MethodChannel('jet_browser/shell_shortcuts');

const shellShortcutSelectAddress = 'selectAddress';
const shellShortcutNewTab = 'newTab';
const shellShortcutReload = 'reload';

/// Drops a second delivery of the same action until [release]. Native
/// performKeyEquivalent and the Flutter fallback can both observe one chord.
class ShellShortcutGate {
  final _held = <String>{};

  bool claim(String action) {
    if (_held.contains(action)) return false;
    _held.add(action);
    return true;
  }

  void release(String action) => _held.remove(action);
}

void bindShellShortcuts(void Function(String action) onAction) {
  shellShortcutChannel.setMethodCallHandler((call) async {
    if (call.method != 'shortcut' || call.arguments is! String) return;
    onAction(call.arguments as String);
  });
}

void unbindShellShortcuts() {
  shellShortcutChannel.setMethodCallHandler(null);
}
