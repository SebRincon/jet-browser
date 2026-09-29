import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cef_browser/flutter_cef_browser.dart';
import 'package:jet_browser/browser_host.dart';
import 'package:jet_browser/sidecar_api.dart';

class RecordingApi extends SidecarApi {
  RecordingApi() : super('test-only');
  final requests = <Map<String, dynamic>>[];
  Map<String, dynamic> response = {};
  @override
  Future<Map<String, dynamic>> request(String path,
      {Map<String, dynamic>? body}) async {
    requests.add({'path': path, 'body': body});
    return response;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jet-host-test');
  const managerChannel = MethodChannel('com.example/cef_browser');
  late BrowserHost host;
  late RecordingApi api;
  late BrowserTab first;
  late BrowserTab second;
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    api = RecordingApi();
    host = BrowserHost('/test', api);
    first = BrowserTab(CefBrowserController(browserId: 11, channel: channel),
        'https://example.com/first');
    second = BrowserTab(CefBrowserController(browserId: 22, channel: channel),
        'https://example.com/second');
    host.tabs.addAll([first, second]);
    host.active = first;
    for (final value in [channel, managerChannel]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(value, (call) async {
        calls.add(call);
        return null;
      });
    }
  });
  tearDown(() {
    host.dispose();
    first.controller.dispose();
    second.controller.dispose();
  });

  test('first-run setup connects without initializing Chromium', () async {
    api.response = {
      'setup': {'packaged': true, 'ready': false}
    };
    await host.initialize();
    expect(host.connected, isTrue);
    expect(host.ready, isFalse);
    expect(host.startupError, isNull);
    expect(api.requests.single['path'], '/state');
    expect(calls, isEmpty);
  });

  test('collection workspace remains visible when backend selects another tab',
      () async {
    host.setBrowserVisible(false);
    await Future<void>.delayed(Duration.zero);
    calls.clear();
    await host.executeCommand(second.id, 'Browser.selectTab', {});
    final visibility =
        calls.where((call) => call.method == 'setVisible').toList();
    expect(visibility, isNotEmpty);
    expect(
        visibility.every((call) => call.arguments['visible'] == false), isTrue);
    host.setBrowserVisible(true);
    await Future<void>.delayed(Duration.zero);
    expect(
        calls
            .lastWhere((call) => call.method == 'setVisible')
            .arguments['visible'],
        isTrue);
  });

  test('finite history commands dispatch only to the exact active tab',
      () async {
    for (final method in [
      'Browser.back',
      'Browser.forward',
      'Browser.reload'
    ]) {
      expect(await host.executeCommand(first.id, method, {}),
          {'tab_id': first.id, 'active_tab_id': first.id});
    }
    expect(calls.map((call) => call.method), ['goBack', 'goForward', 'reload']);
    expect(calls.every((call) => call.arguments['id'] == 11), isTrue);
    calls.clear();
    await expectLater(
        host.executeCommand(second.id, 'Browser.back', {}), throwsStateError);
    await expectLater(
        host.executeCommand('missing', 'Browser.reload', {}), throwsStateError);
    await expectLater(host.executeCommand(first.id, 'Browser.arbitrary', {}),
        throwsUnsupportedError);
    expect(calls, isEmpty);
  });

  test('select and close preserve observed handles and synchronize inventory',
      () async {
    await host.executeCommand(second.id, 'Browser.selectTab', {});
    expect(host.active, second);
    expect(api.requests.last['body']['active_tab_id'], second.id);
    expect(
        calls
            .where((call) => call.method == 'setViewFrame')
            .single
            .arguments['id'],
        22);
    calls.clear();
    await host.executeCommand(second.id, 'Browser.closeTab', {});
    expect(host.tabs, [first]);
    expect(host.active, first);
    expect(
        calls.where((call) => call.method == 'closeBrowser').single.arguments,
        {'id': 22, 'force': true});
    expect(api.requests.last['body']['tabs'], [first.toJson()]);
    calls.clear();
    await expectLater(host.executeCommand(second.id, 'Browser.selectTab', {}),
        throwsStateError);
    expect(calls, isEmpty);
  });
  test('leased DOM work stays on its background tab without selecting it',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'evaluateJavaScript') {
        return '{"type":"object","value":{"ok":true}}';
      }
      return null;
    });
    await expectLater(
        host.executeCommand(second.id, 'Runtime.evaluate', {'expression': '1'}),
        throwsStateError);
    final result = await host.executeCommand(
        second.id, 'Runtime.evaluate', {'expression': '1'},
        backgroundOwner: 'collection:test');
    expect(result['result']['value']['ok'], true);
    expect(host.active, first);
    expect(calls.single.arguments['id'], 22);
    expect(calls.single.method, 'evaluateJavaScript');
    await expectLater(
        host.executeCommand(second.id, 'Input.insertText', {'text': 'bad'},
            backgroundOwner: 'collection:test'),
        throwsStateError);
    expect(calls.length, 1);
  });
}
