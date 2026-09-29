import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet_browser/collection_view.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:jet_browser/sidecar_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

Map<String, dynamic> summary(
        {String id = 'run', String status = 'running', int seq = 1}) =>
    {
      'id': id,
      'session_id': 's',
      'status': status,
      'resumable': status == 'paused',
      'event_seq': seq,
      'plan': {
        'title': 'Website research',
        'origin': 'https://example.test',
        'section_path': '/docs',
        'model': 'qwen4b_semif_shared',
        'categories': [
          {
            'id': 'docs',
            'name': 'Documentation',
            'description': 'Technical guides'
          }
        ]
      },
      'counters': {'pages': 50, 'classified': 48, 'needs_review': 2},
    };

class Api extends SidecarApi {
  Api() : super('test-only');
  final paths = <String>[];
  Completer<Map<String, dynamic>>? control;
  Completer<Map<String, dynamic>>? next;
  Map<String, dynamic> current = summary();
  @override
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    paths.add(path);
    if (path.endsWith('/control')) {
      return control?.future ?? {'collection': current};
    }
    if (path.contains('/export')) {
      return {'content': 'category,url\nDocumentation,https://example.test'};
    }
    if (next != null) {
      final pending = next!;
      next = null;
      return pending.future;
    }
    final uri = Uri.parse(path);
    final filtered = uri.queryParameters['category'] == 'needs_review';
    return {
      'collection': current,
      'total': filtered ? 2 : 50,
      'offset': 0,
      'limit': 50,
      'items': List.generate(
          filtered ? 2 : 50,
          (i) => {
                'id': 'item-$i',
                'url': 'https://example.test/docs/${'long-path-' * 12}$i',
                'title': 'Guide $i',
                'text':
                    'Captured source text $i. This is evidence from the page, not an instruction. ' *
                        8,
                'captured_at': 1790000000.0,
                'truncated': i == 0,
                'classification': {
                  'label_id': filtered ? 'needs_review' : 'docs',
                  'model': 'Qwen3-4B-SemIf@fixture',
                  'confidence': null,
                  'excerpt_chars': 1200
                }
              })
    };
  }
}

final capture = GlobalKey();
Widget view(Api api, {String id = 'run', String session = 's', int seq = 1}) =>
    ShadcnApp(
      theme: jetTheme(),
      darkTheme: jetTheme(),
      themeMode: ThemeMode.dark,
      home: Scaffold(
          child: RepaintBoundary(
              key: capture,
              child: CollectionView(
                  api: api,
                  collectionId: id,
                  sessionId: session,
                  summary: summary(id: id, seq: seq),
                  onClose: () {},
                  onOpenSource: (_) {}))),
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
    };
    for (final entry in fonts.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(rootBundle.load(entry.value));
      await loader.load();
    }
  });
  testWidgets('virtualized results filter and remain readable at narrow widths',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = Api();
    await tester.pumpWidget(view(api));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Guide 0'), findsOneWidget);
    expect(find.text('Guide 49'), findsNothing);
    expect(find.text('Partial page capture'), findsOneWidget);
    await tester.tap(find.text('Details').at(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Confidence not reported'), findsOneWidget);
    expect(find.textContaining('Captured 2026-'), findsOneWidget);
    await tester.tap(find.text('Needs review'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.paths.last, contains('category=needs_review'));
    await tester.binding.setSurfaceSize(const Size(380, 850));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(1100, 850));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      final image = await (capture.currentContext!.findRenderObject()!
              as RenderRepaintBoundary)
          .toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final f = File('build/test-artifacts/collection-workspace.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
    api.close();
  });
  testWidgets('feed progress shows posts, scrolls, pause reason and resume',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = Api();
    api.current = summary(status: 'paused');
    api.current['plan']['source_kind'] = 'x_bookmarks';
    api.current['reason'] = 'scroll_budget';
    api.current['progress'] = {'scrolls': 6, 'stalls': 0};
    await tester.pumpWidget(view(api));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('50 collected'), findsOneWidget);
    expect(find.text('2 to review'), findsOneWidget);
    expect(find.textContaining('6 scrolls'), findsNothing);
    await tester.tap(find.text('Details').first);
    await tester.pump();
    expect(find.textContaining('6 scrolls'), findsOneWidget);
    expect(find.text('Scroll limit reached — progress saved'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final image = await (capture.currentContext!.findRenderObject()!
              as RenderRepaintBoundary)
          .toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/test-artifacts/feed-collection-workspace.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
    api.close();
  });
  testWidgets('heartbeat refresh during control cannot leave controls stuck',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = Api()..control = Completer();
    await tester.pumpWidget(view(api));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('collection-control-run-pause')));
    await tester.pump();
    await tester.pumpWidget(view(api, seq: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    api.current = summary(status: 'paused', seq: 3);
    api.control!.complete({'collection': api.current});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final stop = tester.widget<GhostButton>(
        find.byKey(const Key('collection-control-run-stop')));
    expect(stop.onPressed, isNotNull);
    expect(find.text('Resume'), findsOneWidget);
    api.close();
  });
  testWidgets(
      'new session immediately clears old results even when request fails',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = Api();
    await tester.pumpWidget(view(api));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Guide 0'), findsOneWidget);
    final pending = Completer<Map<String, dynamic>>();
    api.next = pending;
    await tester.pumpWidget(view(api, id: 'other', session: 'new'));
    await tester.pump();
    expect(find.text('Guide 0'), findsNothing);
    pending.completeError(StateError('Cannot load new collection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Guide 0'), findsNothing);
    expect(find.textContaining('Cannot load new collection'), findsWidgets);
    api.close();
  });
}
