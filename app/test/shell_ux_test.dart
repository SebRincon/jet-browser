import 'dart:async';

import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet_browser/agent_pane.dart';
import 'package:jet_browser/browser_host.dart';
import 'package:jet_browser/jet_theme.dart';
import 'package:jet_browser/main.dart';
import 'package:jet_browser/shell_chrome.dart';
import 'package:jet_browser/shell_shortcuts.dart';
import 'package:jet_browser/sidecar_api.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:vten_chat/vten_chat.dart';

class ShellApi extends SidecarApi {
  ShellApi() : super('test-only');
  final calls = <Map<String, dynamic>>[];
  Map<String, dynamic> state = {
    'session': {'id': 's', 'title': 'Empty'},
    'sessions': [
      {'id': 's', 'title': 'Empty'},
      {'id': 'ada', 'title': 'Ada Lovelace notes'},
    ],
    'provider': {'status': 'ready'},
    'messages': [],
  };
  @override
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    calls.add({'path': path, 'body': body});
    if (path == '/state') return state;
    if (path == '/chat') throw StateError('send failed');
    return {};
  }
}

class _HoldingTabHost extends ShellHost {
  _HoldingTabHost(super.api);
  final openGate = Completer<void>();
  @override
  Future<String> openTab(String url, {bool background = false}) async {
    opened += 1;
    await openGate.future;
    return 'tab-$opened';
  }
}

class ShellHost extends BrowserHost {
  ShellHost(ShellApi api) : super('/test', api);
  int opened = 0;
  int reloads = 0;
  int blurs = 0;
  bool loading = false;
  @override
  Future<void> initialize() async {
    ready = true;
  }

  @override
  Future<String> openTab(String url, {bool background = false}) async {
    opened += 1;
    return 'tab-$opened';
  }

  @override
  Future<void> reloadActive() async {
    reloads += 1;
  }

  @override
  bool get pageLoading => loading;

  @override
  Future<void> blurBrowser() async {
    blurs += 1;
  }
}

Widget app(BrowserHost host) => ShadcnApp(
    theme: jetTheme(),
    darkTheme: jetTheme(),
    themeMode: ThemeMode.dark,
    home: BrowserShell(host: host));

void main() {
  test('chat width stays inside the window', () {
    expect(clampChatWidth(480, 1440), 480);
    expect(clampChatWidth(480, 1024), 480);
    expect(clampChatWidth(900, 800), 800 - 6 - 320);
    expect(clampChatWidth(900, 800), greaterThanOrEqualTo(280));
    expect(clampChatWidth(400, 200), 0);
    expect(clampChatWidth(-20, 1440), 280);
  });

  testWidgets('native semantics can detach and rebuild a complete shell tree',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final dispatcher = tester.binding.platformDispatcher;
    addTearDown(dispatcher.clearSemanticsEnabledTestValue);
    dispatcher.semanticsEnabledTestValue = false;
    final api = ShellApi();
    final host = ShellHost(api)
      ..connected = true
      ..state = api.state;
    await tester.pumpWidget(app(host));
    await tester.pump();
    expect(tester.binding.semanticsEnabled, isFalse);
    for (var attempt = 0; attempt < 2; attempt++) {
      dispatcher.semanticsEnabledTestValue = true;
      await tester.pump();
      expect(tester.binding.semanticsEnabled, isTrue);
      expect(tester.getSemantics(find.text('Where do you want to go?')).label,
          contains('Where do you want to go?'));
      dispatcher.semanticsEnabledTestValue = false;
      await tester.pump();
      expect(tester.binding.semanticsEnabled, isFalse);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }, semanticsEnabled: false);

  testWidgets('resize, collapse, and shortcuts keep one chat', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = ShellApi();
    final host = ShellHost(api)
      ..connected = true
      ..state = api.state;
    await tester.pumpWidget(app(host));
    await tester.pump();
    expect(find.text('Local first · Grok when needed'), findsOneWidget);
    expect(find.text('Where do you want to go?'), findsOneWidget);
    expect(find.byType(MessageList), findsOneWidget);
    SizedBox slot() =>
        tester.widget<SizedBox>(find.byKey(const ValueKey('chat-slot')));
    final wide = slot().width!;
    await tester.drag(
        find.byKey(const ValueKey('chat-resize')), const Offset(80, 0));
    await tester.pump();
    expect(slot().width!, lessThan(wide));
    expect(slot().width!, greaterThanOrEqualTo(280));
    Focus.of(tester.element(find.byKey(const ValueKey('chat-resize'))))
        .requestFocus();
    await tester.pump();
    expect(find.byKey(const ValueKey('chat-resize-focused')), findsOneWidget);
    final focusedWidth = slot().width!;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    final widened = slot().width!;
    expect(widened, greaterThan(focusedWidth));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(slot().width!, lessThan(widened));
    expect(slot().width!, greaterThanOrEqualTo(280));

    final field = find.byKey(const ValueKey('chat-composer'));
    await tester.enterText(field, 'Keep this draft');
    await tester.pump();
    await tester.tap(field);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-visibility')));
    await tester.pump();
    final offstage =
        tester.widget<Offstage>(find.byKey(const ValueKey('chat-offstage')));
    expect(offstage.offstage, isTrue);
    expect(find.byType(AgentPane, skipOffstage: false), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(
        tester
            .widget<material.TextField>(find
                .byKey(const ValueKey('chat-composer'), skipOffstage: false))
            .controller!
            .text,
        'Keep this draft');
    await tester.tap(find.byKey(const ValueKey('chat-visibility')));
    await tester.pump();
    expect(tester.widget<material.TextField>(field).controller!.text,
        'Keep this draft');

    await tester.enterText(
        find.byKey(const ValueKey('address-field')), 'https://example.com/ada');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    final address = tester
        .widget<TextField>(find.byKey(const ValueKey('address-field')))
        .controller!;
    expect(address.selection.baseOffset, 0);
    expect(address.selection.extentOffset, address.text.length);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(host.opened, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(host.reloads, 1);
    expect(api.calls, isEmpty);

    host.loading = true;
    host.notifyListeners();
    await tester.pump();
    expect(find.byKey(const ValueKey('page-loading')), findsOneWidget);

    for (final size in const [
      Size(800, 700),
      Size(1024, 640),
      Size(1440, 220),
      Size(240, 180),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(slot().width!, greaterThanOrEqualTo(0));
    }
    expect(find.text('Local first · Grok when needed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('collapse keeps the transcript scroll position', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = ShellApi()
      ..state = {
        'session': {'id': 's', 'title': 'Long'},
        'provider': {'status': 'ready'},
        'messages': [
          for (var index = 0; index < 16; index++)
            {
              'id': 'm$index',
              'created_at': index,
              'role': 'assistant',
              'source': 'local',
              'text': 'Saved line $index about the open page.',
            }
        ],
      };
    final host = ShellHost(api)
      ..connected = true
      ..state = api.state;
    await tester.pumpWidget(app(host));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final scroll = tester.state<ScrollableState>(find.descendant(
        of: find.byKey(MessageList.scrollViewKey),
        matching: find.byType(Scrollable)));
    await tester.drag(
        find.byKey(MessageList.scrollViewKey), const Offset(0, 360));
    await tester.pump();
    final remembered = scroll.position.pixels;
    expect(remembered, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('chat-visibility')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-visibility')));
    await tester.pump();
    expect(scroll.position.pixels, closeTo(remembered, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('suggestions prefill and history filtering keeps drafts',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = ShellApi();
    final host = ShellHost(api)
      ..connected = true
      ..state = api.state;
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: SizedBox(width: 420, child: AgentPane(host: host)))));
    await tester.pumpAndSettle();
    expect(find.text('Open YouTube'), findsOneWidget);
    await tester.tap(find.text('Open YouTube'));
    await tester.pump();
    expect(
        tester
            .widget<material.TextField>(
                find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        'Open YouTube');
    expect(api.calls, isEmpty);
    await tester.enterText(
        find.byKey(const ValueKey('chat-composer')), 'unsent note');
    await tester.pump();
    expect(find.text('Open YouTube'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat-history')));
    await tester.pump();
    expect(
        tester
            .widget<material.TextField>(
                find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        'unsent note');
    expect(api.calls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('history-search')));
    await tester.pump();
    expect(host.blurs, greaterThan(0));

    host.state = {
      ...api.state,
      'messages': [
        {'id': 'u', 'created_at': 1, 'role': 'user', 'text': 'Hello'}
      ],
    };
    host.notifyListeners();
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: SizedBox(width: 420, child: AgentPane(host: host)))));
    await tester.pump();
    expect(find.text('Where do you want to go?'), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('chat-composer')), 'still here');
    if (find.text('Chat history').evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('chat-history')));
      await tester.pump();
    }
    expect(find.text('Chat history'), findsOneWidget);
    expect(find.byKey(const ValueKey('history-empty')), findsNothing);
    final search =
        tester.widget<TextField>(find.byKey(const ValueKey('history-search')));
    search.controller!.text = 'zzz';
    search.onChanged!.call('zzz');
    await tester.pump();
    expect(find.byKey(const ValueKey('history-no-results')), findsOneWidget);
    search.controller!.text = 'Ada';
    search.onChanged!.call('Ada');
    await tester.pump();
    expect(find.byKey(const ValueKey('session-ada')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-s')), findsNothing);
    expect(
        tester
            .widget<material.TextField>(
                find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        'still here');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });

  testWidgets('authoritative busy, stop, and honest route timing',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = ShellApi()
      ..state = {
        'busy': true,
        'session': {'id': 's', 'title': 'Work'},
        'sessions': [
          {'id': 's', 'title': 'Work'},
          {'id': 'other', 'title': 'Other'},
        ],
        'provider': {'status': 'ready'},
        'messages': [
          {'id': 'u', 'created_at': 1, 'role': 'user', 'text': 'Open Wikipedia'}
        ],
        'routes': [
          {
            'id': 'live',
            'created_at': 2,
            'decision': 'local',
            'status': 'running',
            'elapsed_ms': 12,
            'total_ms': 1800,
            'plan': {
              'navigation_goal': {
                'kind': 'article',
                'provider': 'wikipedia',
                'query': 'Ada Lovelace',
              }
            },
            'outcome': {
              'status': 'running',
              'reason': 'continue',
              'kind': 'assessment'
            },
          }
        ],
      };
    final host = ShellHost(api)
      ..connected = true
      ..state = api.state;
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: SizedBox(width: 420, child: AgentPane(host: host)))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Checking the destination'), findsOneWidget);
    expect(
        find.textContaining('Open the Wikipedia article for Ada Lovelace',
            findRichText: true),
        findsOneWidget);
    expect(find.textContaining('1.80 s', findRichText: true), findsOneWidget);
    expect(find.textContaining('12 ms', findRichText: true), findsNothing);
    await tester.enterText(
        find.byKey(const ValueKey('chat-composer')), 'again');
    expect(find.byKey(const ValueKey('chat-send')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(api.calls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('new-chat')));
    await tester.pump();
    expect(api.calls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('chat-stop')));
    await tester.pump();
    expect(api.calls.single['path'], '/chat/stop');
    expect(
        tester
            .widget<material.TextField>(
                find.byKey(const ValueKey('chat-composer')))
            .controller!
            .text,
        'again');

    host.state = {
      'busy': false,
      'session': {'id': 's', 'title': 'Work'},
      'provider': {'status': 'ready'},
      'messages': [
        {'id': 'u', 'created_at': 1, 'role': 'user', 'text': 'Open Wikipedia'}
      ],
      'routes': [
        {
          'id': 'stopped',
          'created_at': 2,
          'decision': 'local',
          'status': 'cancelled',
          'elapsed_ms': 40,
          'plan': {
            'navigation_goal': {
              'kind': 'homepage',
              'provider': 'youtube',
            }
          },
          'outcome': {'status': 'stopped', 'reason': 'user', 'kind': 'proof'},
        }
      ],
    };
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: SizedBox(width: 420, child: AgentPane(host: host)))));
    await tester.pump();
    expect(find.textContaining('Stopped', findRichText: true), findsWidgets);
    expect(find.textContaining('verified'), findsNothing);
    await tester.tap(find.textContaining('Stopped', findRichText: true).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('URL and visible page matched'), findsNothing);
    expect(find.textContaining('Direct navigation'), findsOneWidget);
    expect(find.textContaining('Outcome · stopped · user'), findsOneWidget);
    expect(find.textContaining('Goal · homepage · youtube'), findsOneWidget);
    expect(find.textContaining('independent verification'), findsNothing);

    host.state = {
      'busy': true,
      'provider': {'status': 'routing'},
      'trace': {'turn_id': 'turn-2'},
      'messages': [
        {
          'id': 'u2',
          'created_at': 3,
          'role': 'user',
          'turn_id': 'turn-2',
          'text': 'Now research this'
        }
      ],
      'routes': [
        {
          'id': 'old',
          'created_at': 1,
          'turn_id': 'turn-1',
          'decision': 'local',
          'status': 'running',
          'outcome': {'status': 'running', 'reason': 'continue'},
        }
      ],
    };
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: SizedBox(width: 420, child: AgentPane(host: host)))));
    await tester.pump();
    expect(find.text('Choosing an action'), findsOneWidget);
    expect(find.text('Checking the destination'), findsNothing);

    host.state = {
      'busy': true,
      'provider': {'status': 'ready'},
      'trace': {'turn_id': 'turn-3'},
      'task': {'id': 'task-new', 'status': 'running'},
      'messages': [
        {
          'id': 'u3',
          'created_at': 4,
          'role': 'user',
          'turn_id': 'turn-3',
          'text': 'Fill the form'
        }
      ],
      'routes': [
        {
          'id': 'old-done',
          'created_at': 1,
          'turn_id': 'turn-1',
          'decision': 'local',
          'status': 'done',
          'outcome': {'status': 'done', 'reason': 'continue', 'kind': 'proof'},
        }
      ],
    };
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: SizedBox(width: 420, child: AgentPane(host: host)))));
    await tester.pump();
    expect(find.text('Opening a page'), findsOneWidget);
    expect(find.text('Checking the destination'), findsNothing);

    host.state = {
      'busy': false,
      'provider': {'status': 'ready'},
      'messages': [
        {'id': 'home', 'created_at': 1, 'role': 'user', 'text': 'Open YouTube'}
      ],
      'routes': [
        {
          'id': 'home-route',
          'created_at': 2,
          'decision': 'local',
          'status': 'done',
          'model': 'qwen4b_semif_shared',
          'plan': {
            'navigation_goal': {'kind': 'homepage', 'provider': 'youtube'}
          },
          'outcome': {'status': 'done', 'kind': 'proof', 'reason': 'matched'},
        }
      ],
    };
    await tester.pumpWidget(ShadcnApp(
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: Scaffold(
            child: SizedBox(width: 420, child: AgentPane(host: host)))));
    await tester.pump();
    await tester.tap(find.text('1 step'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.textContaining('Open YouTube', findRichText: true).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Direct navigation'), findsOneWidget);
    expect(find.textContaining('SemIf'), findsNothing);
    expect(find.textContaining('URL and visible page matched the destination.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    host.dispose();
  });

  testWidgets('native shortcut channel maps once and does not repeat tabs',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final host = _HoldingTabHost(ShellApi())..connected = true;
    await tester.pumpWidget(app(host));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('address-field')), 'https://example.com/ada');
    await tester.pump();

    final codec = const StandardMethodCodec();
    Future<ByteData?> send(String action) {
      return tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        shellShortcutChannel.name,
        codec.encodeMethodCall(MethodCall('shortcut', action)),
        (_) {},
      );
    }

    await send(shellShortcutSelectAddress);
    await send(shellShortcutSelectAddress);
    await tester.pump();
    final address = tester
        .widget<TextField>(find.byKey(const ValueKey('address-field')))
        .controller!;
    expect(address.selection.baseOffset, 0);
    expect(address.selection.extentOffset, address.text.length);
    expect(host.blurs, 1);

    final first = send(shellShortcutNewTab);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await send(shellShortcutNewTab);
    expect(host.opened, 1);
    host.openGate.complete();
    await first;
    await tester.pump();
    expect(host.opened, 1);

    await send(shellShortcutReload);
    await tester.pump();
    expect(host.reloads, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
