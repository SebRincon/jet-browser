import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet_browser/collection_review.dart';
import 'package:jet_browser/collection_view.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

Map<String, dynamic> packet({String status = 'awaiting_user'}) => {
      'pending': {
        'id': 'review-1',
        'status': status,
        'reason': 'first_batch',
        'summary':
            'Most posts fit. Two design posts may need a separate category.',
        'question': 'Keep these categories, or add Design?',
        'suggested_categories': [
          {
            'id': 'design',
            'name': 'Design',
            'description': 'Design and typography'
          }
        ]
      },
      'mode': 'checkpoints',
      'interval_seconds': 600,
      'fields': ['url', 'text', 'author', 'published_at'],
      'counts': {'technology': 6, 'science': 2, 'needs_review': 2},
      'categories': [
        {'id': 'technology', 'name': 'Technology'},
        {'id': 'science', 'name': 'Science'}
      ],
      'coverage': {'author': 9, 'published_at': 8},
      'counters': {
        'pages': 10,
        'classified': 8,
        'needs_review': 2,
        'elapsed_ms': 125000
      },
      'samples': [
        {
          'text': 'A new approach to type and layout on the web.',
          'category': 'needs_review',
          'author': 'Alex Kim',
          'published_at': '2026-09-28',
          'url': 'https://example.test/posts/1'
        },
        {
          'text': 'Open models can make browser workflows faster.',
          'category': 'technology',
          'author': 'Sam Lee',
          'published_at': '2026-09-27',
          'url': 'https://example.test/posts/2'
        },
        {
          'text': 'Research notes from the latest telescope observations.',
          'category': 'science',
          'author': null,
          'published_at': null,
          'url': 'https://example.test/posts/3'
        },
      ],
    };

void main() {
  final capture = GlobalKey();
  Widget wrap(Widget child) => ShadcnApp(
      theme: jetTheme(),
      darkTheme: jetTheme(),
      themeMode: ThemeMode.dark,
      home: Scaffold(
          child: RepaintBoundary(
              key: capture,
              child: SingleChildScrollView(
                  child: Padding(
                      padding: const EdgeInsets.all(16), child: child)))));
  setUpAll(() async {
    final f = FontLoader('packages/shadcn_flutter/GeistSans')
      ..addFont(rootBundle
          .load('packages/shadcn_flutter/lib/fonts/Geist-Regular.otf'));
    await f.load();
  });
  test('elapsed and approval payload retain exact checkpoint', () {
    expect(formatCollectionElapsed(125000), '2:05');
    expect(formatCollectionElapsed(3725000), '1:02:05');
    expect(formatCollectionElapsed(double.nan), '0:00');
    expect(collectionControlBody('approve_continuous:review-1'),
        {'action': 'approve_continuous', 'review_id': 'review-1'});
    expect(collectionControlBody('pause'), {'action': 'pause'});
  });
  testWidgets(
      'review has observed sample coverage and explicit continuation at 320px',
      (t) async {
    t.view.physicalSize = const Size(320, 850);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final actions = <String>[];
    await t.pumpWidget(
        wrap(CollectionReviewPanel(packet: packet(), onControl: actions.add)));
    await t.pumpAndSettle();
    expect(find.text('A quick check-in'), findsOneWidget);
    expect(find.text('Author 9/10 · Post date 8/10'), findsOneWidget);
    expect(find.text('Not observed'), findsNWidgets(2));
    expect(find.text('Suggested: Design'), findsOneWidget);
    await t.ensureVisible(find.byKey(const Key('review-continuous')));
    await t.tap(find.byKey(const Key('review-continuous')));
    await t.pump();
    expect(actions, ['approve_continuous:review-1']);
    expect(t.takeException(), isNull);
  });
  testWidgets('reviewing and disabled approvals cannot resume', (t) async {
    final actions = <String>[];
    await t.pumpWidget(wrap(CollectionReviewPanel(
        packet: packet(status: 'reviewing'), onControl: actions.add)));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('review-continuous')), findsNothing);
    await t.pumpWidget(wrap(CollectionReviewPanel(
        packet: packet(), onControl: actions.add, enabled: false)));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('review-checkpoints')));
    await t.pump();
    expect(actions, isEmpty);
    expect(t.takeException(), isNull);
  });
  testWidgets('collection card presents review instead of a bypass resume',
      (t) async {
    t.view.physicalSize = const Size(760, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final p = packet();
    await t.pumpWidget(wrap(CollectionRunCard(collection: {
      'id': 'demo',
      'status': 'paused',
      'reason': 'supervisor_review',
      'resumable': true,
      'plan': {
        'source_kind': 'x_bookmarks',
        'title': 'Bookmarks',
        'model': 'qwen4b_semif_shared'
      },
      'counters': p['counters'],
      'supervision': {'pending': p['pending']},
      'review': p,
    }, onOpen: () {}, onControl: (_) {})));
    await t.pumpAndSettle();
    expect(find.text('10 collected'), findsOneWidget);
    expect(find.text('8 categorized'), findsOneWidget);
    expect(
        find.byKey(const Key('collection-control-demo-resume')), findsNothing);
    expect(t.takeException(), isNull);
    final b =
        capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await t.runAsync(() async {
      final image = await b.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final f = File('build/test-artifacts/supervised-collection.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  });
}
