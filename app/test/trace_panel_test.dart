import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:jet_browser/sidecar_api.dart';
import 'package:jet_browser/trace_panel.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class TraceApi extends SidecarApi {
  TraceApi() : super('test-only');
  final paths = <String>[];
  Future<Map<String, dynamic>> Function()? response;
  @override
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) {
    paths.add(path);
    return response!();
  }
}

Map<String, dynamic> event(String id, num ts, String name, {String? error}) => {
      'id': id,
      'ts': ts,
      'event': name,
      'level': error == null ? 'info' : 'error',
      'span_id': 'span-$id',
      'duration_ms': 18,
      'attributes': error == null ? {'decision': 'local'} : {'error': error},
    };

Widget shell(
        TraceApi api, String session, Map<String, dynamic> trace) =>
    ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: Align(
                alignment: Alignment.bottomRight,
                child: SizedBox(
                    width: 390,
                    child: TracePanel(
                        trace: trace, api: api, sessionId: session)))));

void main() {
  testWidgets(
      'trace is compact, shows errors, loads retained spans and copies details',
      (tester) async {
    final api = TraceApi();
    final e1 = event('1', 2, 'router.choice');
    final e2 =
        event('2', 10, 'browser.failed', error: 'Native tab disappeared');
    final trace = {
      'turn_id': 'turn/1',
      'events': [e1, e2],
      'summary': {'duration_ms': 1450, 'error_count': 1}
    };
    api.response = () async => {
          'turn_id': 'turn/1',
          'events': [event('0', 1, 'turn.started'), e1, e2],
          'summary': trace['summary']
        };
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
    await tester.pumpWidget(shell(api, 's1', trace));
    await tester.pumpAndSettle();
    expect(find.text('1 error'), findsOneWidget);
    expect(find.text('router.choice'), findsNothing);
    expect(find.text('2 events · 1.45 s'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('trace-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Native tab disappeared'), findsOneWidget);
    await tester.tap(find.text('router.choice'));
    await tester.pumpAndSettle();
    expect(find.textContaining('span-1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('trace-load-full')));
    await tester.pumpAndSettle();
    expect(api.paths, ['/traces?turn_id=turn%2F1&limit=2000']);
    expect(find.text('3 events · 1.45 s'), findsOneWidget);
    await tester.tap(find.text('Copy ID'));
    await tester.pumpAndSettle();
    expect(clipboard, 'turn/1');
    await tester.tap(find.text('Copy trace'));
    await tester.pumpAndSettle();
    final data = jsonDecode(clipboard!) as Map;
    expect((data['events'] as List).map((e) => e['id']), ['0', '1', '2']);
    expect(data['turn_id'], 'turn/1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a late retained trace never appears in another session',
      (tester) async {
    final api = TraceApi();
    final response = Completer<Map<String, dynamic>>();
    api.response = () => response.future;
    await tester.pumpWidget(shell(api, 'a', {
      'turn_id': 'a',
      'events': [event('a', 1, 'old.event')]
    }));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trace-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('trace-load-full')));
    await tester.pump();
    await tester.pumpWidget(shell(api, 'b', {
      'turn_id': 'b',
      'events': [event('b', 2, 'current.event')]
    }));
    response.complete({
      'turn_id': 'a',
      'events': [event('secret', 3, 'old.private.event')]
    });
    await tester.pumpAndSettle();
    expect(find.text('current.event'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('trace-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('current.event'), findsOneWidget);
    expect(find.text('old.private.event'), findsNothing);
    expect(find.textContaining('Loading retained'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
