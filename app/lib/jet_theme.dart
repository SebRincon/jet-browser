import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:vten_chat/vten_chat.dart';

/// vten 2026 dark workbench colors through the copied [vsCodeColorScheme].
ThemeData jetTheme() => ThemeData(
      colorScheme: vten2026DarkScheme(),
      radius: 0.5,
      typography: const Typography.geist(),
    );

class ChromeButton extends StatelessWidget {
  const ChromeButton(
      {super.key, required this.label, required this.icon, this.onPressed});
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
      label: label,
      button: true,
      child: Tooltip(
        alignment: Alignment.bottomCenter,
        anchorAlignment: Alignment.topCenter,
        tooltip: (_) => TooltipContainer(child: Text(label)),
        child: IconButton.ghost(
            size: ButtonSize.small,
            onPressed: onPressed,
            icon: Icon(icon, size: 18)),
      ));
}
