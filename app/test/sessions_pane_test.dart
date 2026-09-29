import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet_browser/agent_pane.dart';
import 'package:vten_chat/vten_chat.dart';
import 'package:jet_browser/browser_host.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:jet_browser/sidecar_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class SessionApi extends SidecarApi {
  SessionApi() : super('test-only');
  String selected = 'alpha';
  String provider = 'ready';
  bool fail = false;
  bool longHistory = false;
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic> get state => {
        'session': {'id': selected, 'title': '$selected chat'},
        'sessions': [
          for (final id in ['alpha', 'beta', 'new'])
            {'id': id, 'title': '$id chat'}
        ],
        'provider': {'status': provider},
        'messages': [
          if (longHistory)
            for (var index = 0; index < 18; index++)
              {
                'id': '$selected-old-$index',
                'created_at': index / 20,
                'role': 'assistant',
                'source': 'local',
                'text':
                    '$selected past response $index.\n\nDetails for the browser task.'
              },
          {
            'id': '$selected-1',
            'created_at': 1,
            'role': 'assistant',
            'source': 'local',
            'text': '$selected response'
          },
          {
            'id': '$selected-2',
            'created_at': 3,
            'role': 'assistant',
            'source': 'grok',
            'text': 'Research response'
          }
        ],
        'routes': [
          {
            'id': '$selected-route',
            'created_at': 2,
            'model': 'lfm_rlcd',
            'decision': 'Local browser action',
            'reason': 'A supported navigation request.',
            'elapsed_ms': 18,
            'status': 'done'
          }
        ],
      };
  @override
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    calls.add({'path': path, 'body': body});
    if (fail && path != '/state') throw StateError('Service rejected request');
    if (path == '/sessions/select') selected = body!['session_id'] as String;
    if (path == '/sessions') selected = 'new';
    if (path == '/state') return state;
    return {};
  }
}

Widget shell(BrowserHost host) => ShadcnApp(
    theme: jetTheme(),
    darkTheme: jetTheme(),
    themeMode: ThemeMode.dark,
    home: Scaffold(
        child: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(width: 390, child: AgentPane(host: host)))));

void main() {
  testWidgets('local and Grok sources and routing remain one stoppable chat',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 940));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SessionApi()..provider = 'routing';
    final host = BrowserHost('/test', api)
      ..connected = true
      ..state = api.state;
    Future<void> frames() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    await tester.pumpWidget(shell(host));
    await frames();
    expect(find.text('Jet Assistant'), findsNothing);
    expect(find.text('Local'), findsNothing);
    expect(find.text('Grok'), findsNothing);
    expect(find.textContaining('18 ms', findRichText: true), findsNothing);
    await tester.tap(find.text('1 step'));
    await frames();
    expect(find.textContaining('18 ms', findRichText: true), findsOneWidget);
    expect(find.text('Choosing a local action…'), findsNothing);
    expect(find.byType(DotMatrixLoader), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('chat-composer')), 'Reload this page');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await frames();
    expect(api.calls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('new-chat')));
    await frames();
    expect(api.calls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('chat-stop')));
    await frames();
    expect(api.calls.single['path'], '/chat/stop');
    expect(
        tester
            .widget<material.TextField>(
                find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        'Reload this page');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });

  testWidgets('saved chats select without mixing messages or losing drafts',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SessionApi();
    final host = BrowserHost('/test', api)
      ..connected = true
      ..state = api.state;
    await tester.pumpWidget(shell(host));
    await tester.pumpAndSettle();
    Future<void> select(String id) async {
      await tester.tap(find.byKey(const ValueKey('chat-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('session-$id')));
      await tester.pumpAndSettle();
    }

    String draft() => tester
        .widget<material.TextField>(find.byKey(const ValueKey('chat-composer')))
        .controller!
        .text;
    await tester.enterText(
        find.byKey(const ValueKey('chat-composer')), 'Alpha unfinished draft');
    await select('beta');
    expect(draft(), isEmpty);
    expect(find.text('beta response', findRichText: true), findsOneWidget);
    expect(find.text('alpha response', findRichText: true), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('chat-composer')), 'Beta unfinished draft');
    await select('alpha');
    expect(draft(), 'Alpha unfinished draft');
    expect(find.text('beta response', findRichText: true), findsNothing);
    await tester.tap(find.byKey(const ValueKey('new-chat')));
    await tester.pumpAndSettle();
    expect(api.calls.any((call) => call['path'] == '/sessions'), isTrue);
    expect(draft(), isEmpty);
    await select('beta');
    expect(draft(), 'Beta unfinished draft');
    api.fail = true;
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pumpAndSettle();
    expect(draft(), 'Beta unfinished draft');
    expect(find.textContaining('Service rejected request'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('new-chat')));
    await tester.pumpAndSettle();
    expect(api.selected, 'beta');
    expect(draft(), 'Beta unfinished draft');
    expect(find.text('beta response', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });

  testWidgets(
      'manual scroll survives streaming updates and session restoration',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 940));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = SessionApi()..longHistory = true;
    final host = BrowserHost('/test', api)
      ..connected = true
      ..state = api.state;
    await tester.pumpWidget(shell(host));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    await tester.drag(find.byType(ListView).first, const Offset(0, 440));
    await tester.pumpAndSettle();
    final remembered = scroll.position.pixels;
    expect(find.byKey(const ValueKey('jump-to-latest')), findsOneWidget);
    Future<void> select(String id) async {
      await tester.tap(find.byKey(const ValueKey('chat-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('session-$id')));
      await tester.pumpAndSettle();
    }

    await select('beta');
    await select('alpha');
    expect(scroll.position.pixels, closeTo(remembered, 1));
    host.state = {
      ...api.state,
      'messages': [
        ...(api.state['messages'] as List),
        {
          'id': 'streaming',
          'created_at': 10,
          'role': 'assistant',
          'source': 'grok',
          'text': 'New streamed response'
        },
      ]
    };
    await tester.pumpWidget(shell(host));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(remembered, 1));
    await tester.tap(find.byKey(const ValueKey('jump-to-latest')));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, closeTo(0, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });
}
