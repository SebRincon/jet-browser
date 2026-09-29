import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:vten_chat/vten_chat.dart';

void main() {
  testWidgets('user bubble expands in place and the copy footer is icon-only',
      (tester) async {
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
    final prompt = List.generate(9, (i) => 'Please check item $i.').join('\n');
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: SingleChildScrollView(
                child: SizedBox(
                    width: 390,
                    child: VtenChatUiConfig(
                        data: const VtenChatUiConfigData(
                            compactToolCalls: true,
                            compactStyle: VtenChatUiCompactStyle.vten),
                        child: Column(children: [
                          MessageBubble.user(text: prompt),
                          MessageBubble.assistant(
                              copyText: 'Completed **locally**.',
                              markdown: const Text('Completed **locally**.')),
                        ])))))));
    await tester.pumpAndSettle();
    expect(find.text('Copy response'), findsNothing);
    expect(find.text('Local'), findsNothing);
    expect(find.byType(UserMessageBubble), findsOneWidget);
    await tester.tap(find.byType(UserMessageBubble));
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);
    expect(find.widgetWithText(SelectableText, prompt), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Copy message'));
    await tester.pumpAndSettle();
    expect(clipboard, 'Completed **locally**.');
    expect(find.byIcon(LucideIcons.check), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
