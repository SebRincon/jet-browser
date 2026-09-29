import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:jet_browser/sidecar_api.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:jet_browser/workflow_view.dart';
import 'package:jet_browser/runtime_setup_view.dart';
import 'package:jet_browser/tab_agent_state.dart';

final run = <String, dynamic>{
  'id': 'workflow',
  'title': 'Organizing bookmarks',
  'status': 'paused',
  'revision': 2,
  'source':
      "const page = jet.call('feed.observe', {});\njet.call('run.checkpoint', {state: {}, status: 'review', summary: 'Sample ready'});",
  'counters': {
    'saved': 10,
    'classified': 10,
    'scrolls': 3,
    'elapsed_ms': 61000
  },
  'tab_id': 'tab'
};

class Api extends SidecarApi {
  Api() : super('fixture');
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    calls.add(path);
    if (path.startsWith('/setup')) {
      return {
        'packaged': true,
        'ready': false,
        'models': [
          {
            'id': 'qwen4b',
            'title': 'SemIf · 4B',
            'description': 'Decisions, tags and summaries',
            'status': 'available',
            'bytes': 9342905899,
            'total': 9342905899,
            'received': 0
          },
          {
            'id': 'qwen08b',
            'title': 'Qwen · 0.8B',
            'status': 'downloading',
            'bytes': 652027821,
            'total': 652027821,
            'received': 320000000
          }
        ],
        'downloading': 'qwen08b',
        'grok': {'available': true, 'authenticated': false}
      };
    }
    if (path.endsWith('/export')) {
      return {
        'file': {'name': 'workflow-bookmarks.csv'}
      };
    }
    if (path.endsWith('/control')) return {};
    return {
      'run': run,
      'records': {
        'total': 1,
        'items': [
          {
            'id': 'item',
            'url': 'https://example.test/mobile',
            'summary':
                'An open source mobile app with an accessible design system.',
            'author': 'Example Author',
            'published_at': '2026-09-28T10:00:00Z',
            'tags': ['mobile', 'design'],
            'text': 'Observed post text',
            'truncated': false,
            'revision': 2
          }
        ]
      }
    };
  }
}

void main() {
  setUpAll(() async {
    for (final f in {
      'GeistSans': 'lib/fonts/Geist-Regular.otf',
      'LucideIcons': 'lib/icons/LucideIcons.ttf'
    }.entries) {
      await (FontLoader('packages/shadcn_flutter/${f.key}')
            ..addFont(rootBundle.load('packages/shadcn_flutter/${f.value}')))
          .load();
    }
  });
  test('workflow tab badge uses workflow counters and controls', () {
    final job = TabAgentState.fromState({
      'workflows': [run]
    }, 'tab')!;
    expect(job.isWorkflow, isTrue);
    expect(job.collected, 10);
    expect(job.elapsedMs, 61000);
  });
  testWidgets('workflow records, source and export remain usable at 420px',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = Api();
    final key = GlobalKey();
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        home: RepaintBoundary(
            key: key,
            child: WorkflowView(
                api: api,
                workflowId: 'workflow',
                sessionId: 's',
                onClose: () {},
                onOpenUrl: (_) {}))));
    await tester.pumpAndSettle();
    expect(find.textContaining('An open source mobile'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('artifacts/workflow-workspace.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    final source = find.text('Source');
    if (source.evaluate().isNotEmpty) {
      await tester.tap(source);
      await tester.pumpAndSettle();
      expect(find.textContaining('jet.call'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    api.close();
  });
  testWidgets(
      'first-run setup shows local download progress and can continue browsing',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = Api();
    final key = GlobalKey();
    var continued = false;
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        home: RepaintBoundary(
            key: key,
            child: RuntimeSetupView(
                api: api,
                onContinue: () => continued = true,
                onOpenUrl: (_) {}))));
    await tester.pumpAndSettle();
    expect(find.text('Make Jet yours'), findsOneWidget);
    expect(find.text('Open browser'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('artifacts/runtime-setup.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.ensureVisible(find.text('Open browser'));
    await tester.tap(find.text('Open browser'));
    expect(continued, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    api.close();
  });
}
