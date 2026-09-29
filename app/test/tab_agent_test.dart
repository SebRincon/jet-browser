import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:jet_browser/tab_agent_state.dart';
import 'package:jet_browser/tab_agent_badge.dart';

Map<String, dynamic> row(String id, String status, {String tab = 'tab-a'}) => {
      'id': id,
      'status': status,
      'plan': {'tab_id': tab, 'title': 'Bookmarks'},
      'counters': {'pages': 50, 'classified': 42, 'elapsed_ms': 61123.4},
      'supervision': {
        'pending': {'status': 'awaiting_user'}
      }
    };

void main() {
  setUpAll(() async {
    for (final font in {
      'GeistSans': 'lib/fonts/Geist-Regular.otf',
      'LucideIcons': 'lib/icons/LucideIcons.ttf',
    }.entries) {
      await (FontLoader('packages/shadcn_flutter/${font.key}')
            ..addFont(rootBundle.load('packages/shadcn_flutter/${font.value}')))
          .load();
    }
  });
  test(
      'job identity follows the tab, includes elapsed doubles and latest pause',
      () {
    final state = {
      'collections': [row('new', 'paused'), row('old', 'paused')]
    };
    final job = TabAgentState.fromState(state, 'tab-a')!;
    expect(job.collectionId, 'new');
    expect(job.label, 'Review ready');
    expect(job.elapsedMs, 61123);
    expect(job.tooltip, contains('1m 1s'));
    expect(TabAgentState.fromState(state, 'other'), isNull);
    expect(
        TabAgentState.fromState({
          'collections': [row('done', 'completed')]
        }, 'tab-a'),
        isNull);
  });
  test('running job is selected over a paused job', () {
    final job = TabAgentState.fromState({
      'collections': [row('old', 'paused'), row('live', 'running')]
    }, 'tab-a')!;
    expect(job.collectionId, 'live');
    expect(job.label, 'Agent working');
  });
  testWidgets(
      'compact tab controls pause and stop without selecting another tab',
      (tester) async {
    var pauses = 0, stops = 0, opens = 0;
    final job = TabAgentState.fromState({
      'collections': [row('live', 'running')]
    }, 'tab-a')!;
    await tester.pumpWidget(ShadcnApp(
        home: Center(
            child: SizedBox(
                width: 320,
                child: AgentTabStatusBar(
                    job: job,
                    onPause: () => pauses++,
                    onStop: () => stops++,
                    onOpen: () => opens++)))));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('tab-agent-pause-live')));
    await tester.tap(find.byKey(const ValueKey('tab-agent-stop-live')));
    await tester.tap(find.byKey(const ValueKey('tab-agent-details-live')));
    expect([pauses, stops, opens], [1, 1, 1]);
  });
  testWidgets('tab badge supports keyboard activation', (tester) async {
    var opens = 0;
    final job = TabAgentState.fromState({
      'collections': [row('live', 'running')]
    }, 'tab-a')!;
    await tester.pumpWidget(ShadcnApp(
        home: Center(
            child: TabAgentBadge(
                job: job,
                onPause: () {},
                onStop: () {},
                onOpen: () => opens++))));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opens, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('tab status stays readable across shell widths', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final capture = GlobalKey();
    final running = TabAgentState.fromState({
      'collections': [row('live', 'running')]
    }, 'tab-a')!;
    final paused = TabAgentState.fromState({
      'collections': [row('review', 'paused')]
    }, 'tab-a')!;
    for (final width in [320.0, 768.0, 1024.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 180);
      await tester.pumpWidget(ShadcnApp(
        debugShowCheckedModeBanner: false,
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: RepaintBoundary(
            key: capture,
            child: Scaffold(
              child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(children: [
                    Row(children: [
                      const Text('Bookmarks'),
                      TabAgentBadge(
                          job: running,
                          onPause: () {},
                          onStop: () {},
                          onOpen: () {}),
                      const Expanded(
                          child: Text('Browsing another tab',
                              textAlign: TextAlign.end,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis))
                    ]),
                    const SizedBox(height: 12),
                    AgentTabStatusBar(
                        job: running,
                        onPause: () {},
                        onStop: () {},
                        onOpen: () {}),
                    const SizedBox(height: 8),
                    AgentTabStatusBar(
                        job: paused,
                        onPause: () {},
                        onStop: () {},
                        onOpen: () {}),
                  ])),
            )),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width=$width');
      if (width == 320 || width == 1024) {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file =
              File('build/test-artifacts/tab-agent-${width.toInt()}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
  });
}
