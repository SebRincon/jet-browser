import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:jet_browser/sidecar_api.dart';
import 'package:jet_browser/workspace_view.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

const rows = <Map<String, dynamic>>[
  {
    'id': 'first',
    'name': 'Bookmarks report.md',
    'area': 'artifacts',
    'size': 128,
    'created_at': 1790000000,
    'media_type': 'text/markdown'
  },
  {
    'id': 'second',
    'name': 'Notes.txt',
    'area': 'scratch',
    'size': 20,
    'created_at': 1790000001,
    'media_type': 'text/plain'
  },
];

class WorkspaceApi extends SidecarApi {
  WorkspaceApi() : super('test-only');
  final calls = <String>[];
  Completer<Map<String, dynamic>>? pending;
  bool fail = false;
  @override
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    calls.add(path);
    if (path.endsWith('/preview')) {
      return {'url': '/artifacts/view/test-capability'};
    }
    if (fail) throw StateError('Temporary connection problem');
    if (pending != null) {
      final p = pending!;
      pending = null;
      return p.future;
    }
    final first = path.contains('first');
    return {
      'file': rows[first ? 0 : 1],
      'content': first
          ? '# Bookmarks report\n\nYour saved posts are organized locally.'
          : 'Scratch note',
      'next_offset': null
    };
  }
}

final capture = GlobalKey();
Widget view(WorkspaceApi api,
        {String session = 'a',
        bool canOpen = true,
        List<Map<String, dynamic>> files = rows,
        ValueChanged<String>? onOpen}) =>
    ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: RepaintBoundary(
                key: capture,
                child: WorkspaceView(
                    api: api,
                    sessionId: session,
                    files: files,
                    onClose: () {},
                    onOpenBrowser: onOpen ?? (_) {},
                    canOpenBrowser: canOpen))));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in {
      'packages/shadcn_flutter/GeistSans':
          'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
      'packages/shadcn_flutter/LucideIcons':
          'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
    }.entries) {
      final loader = FontLoader(entry.key)
        ..addFont(rootBundle.load(entry.value));
      await loader.load();
    }
  });
  testWidgets(
      'workspace is readable at narrow widths and browser opening is explicit',
      (t) async {
    final api = WorkspaceApi();
    final opened = <String>[];
    t.view.physicalSize = const Size(560, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(view(api, onOpen: opened.add));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('workspace-file-first')));
    await t.pumpAndSettle();
    expect(find.textContaining('Your saved posts are organized locally.'),
        findsOneWidget);
    expect(opened, isEmpty);
    await t.tap(find.byKey(const Key('workspace-open-browser')));
    await t.pumpAndSettle();
    expect(opened, ['http://127.0.0.1:9148/artifacts/view/test-capability']);
    expect(t.takeException(), isNull);
    final b =
        capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await t.runAsync(() async {
      final im = await b.toImage(pixelRatio: 1);
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      final f = File('build/test-artifacts/agent-workspace.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes!.buffer.asUint8List());
      im.dispose();
    });
  });
  testWidgets(
      'background browser owner does not block reading but fences new tabs',
      (t) async {
    final api = WorkspaceApi();
    final opened = <String>[];
    await t.pumpWidget(view(api, canOpen: false, onOpen: opened.add));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('workspace-file-first')));
    await t.pumpAndSettle();
    expect(find.textContaining('Your saved posts'), findsOneWidget);
    await t.tap(find.byKey(const Key('workspace-open-browser')));
    await t.pumpAndSettle();
    expect(opened, isEmpty);
    expect(api.calls.where((p) => p.endsWith('/preview')), isEmpty);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'late response cannot leak previous session file into new workspace',
      (t) async {
    final api = WorkspaceApi();
    final gate = Completer<Map<String, dynamic>>();
    api.pending = gate;
    await t.pumpWidget(view(api));
    await t.pump();
    // Some implementations auto-select the first file; otherwise explicitly select it.
    if (api.calls.isEmpty) {
      await t.tap(find.byKey(const Key('workspace-file-first')));
      await t.pump();
    }
    await t.pumpWidget(view(api, session: 'b', files: const []));
    await t.pump();
    gate.complete({
      'file': rows[0],
      'content': 'OLD SESSION PRIVATE TEXT',
      'next_offset': null
    });
    await t.pumpAndSettle();
    expect(find.textContaining('OLD SESSION PRIVATE TEXT'), findsNothing);
    expect(find.byKey(const Key('workspace-file-first')), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets('workspace file failures offer retry', (t) async {
    final api = WorkspaceApi()..fail = true;
    await t.pumpWidget(view(api));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('workspace-file-first')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('workspace-retry')), findsOneWidget);
    api.fail = false;
    await t.tap(find.byKey(const Key('workspace-retry')));
    await t.pumpAndSettle();
    expect(find.textContaining('Your saved posts'), findsOneWidget);
  });
}
