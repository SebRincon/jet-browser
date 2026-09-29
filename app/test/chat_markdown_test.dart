import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet_browser/chat_markdown.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

Iterable<TextSpan> spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? <InlineSpan>[]) {
      yield* spans(child);
    }
  }
}

void main() {
  test('dark chat text, metadata and controls have readable contrast', () {
    final colors = jetTheme().colorScheme;
    double contrast(Color a, Color b) {
      final luminance = [a.computeLuminance(), b.computeLuminance()]..sort();
      return (luminance.last + .05) / (luminance.first + .05);
    }

    expect(colors.brightness, Brightness.dark);
    expect(colors.background, const Color(0xff121314));
    expect(colors.foreground, const Color(0xffbfbfbf));
    expect(colors.sidebar, const Color(0xff191a1b));
    for (final surface in [
      colors.background,
      colors.sidebar,
      colors.card,
      colors.muted,
      colors.popover
    ]) {
      expect(contrast(colors.foreground, surface), greaterThanOrEqualTo(4.5));
      expect(
          contrast(colors.mutedForeground, surface), greaterThanOrEqualTo(4.5));
    }
    expect(contrast(colors.primaryForeground, colors.primary),
        greaterThanOrEqualTo(4.5));
    expect(contrast(const Color(0xFF60A5FA), colors.background),
        greaterThanOrEqualTo(4.5));
  });

  testWidgets('Markdown renders blocks, preserves code and routes safe links',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final opened = <String>[];
    String? clipboard;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: SingleChildScrollView(
                child: SizedBox(
                    width: 440,
                    child: ChatMarkdown(
                        onOpenLink: opened.add,
                        text: '# Results\n\n**Ready** with `local` models.\n\n'
                            '- Navigate\n- Fill a form\n\n'
                            '```python\nprint("hello")\n```\n\n'
                            '[Model docs](https://example.com/docs) and '
                            '[unsafe](javascript:alert(1)).\n\n'
                            '> Review the page.\n\n'
                            '| Model | Time |\n| --- | --- |\n| LFM | 1 s |'))))));
    await tester.pumpAndSettle();
    expect(find.text('Results', findRichText: true), findsOneWidget);
    expect(find.textContaining('Navigate', findRichText: true), findsWidgets);
    expect(find.byType(ChatCodeBlock), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(clipboard, 'print("hello")\n');
    expect(find.text('Copied'), findsOneWidget);
    final links = tester
        .widgetList<RichText>(find.byType(RichText))
        .expand((rich) => spans(rich.text))
        .where((span) => span.recognizer is TapGestureRecognizer)
        .toList();
    final docs = links.firstWhere((span) => span.text == 'Model docs');
    (docs.recognizer! as TapGestureRecognizer).onTap!();
    final unsafe = links.firstWhere((span) => span.text == 'unsafe');
    (unsafe.recognizer! as TapGestureRecognizer).onTap!();
    expect(opened, ['https://example.com/docs']);
    expect(tester.takeException(), isNull);
  });
}
