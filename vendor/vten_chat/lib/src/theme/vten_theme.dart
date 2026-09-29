import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'vscode_2026_colors.g.dart';
import 'vscode_color_scheme.dart';

/// 2026 dark workbench colors mapped through the copied [vsCodeColorScheme].
ColorScheme vten2026DarkScheme() => vsCodeColorScheme(
      Map<String, String?>.from(k2026DarkColors),
      Brightness.dark,
    );
