import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cef_browser/flutter_cef_browser.dart';
import 'package:jet_browser/native_bridge.dart';
import 'package:jet_browser/browser_host.dart';
import 'package:jet_browser/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jet-test-browser');
  final calls = <MethodCall>[];
  late CefBrowserController controller;
  final bridge = NativeBridge();
  setUp(() {
    calls.clear();
    controller = CefBrowserController(browserId: 42, channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'evaluateJavaScript') {
        return jsonEncode({
          'type': 'object',
          'value': {'count': 7, 'checked': false}
        });
      }
      if (call.method == 'captureViewportScreenshot') return 'image-data';
      return null;
    });
  });
  tearDown(() => controller.dispose());

  test(
      'private evaluation preserves JSON value and awaits asynchronous expression',
      () async {
    final result = await bridge.execute(controller, 'Runtime.evaluate',
        {'expression': 'Promise.resolve({count: 7, checked: false})'});
    expect(result['result']['value'], {'count': 7, 'checked': false});
    expect(calls.single.arguments['expression'],
        contains('const value = await (Promise.resolve'));
    expect(calls.single.arguments['id'], 42);
  });

  test('pointer input preserves exact CSS coordinates and protocol modifiers',
      () async {
    final params = {
      'type': 'mousePressed',
      'x': 102.5,
      'y': 51,
      'button': 'left',
      'modifiers': 5
    };
    await bridge.execute(controller, 'Input.dispatchMouseEvent', params);
    expect(calls.single.method, 'dispatchInput');
    expect(calls.single.arguments,
        {'id': 42, 'method': 'Input.dispatchMouseEvent', 'params': params});
    await bridge.execute(controller, 'Input.dispatchMouseEvent',
        {'type': 'mouseWheel', 'x': 10, 'y': 20, 'deltaY': 300});
    expect(calls.last.arguments['params']['deltaY'], 300);
  });

  test('Unicode text and native screenshot remain in process', () async {
    await bridge.execute(controller, 'Input.insertText', {'text': 'Maya 林'});
    expect(calls.single.arguments, {
      'id': 42,
      'method': 'Input.insertText',
      'params': {'text': 'Maya 林'}
    });
    expect(await bridge.execute(controller, 'Page.captureScreenshot', {}),
        {'data': 'image-data'});
  });

  test('selection commands preserve Chromium semantics without focus reset',
      () async {
    final params = {
      'type': 'keyDown',
      'key': 'a',
      'modifiers': 4,
      'commands': ['selectAll']
    };
    await bridge.execute(controller, 'Input.dispatchKeyEvent', params);
    expect(calls.map((call) => call.method), ['dispatchInput']);
    expect(calls.single.arguments['params'], params);
  });

  test('unsupported bridge and native input operations fail without dispatch',
      () async {
    await expectLater(bridge.execute(controller, 'Browser.runShell', {}),
        throwsUnsupportedError);
    await expectLater(
        controller.dispatchInput('Runtime.evaluate', {}), throwsArgumentError);
    expect(calls, isEmpty);
  });

  test('URL entry supports domains, loopback and explicit search', () {
    expect(navigationUrl('example.com'), 'https://example.com');
    expect(navigationUrl('127.0.0.1:9148/fixture'),
        'http://127.0.0.1:9148/fixture');
    expect(navigationUrl('hello world'),
        'https://www.google.com/search?q=hello+world');
    expect(navigationUrl('javascript:alert(1)'),
        startsWith('https://www.google.com/search?'));
    expect(() => navigationUrl(' '), throwsArgumentError);
  });

  testWidgets('missing installation state gives actionable startup error',
      (tester) async {
    await tester.pumpWidget(const JetApp(startupError: 'Run scripts/start.sh'));
    expect(find.text('Run scripts/start.sh'), findsOneWidget);
  });
}
