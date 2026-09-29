import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet_browser/agent_pane.dart';
import 'package:jet_browser/browser_host.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:jet_browser/sidecar_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:vten_chat/vten_chat.dart';

class PortApi extends SidecarApi {
  PortApi() : super('test-only');
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic> state = {'provider': {'status': 'ready'}};
  @override
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    calls.add({'path': path, 'body': body});
    if (path == '/state') return state;
    return {};
  }
}

Widget pane(BrowserHost host, double width) => ShadcnApp(
    theme: jetTheme(),
    darkTheme: jetTheme(),
    themeMode: ThemeMode.dark,
    home: Scaffold(
        child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: width, child: AgentPane(host: host)))));

void main() {
  testWidgets('empty, error, handoff, and diagnostics stay in one composer',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = PortApi();
    final host = BrowserHost('/test', api)
      ..connected = true
      ..state = {
        'session': {'id': 's', 'title': 'Space'},
        'provider': {'status': 'ready'},
        'messages': [
          {
            'id': 'u',
            'created_at': 1,
            'role': 'user',
            'text': 'Summarize this page'
          },
          {
            'id': 'a',
            'created_at': 3,
            'role': 'assistant',
            'source': 'grok',
            'text': 'Here is the summary.'
          }
        ],
        'routes': [
          {
            'id': 'r',
            'created_at': 2,
            'decision': 'grok',
            'status': 'done',
            'reason': 'Research needs Grok.',
            'elapsed_ms': 12
          }
        ],
        'trace': {
          'turn_id': 'turn/1',
          'events': [
            {'id': '1', 'ts': 1, 'event': 'router.choice', 'level': 'info'}
          ],
          'summary': {'duration_ms': 12, 'error_count': 0}
        }
      };
    await tester.pumpWidget(pane(host, 420));
    await tester.pumpAndSettle();
    expect(find.text('Activity'), findsNothing);
    expect(find.text('Jet Assistant'), findsNothing);
    expect(find.textContaining('Handed off to Grok', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('Research needs Grok.'), findsNothing);
    await tester.tap(find.textContaining('Handed off to Grok', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('Research needs Grok.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('trace-toggle')), findsOneWidget);
    expect(find.byType(material.TextField), findsOneWidget);
    expect(tester.takeException(), isNull);

    host.state = {
      'session': {'id': 's', 'title': 'Space'},
      'provider': {'status': 'ready'},
      'messages': [
        {'id': 'u2', 'created_at': 1, 'role': 'user', 'text': 'Open it'}
      ],
      'routes': [
        {
          'id': 'bad',
          'created_at': 2,
          'decision': 'local',
          'status': 'error',
          'error': 'Native tab disappeared',
          'elapsed_ms': 4
        }
      ]
    };
    await tester.pumpWidget(pane(host, 420));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Native tab disappeared', findRichText: true),
        findsWidgets);
    expect(find.byIcon(LucideIcons.badgeAlert), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });

  testWidgets('enter sends, shift-enter does not, and both widths fit',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = PortApi()
      ..state = {
        'session': {'id': 's', 'title': 'Empty'},
        'provider': {'status': 'ready'},
        'messages': []
      };
    final host = BrowserHost('/test', api)
      ..connected = true
      ..state = api.state;
    await tester.pumpWidget(pane(host, 360));
    await tester.pumpAndSettle();
    expect(find.byType(ChatSessionTab), findsOneWidget);
    expect(find.byType(MessageList), findsOneWidget);
    expect(find.text('Activity'), findsNothing);
    final field = find.byKey(const ValueKey('chat-composer'));
    await tester.tap(field);
    await tester.enterText(field, 'Hello Jet');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(api.calls, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(api.calls.single['path'], '/chat');
    expect(tester.takeException(), isNull);

    host.state = {
      'session': {'id': 's', 'title': 'Wide'},
      'provider': {'status': 'ready'},
      'messages': [
        {'id': 'u', 'created_at': 1, 'role': 'user', 'text': 'Wide layout'}
      ]
    };
    await tester.pumpWidget(pane(host, 800));
    await tester.pumpAndSettle();
    final widths = tester
        .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
        .map((box) => box.constraints.maxWidth)
        .where((width) => width == MessageList.contentColumnMaxWidth);
    expect(widths, isNotEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });

  testWidgets('disconnected service is visible and inspectors fit a short pane',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = PortApi()
      ..state = {
        'session': {'id': 's', 'title': 'Short'},
        'provider': {'status': 'ready'},
        'messages': [
          {'id': 'u', 'created_at': 1, 'role': 'user', 'text': 'Keep going'}
        ],
        'trace': {
          'turn_id': 'turn/1',
          'events': [
            for (var i = 0; i < 12; i++)
              {'id': '$i', 'ts': i, 'event': 'span.$i', 'level': 'info'}
          ]
        }
      };
    final host = BrowserHost('/test', api)
      ..connected = false
      ..connectionError = 'Local service unavailable'
      ..state = api.state;
    await tester.pumpWidget(pane(host, 390));
    await tester.pump();
    expect(find.byKey(const ValueKey('connection-notice')), findsOneWidget);
    expect(find.textContaining('Local service unavailable'), findsOneWidget);
    final send = tester.widget<PrimaryButton>(find.byKey(const ValueKey('chat-send')));
    expect(send.onPressed, isNull);
    expect(find.byKey(const ValueKey('chat-stop')), findsNothing);

    host.connected = true;
    host.connectionError = null;
    host.state = {
      ...api.state,
      'provider': {'status': 'running'},
    };
    await tester.pumpWidget(pane(host, 390));
    await tester.pump();
    expect(find.byKey(const ValueKey('connection-notice')), findsNothing);
    final stop = tester.widget<DestructiveButton>(find.byKey(const ValueKey('chat-stop')));
    expect(stop.onPressed, isNotNull);
    host.connected = false;
    await tester.pumpWidget(pane(host, 390));
    await tester.pump();
    expect(
        tester.widget<DestructiveButton>(find.byKey(const ValueKey('chat-stop'))).onPressed,
        isNull);

    host.connected = true;
    await tester.pumpWidget(pane(host, 390));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-diagnostics')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('trace-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('trace-toggle')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-history')));
    await tester.pump();
    expect(find.byKey(const ValueKey('trace-toggle')), findsNothing);
    expect(find.text('Chat history'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-model')));
    await tester.pump();
    expect(find.text('Chat history'), findsNothing);
    expect(find.text('Browser action model'), findsOneWidget);
    expect(tester.getSize(find.byType(MessageList)).height, greaterThan(80));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });
}
