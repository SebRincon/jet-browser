library;

/// Maps a resolved VS Code **workbench colors** map (the `colors` object of a
/// theme, with any `include` chain already merged) onto the app's
/// `shadcn_flutter` [ColorScheme] and editor tokens.
///
/// This is the single source of truth for "a VS Code theme becomes our theme".
/// Both the built-in themes ([app_themes.dart]) and runtime-imported VS Code
/// themes ([appThemeFromVsCodeColors]) go through here, so the default look and
/// an imported `.json` theme travel the exact same code path.
///
/// VS Code themes only define *overrides*; absent keys inherit platform
/// defaults. We mirror that by resolving each shadcn role from an ordered list
/// of candidate keys and deriving a sensible value when none is present.

import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Parses a VS Code hex color: `#RGB`, `#RRGGBB`, or `#RRGGBBAA`.
///
/// Returns `null` for null/empty/malformed input so callers can fall back.
Color? parseVsCodeColor(String? hex) {
  if (hex == null) return null;
  var h = hex.trim();
  if (h.isEmpty || h[0] != '#') return null;
  h = h.substring(1);
  if (h.length == 3) {
    // #RGB -> #RRGGBB
    h = h.split('').map((c) => '$c$c').join();
  }
  if (h.length == 6) h = '${h}FF'; // add opaque alpha
  if (h.length != 8) return null;
  final rgba = int.tryParse(h, radix: 16);
  if (rgba == null) return null;
  final r = (rgba >> 24) & 0xFF;
  final g = (rgba >> 16) & 0xFF;
  final b = (rgba >> 8) & 0xFF;
  final a = rgba & 0xFF;
  return Color.fromARGB(a, r, g, b);
}

/// Alpha-composites [fg] over opaque [bg] (source-over). Used to flatten VS
/// Code's translucent overlay colors (e.g. `list.hoverBackground` = `#FFFFFF14`)
/// into the opaque surface colors shadcn expects.
Color _flatten(Color fg, Color bg) {
  final fa = fg.a;
  if (fa >= 1.0) return fg;
  double mix(double f, double b) => f * fa + b * (1 - fa);
  return Color.from(
    alpha: 1.0,
    red: mix(fg.r, bg.r),
    green: mix(fg.g, bg.g),
    blue: mix(fg.b, bg.b),
  );
}

/// Relative luminance (0..1) for light/dark derivations.
double _luminance(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

/// Lightens or darkens [c] toward white/black by [amount] (0..1).
Color _shift(Color c, double amount) {
  final target = _luminance(c) < 0.5 ? 1.0 : 0.0;
  double mv(double v) => v + (target - v) * amount;
  return Color.from(
    alpha: 1.0,
    red: mv(c.r),
    green: mv(c.g),
    blue: mv(c.b),
  );
}

/// The editor-specific colors that live outside a shadcn [ColorScheme]: caret,
/// selection wash, and the diagnostic warning tint (VS Code has no shadcn
/// "warning" role). Kept together so a theme carries them alongside its scheme.
class VsCodeEditorTokens {
  const VsCodeEditorTokens({
    required this.cursor,
    required this.selection,
    required this.warning,
  });

  final Color cursor;
  final Color selection;
  final Color warning;
}

class _Resolver {
  _Resolver(this.colors, this.background);
  final Map<String, String?> colors;
  final Color background;

  /// First present, parseable candidate; else [fallback]. Surface colors are
  /// flattened onto the background so translucent overlays become opaque.
  Color pick(List<String> keys, Color fallback, {bool flatten = true}) {
    for (final k in keys) {
      final c = parseVsCodeColor(colors[k]);
      if (c != null) return flatten ? _flatten(c, background) : c;
    }
    return fallback;
  }
}

/// Builds a shadcn [ColorScheme] from resolved VS Code workbench [colors].
ColorScheme vsCodeColorScheme(
  Map<String, String?> colors,
  Brightness brightness,
) {
  final isDark = brightness == Brightness.dark;
  final background =
      parseVsCodeColor(colors['editor.background']) ??
      (isDark ? const Color(0xFF121314) : const Color(0xFFFFFFFF));
  final foreground =
      parseVsCodeColor(colors['foreground']) ??
      (isDark ? const Color(0xFFBFBFBF) : const Color(0xFF202020));
  final r = _Resolver(colors, background);

  // Surface ladder.
  final card = r.pick(
    const ['editorWidget.background', 'sideBar.background'],
    _shift(background, 0.04),
  );
  final popover = r.pick(
    const [
      'editorSuggestWidget.background',
      'editorWidget.background',
      'dropdown.background',
    ],
    card,
  );
  final sidebar = r.pick(const ['sideBar.background'], card);
  final muted = r.pick(
    const ['editor.lineHighlightBackground', 'editorGroupHeader.tabsBackground'],
    _shift(background, 0.06),
  );
  final secondary = r.pick(
    const ['list.inactiveSelectionBackground', 'list.hoverBackground'],
    _shift(background, 0.10),
  );
  final accent = r.pick(
    const ['list.activeSelectionBackground', 'list.hoverBackground'],
    _shift(background, 0.14),
  );

  // Foregrounds.
  final mutedForeground = r.pick(
    const ['descriptionForeground', 'editorLineNumber.foreground'],
    _shift(foreground, 0.35),
    flatten: false,
  );
  final sidebarForeground = r.pick(
    const ['sideBar.foreground'],
    foreground,
    flatten: false,
  );

  // Accents.
  final primary = r.pick(const ['button.background'], const Color(0xFF297AA0));
  final primaryForeground = r.pick(
    const ['button.foreground'],
    const Color(0xFFFFFFFF),
    flatten: false,
  );
  final ring = r.pick(const ['focusBorder'], primary, flatten: false);
  final destructive = r.pick(
    const ['errorForeground'],
    const Color(0xFFF48771),
    flatten: false,
  );

  // Borders.
  final border = r.pick(
    const ['panel.border', 'editorGroup.border', 'contrastBorder'],
    _shift(background, 0.10),
  );
  final input = r.pick(const ['input.border', 'dropdown.border'], border);

  // Chart swatches from the theme's own data-viz palette.
  Color chart(String key, Color fallback) =>
      r.pick([key], fallback, flatten: false);

  return ColorScheme(
    brightness: brightness,
    background: background,
    foreground: foreground,
    card: card,
    cardForeground: foreground,
    popover: popover,
    popoverForeground: foreground,
    primary: primary,
    primaryForeground: primaryForeground,
    secondary: secondary,
    secondaryForeground: foreground,
    muted: muted,
    mutedForeground: mutedForeground,
    accent: accent,
    accentForeground: foreground,
    destructive: destructive,
    destructiveForeground: const Color(0xFFFFFFFF),
    border: border,
    input: input,
    ring: ring,
    chart1: chart('charts.blue', const Color(0xFF569CD6)),
    chart2: chart('charts.green', const Color(0xFFB5CEA8)),
    chart3: chart('charts.yellow', const Color(0xFFDCDCAA)),
    chart4: chart('charts.orange', const Color(0xFFCE9178)),
    chart5: chart('charts.red', const Color(0xFFF48771)),
    sidebar: sidebar,
    sidebarForeground: sidebarForeground,
    sidebarPrimary: primary,
    sidebarPrimaryForeground: primaryForeground,
    sidebarAccent: accent,
    sidebarAccentForeground: foreground,
    sidebarBorder: r.pick(const ['sideBarSectionHeader.border', 'panel.border'], border),
    sidebarRing: ring,
  );
}

/// Editor caret/selection/warning tokens from resolved VS Code [colors].
VsCodeEditorTokens vsCodeEditorTokens(
  Map<String, String?> colors,
  Brightness brightness,
) {
  final isDark = brightness == Brightness.dark;
  return VsCodeEditorTokens(
    cursor:
        parseVsCodeColor(colors['editorCursor.foreground']) ??
        parseVsCodeColor(colors['foreground']) ??
        (isDark ? const Color(0xFFBBBEBF) : const Color(0xFF202020)),
    selection:
        parseVsCodeColor(colors['editor.selectionBackground']) ??
        (isDark ? const Color(0x88276782) : const Color(0x400069CC)),
    warning:
        parseVsCodeColor(colors['editorWarning.foreground']) ??
        parseVsCodeColor(colors['list.warningForeground']) ??
        (isDark ? const Color(0xFFE5BA7D) : const Color(0xFF9D7500)),
  );
}
