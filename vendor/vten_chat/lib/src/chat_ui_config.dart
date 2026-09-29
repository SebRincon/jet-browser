import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

enum VtenChatUiLayoutMode { desktop, mobile }

enum VtenChatUiCompactStyle { standard, vten }

@immutable
class VtenChatUiConfigData {
  const VtenChatUiConfigData({
    this.layoutMode = VtenChatUiLayoutMode.desktop,
    this.compactToolCalls = false,
    this.compactStyle = VtenChatUiCompactStyle.standard,
    this.toolCallsDefaultExpanded = false,
  });

  final VtenChatUiLayoutMode layoutMode;
  final bool compactToolCalls;
  final VtenChatUiCompactStyle compactStyle;

  /// Whether tool call widgets start expanded (true) or as compact
  /// one-line rows (false, default). Users can always toggle either way.
  final bool toolCallsDefaultExpanded;
}

class VtenChatUiConfig extends InheritedWidget {
  const VtenChatUiConfig({
    super.key,
    required super.child,
    this.data = const VtenChatUiConfigData(),
  });

  final VtenChatUiConfigData data;

  static VtenChatUiConfigData of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<VtenChatUiConfig>()
            ?.data ??
        const VtenChatUiConfigData();
  }

  @override
  bool updateShouldNotify(VtenChatUiConfig oldWidget) {
    return oldWidget.data.layoutMode != data.layoutMode ||
        oldWidget.data.compactToolCalls != data.compactToolCalls ||
        oldWidget.data.compactStyle != data.compactStyle ||
        oldWidget.data.toolCallsDefaultExpanded !=
            data.toolCallsDefaultExpanded;
  }
}
