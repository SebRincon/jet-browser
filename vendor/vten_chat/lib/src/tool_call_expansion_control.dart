import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

@immutable
class ToolCallExpansionControlData {
  const ToolCallExpansionControlData({
    required this.expanded,
    required this.toggle,
  });

  final bool expanded;
  final VoidCallback toggle;
}

class ToolCallExpansionControl extends InheritedWidget {
  const ToolCallExpansionControl({
    super.key,
    required super.child,
    required this.data,
  });

  final ToolCallExpansionControlData data;

  static ToolCallExpansionControlData? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ToolCallExpansionControl>()
        ?.data;
  }

  @override
  bool updateShouldNotify(ToolCallExpansionControl oldWidget) {
    return oldWidget.data.expanded != data.expanded;
  }
}
