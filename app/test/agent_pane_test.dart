import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:jet_browser/agent_pane.dart';
import 'package:jet_browser/browser_host.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:jet_browser/sidecar_api.dart';
import 'package:vten_chat/vten_chat.dart';

class FakeApi extends SidecarApi {
  FakeApi() : super('test-only');
  final calls = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    calls.add({'path': path, 'body': body});
    return {};
  }
}

void main() {
  test('collection status reflects actual local work', () {
    expect(
        busyPhaseLabel({
          'busy': true,
          'provider': {'status': 'ready'},
          'collections': [
            {'status': 'running'}
          ]
        }),
        'Organizing locally');
    expect(
        busyPhaseLabel({
          'busy': true,
          'provider': {'status': 'ready'},
          'collections': [
            {'status': 'pausing'}
          ]
        }),
        'Pausing collection');
  });

  testWidgets(
      'one hundred completed steps collapse while collection stays accessible',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final host = BrowserHost('/test', FakeApi())..connected = true;
    host.state = {
      'session': {'id': 's'},
      'provider': {'status': 'ready'},
      'messages': [
        {
          'id': 'u',
          'role': 'user',
          'text': 'Organize the site',
          'created_at': 1,
          'turn_id': 'turn'
        }
      ],
      'task_history': List.generate(
          100,
          (i) => {
                'id': 't$i',
                'turn_id': 'turn',
                'created_at': 2 + i,
                'status': 'done',
                'goal': 'Task $i'
              }),
      'collections': [
        {
          'id': 'c',
          'turn_id': 'turn',
          'created_at': 102,
          'status': 'completed',
          'plan': {'title': 'Saved pages'},
          'counters': {'pages': 10, 'classified': 9, 'needs_review': 1}
        }
      ],
    };
    String? opened;
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        home: Scaffold(
            child:
                AgentPane(host: host, onOpenCollection: (id) => opened = id))));
    await tester.pumpAndSettle();
    expect(find.text('100 steps'), findsOneWidget);
    expect(find.text('Task 99'), findsNothing);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    await tester.tap(find.byKey(const Key('collection-open-c')));
    await tester.pump();
    expect(opened, 'c');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });

  testWidgets('job narration is folded and final answer stays visible',
      (tester) async {
    final host = BrowserHost('/test', FakeApi())..connected = true;
    host.state = {
      'session': {'id': 's'},
      'provider': {'status': 'ready'},
      'messages': [
        {
          'id': 'u',
          'role': 'user',
          'text': 'Save a report',
          'created_at': 1,
          'turn_id': 't'
        },
        {
          'id': 'p',
          'role': 'assistant',
          'text': 'Intermediate tool narration',
          'phase': 'progress',
          'created_at': 2,
          'turn_id': 't'
        },
        {
          'id': 'f',
          'role': 'assistant',
          'text': 'Your report is ready.',
          'created_at': 3,
          'turn_id': 't'
        },
      ]
    };
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(), home: Scaffold(child: AgentPane(host: host))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your report is ready.'), findsOneWidget);
    expect(find.textContaining('Intermediate tool narration'), findsNothing);
    await tester.tap(find.text('1 step'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Intermediate tool narration'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });

  testWidgets(
      'one Shadcn composer with inline browser actions and compact model settings',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 940));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = FakeApi();
    final host = BrowserHost('/test', api)..connected = true;
    host.state = {
      'provider': {'status': 'ready'},
      'settings': {'local_model': 'lfm_rlcd'},
      'messages': [
        {'id': 'm1', 'created_at': 1, 'role': 'user', 'text': 'Fill this form'}
      ],
      'task_history': [
        {
          'id': 't1',
          'created_at': 2,
          'model': 'laya_mlx',
          'goal': 'Enter a team name',
          'status': 'done',
          'steps': 1,
          'elapsed_ms': 450,
          'actions': [
            {'kind': 'fill', 'action': 'Team name'}
          ]
        }
      ],
    };
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(width: 480, child: AgentPane(host: host))))));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(find.byType(MessageList), findsOneWidget);
    expect(find.byType(EnhancedPromptInput), findsOneWidget);
    expect(find.text('Run locally'), findsNothing);
    expect(find.text('Jet Assistant'), findsNothing);
    expect(find.text('Enter a team name'), findsNothing);
    expect(
        find.textContaining('Browser task', findRichText: true), findsNothing);
    await tester.tap(find.text('1 step'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Browser task', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('Enter a team name'), findsOneWidget);
    expect(find.textContaining('fill · Team name'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-model')));
    await tester.pumpAndSettle();
    expect(find.byType(Select<String>), findsOneWidget);
    await tester.tap(find.byType(Select<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Laya Typed · 421M').last);
    await tester.pumpAndSettle();
    expect(api.calls.single, {
      'path': '/settings',
      'body': {'local_model': 'laya_typed'}
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });
}
