import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_cef_browser/flutter_cef_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('snapshot uses bounded generated JavaScript and normalized nodes',
      () async {
    const channel = MethodChannel('test.cef.automation.snapshot');
    final expressions = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'evaluateJavaScript') return null;
      final expression = (call.arguments as Map)['expression'].toString();
      expressions.add(expression);
      return _snapshotPayload();
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 41, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });

    final snapshot = await broker.snapshot(maxNodes: 10, maxDepth: 8);

    expect(snapshot.nodes, hasLength(1));
    expect(snapshot.nodes.single.role, 'button');
    expect(snapshot.nodes.single.name, 'Continue');
    expect(snapshot.nodes.single.bounds?.centerX, 30);
    expect(expressions.single, contains('const limit=10, depthLimit=8'));
    expect(expressions.single, contains('new TextEncoder()'));
    expect(expressions.single, contains("'one-time-code'"));
    expect(expressions.single, contains("startsWith('cc-')"));
  });

  test('snapshot rejects payloads beyond the UTF-8 transport budget', () async {
    const channel = MethodChannel('test.cef.automation.snapshot-utf8-limit');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'evaluateJavaScript') return null;
      return jsonEncode(<String, Object?>{
        'nodes': const <Object?>[],
        'padding': List<String>.filled(1100000, 'é').join(),
      });
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 409, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });

    await expectLater(
      broker.snapshot(),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_CONTENT_LIMIT',
        ),
      ),
    );
  });

  test('click rejects a node that did not advertise semantic activation',
      () async {
    const channel = MethodChannel('test.cef.automation.click-unsupported');
    final dispatched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        return expression.contains('const limit=')
            ? _snapshotPayload(role: 'generic', actions: const <String>[])
            : _revalidatedTarget(role: 'generic');
      }
      dispatched.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 410, channel: channel);
    var indicatorCalls = 0;
    final broker = _broker(
      controller,
      beforeInput: (_, __) => indicatorCalls += 1,
    );
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    await expectLater(
      broker.click(
        snapshotId: snapshot.snapshotId,
        ref: snapshot.nodes.single.ref,
      ),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_ACTION_UNSUPPORTED',
        ),
      ),
    );
    expect(indicatorCalls, 0);
    expect(dispatched, isEmpty);
  });

  test('press cannot use an incidental mouse click to bypass target risk',
      () async {
    const channel = MethodChannel('test.cef.automation.press-risk');
    final dispatched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        return expression.contains('const limit=')
            ? _snapshotPayload(
                actions: const <String>['press'],
                clickConsequential: true,
                pressConsequential: true,
              )
            : _revalidatedTarget(
                actions: const <String>['press'],
                clickConsequential: true,
                pressConsequential: true,
              );
      }
      dispatched.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 411, channel: channel);
    var indicatorCalls = 0;
    final broker = _broker(
      controller,
      beforeInput: (_, __) => indicatorCalls += 1,
    );
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    await expectLater(
      broker.press(
        snapshotId: snapshot.snapshotId,
        ref: snapshot.nodes.single.ref,
        key: 'Escape',
      ),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_ACTION_CONFIRMATION_REQUIRED',
        ),
      ),
    );
    expect(indicatorCalls, 0);
    expect(dispatched, isEmpty);
  });

  test('press focuses an editable semantically without a mouse activation',
      () async {
    const channel = MethodChannel('test.cef.automation.press-focus');
    final dispatched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        if (expression.contains('const limit=')) {
          return _snapshotPayload(role: 'textbox', editable: true);
        }
        if (expression.contains('try{el.focus')) {
          return jsonEncode(<String, Object?>{'focused': true});
        }
        return _revalidatedTarget(role: 'textbox', editable: true);
      }
      dispatched.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 412, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.press(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
      key: 'Backspace',
    );

    expect(result, containsPair('status', 'completed'));
    expect(dispatched, <String>[
      'setFocus',
      'sendKeyEvent',
      'sendKeyEvent',
    ]);
    expect(dispatched, isNot(contains('sendMouseClick')));
  });

  test('click acknowledges the indicator before dispatching input', () async {
    const channel = MethodChannel('test.cef.automation.click');
    final order = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        return expression.contains('const limit=')
            ? _snapshotPayload()
            : _revalidatedTarget();
      }
      order.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 42, channel: channel);
    final broker = _broker(
      controller,
      beforeInput: (x, y) {
        expect((x, y), (30, 50));
        order.add('indicator');
      },
    );
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.click(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
    );

    expect(result, containsPair('status', 'completed'));
    expect(result, containsPair('dispatchState', 'completed'));
    expect(result, containsPair('resultCode', 'OK'));
    expect(result, containsPair('retryable', false));
    expect(order, <String>[
      'indicator',
      'setFocus',
      'sendMouseMove',
      'sendMouseClick',
      'sendMouseClick',
    ]);
  });

  test('offscreen click scrolls into view and verifies checkbox state',
      () async {
    const channel = MethodChannel('test.cef.automation.click-offscreen');
    final expressions = <String>[];
    final order = <String>[];
    var didScroll = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        expressions.add(expression);
        if (expression.contains('const limit=')) {
          return _snapshotPayload(role: 'checkbox', y: 900);
        }
        if (expression.contains('scrollIntoView')) {
          didScroll = true;
          return _revalidatedTarget(
            role: 'checkbox',
            y: 120,
            viewportChanged: true,
          );
        }
        if (expression.contains('const expectedRole=')) {
          return jsonEncode(<String, Object?>{'activated': true});
        }
        if (expression.contains('const s=')) return 'true';
        return _revalidatedTarget(
          role: 'checkbox',
          y: didScroll ? 120 : 900,
        );
      }
      order.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 423, channel: channel);
    final broker = _broker(
      controller,
      beforeInput: (x, y) {
        expect((x, y), (30, 150));
        order.add('indicator');
      },
    );
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.click(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
    );

    expect(result, containsPair('status', 'completed'));
    expect(result, containsPair('viewportGeneration', 2));
    expect(expressions, anyElement(contains('scrollIntoView')));
    expect(expressions, anyElement(contains('beforeRect')));
    expect(order, <String>[
      'indicator',
      'setFocus',
    ]);
  });

  test('offscreen input waits for the native scroll frame before activation',
      () async {
    const channel = MethodChannel('test.cef.automation.scroll-frame-settle');
    final stopwatch = Stopwatch()..start();
    Duration? scrolledAt;
    var checked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        if (expression.contains('const limit=')) {
          return _snapshotPayload(role: 'checkbox', y: 900);
        }
        if (expression.contains('scrollIntoView')) {
          scrolledAt = stopwatch.elapsed;
          return _revalidatedTarget(
            role: 'checkbox',
            y: 120,
            viewportChanged: true,
          );
        }
        if (expression.contains('const expectedRole=')) {
          final settled = scrolledAt != null &&
              stopwatch.elapsed - scrolledAt! >=
                  const Duration(milliseconds: 40);
          if (settled) checked = true;
          return jsonEncode(<String, Object?>{'activated': settled});
        }
        if (expression.contains('const s=')) return jsonEncode(checked);
        return _revalidatedTarget(role: 'checkbox', y: 120);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 429, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.click(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
    );

    expect(result, containsPair('status', 'completed'));
  });

  test('click reports outcome unknown when checkbox state does not change',
      () async {
    const channel = MethodChannel('test.cef.automation.click-verification');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'evaluateJavaScript') return null;
      final expression = (call.arguments as Map)['expression'].toString();
      if (expression.contains('const limit=')) {
        return _snapshotPayload(role: 'checkbox');
      }
      if (expression.contains('const expectedRole=')) {
        return jsonEncode(<String, Object?>{'activated': true});
      }
      if (expression.contains('const s=')) return 'false';
      return _revalidatedTarget(role: 'checkbox');
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 424, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.click(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
    );

    expect(result, containsPair('status', 'outcomeUnknown'));
    expect(
      result,
      containsPair('resultCode', 'BROWSER_ACTION_OUTCOME_UNKNOWN'),
    );
  });

  test('offscreen contenteditable is scrolled into view before typing',
      () async {
    const channel = MethodChannel('test.cef.automation.type-contenteditable');
    final expressions = <String>[];
    var didScroll = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        expressions.add(expression);
        if (expression.contains('const limit=')) {
          return _snapshotPayload(
            role: 'textbox',
            value: 'before',
            editable: true,
            y: 900,
          );
        }
        if (expression.contains('scrollIntoView')) {
          didScroll = true;
          return _revalidatedTarget(
            role: 'textbox',
            editable: true,
            value: 'before',
            y: 120,
            viewportChanged: true,
          );
        }
        if (expression.contains('clickConsequential')) {
          return _revalidatedTarget(
            role: 'textbox',
            editable: true,
            value: 'before',
            y: didScroll ? 120 : 900,
          );
        }
        if (expression.contains('const replace=')) {
          return jsonEncode(<String, Object?>{'focused': true});
        }
        return jsonEncode(<String, Object?>{'typedValue': 'after'});
      }
      return call.method == 'performEditCommand' ? true : null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 425, channel: channel);
    final broker = _broker(
      controller,
      beforeInput: (x, y) => expect((x, y), (30, 150)),
    );
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.type(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
      text: 'after',
      replace: true,
    );

    expect(result, containsPair('status', 'completed'));
    expect(expressions, anyElement(contains('scrollIntoView')));
  });

  test('type focuses the semantic editable before committing native text',
      () async {
    const channel = MethodChannel('test.cef.automation.type-focus');
    final order = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        if (expression.contains('const limit=')) {
          return _snapshotPayload(role: 'textbox', value: 'before');
        }
        if (expression.contains('clickConsequential')) {
          return _revalidatedTarget(
            role: 'textbox',
            editable: true,
            value: 'before',
          );
        }
        if (expression.contains('const replace=')) {
          return jsonEncode(<String, Object?>{'focused': true});
        }
        return jsonEncode(<String, Object?>{
          'typedValue': 'after navigation',
        });
      }
      order.add(call.method);
      return call.method == 'performEditCommand' ? true : null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 421, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.type(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
      text: 'after navigation',
      replace: true,
    );

    expect(result, containsPair('status', 'completed'));
    expect(order, <String>[
      'setFocus',
      'performEditCommand',
      'imeCommitText',
    ]);
  });

  test('type waits for semantic focus to settle before committing native text',
      () async {
    const channel = MethodChannel('test.cef.automation.type-focus-settle');
    final stopwatch = Stopwatch()..start();
    Duration? focusedAt;
    var typedValue = 'before';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        if (expression.contains('const limit=')) {
          return _snapshotPayload(role: 'textbox', value: 'before');
        }
        if (expression.contains('clickConsequential')) {
          return _revalidatedTarget(
            role: 'textbox',
            editable: true,
            value: 'before',
          );
        }
        if (expression.contains('const replace=')) {
          focusedAt = stopwatch.elapsed;
          return jsonEncode(<String, Object?>{'focused': true});
        }
        return jsonEncode(<String, Object?>{'typedValue': typedValue});
      }
      if (call.method == 'imeCommitText' &&
          focusedAt != null &&
          stopwatch.elapsed - focusedAt! >= const Duration(milliseconds: 40)) {
        typedValue = 'after';
      }
      return call.method == 'performEditCommand' ? true : null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 426, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.type(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
      text: 'after',
      replace: true,
    );

    expect(result, containsPair('status', 'completed'));
  });

  test('snapshot exposes native select value and semantic select action',
      () async {
    const channel = MethodChannel('test.cef.automation.select-contract');
    late String expression;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'evaluateJavaScript') return null;
      expression = (call.arguments as Map)['expression'].toString();
      return _snapshotPayload(
        role: 'combobox',
        value: 'Designer',
        nativeSelect: true,
      );
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 427, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });

    final snapshot = await broker.snapshot();

    expect(snapshot.nodes.single.value, 'Designer');
    expect(snapshot.nodes.single.actions, contains('select'));
    expect(expression, contains("(canEdit||tag==='select')"));
    expect(expression, contains("form&&(r==='textbox'||r==='combobox')"));
  });

  test('select option dispatches input and change then verifies the value',
      () async {
    const channel = MethodChannel('test.cef.automation.select-option');
    final expressions = <String>[];
    var selectedValue = 'Engineer';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        expressions.add(expression);
        if (expression.contains('const limit=')) {
          return _snapshotPayload(
            role: 'combobox',
            value: selectedValue,
            nativeSelect: true,
          );
        }
        if (expression.contains('const requested=')) {
          selectedValue = 'Designer';
          return jsonEncode(<String, Object?>{
            'matched': true,
            'selectedValue': selectedValue,
          });
        }
        if (expression.contains('clickConsequential')) {
          return _revalidatedTarget(
            role: 'combobox',
            value: selectedValue,
            nativeSelect: true,
          );
        }
        if (expression.contains('const typedValue=')) {
          return jsonEncode(<String, Object?>{'typedValue': selectedValue});
        }
        return _revalidatedTarget(
          role: 'combobox',
          value: selectedValue,
          nativeSelect: true,
        );
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 428, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.selectOption(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
      value: 'Designer',
    );

    expect(result, containsPair('status', 'completed'));
    expect(selectedValue, 'Designer');
    expect(
      expressions,
      anyElement(
        allOf(contains("new Event('input'"), contains("new Event('change'")),
      ),
    );
  });

  test('type reports outcome unknown when the editable value does not change',
      () async {
    const channel = MethodChannel('test.cef.automation.type-verification');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'evaluateJavaScript') return null;
      final expression = (call.arguments as Map)['expression'].toString();
      if (expression.contains('const limit=')) {
        return _snapshotPayload(role: 'textbox', value: 'before');
      }
      if (expression.contains('clickConsequential')) {
        return _revalidatedTarget(
          role: 'textbox',
          editable: true,
          value: 'before',
        );
      }
      if (expression.contains('const replace=')) {
        return jsonEncode(<String, Object?>{'focused': true});
      }
      return jsonEncode(<String, Object?>{'typedValue': 'before'});
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 422, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.type(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
      text: 'after navigation',
      replace: true,
    );

    expect(result, containsPair('status', 'outcomeUnknown'));
    expect(result, containsPair('dispatchState', 'started'));
    expect(
      result,
      containsPair('resultCode', 'BROWSER_ACTION_OUTCOME_UNKNOWN'),
    );
    expect(result, containsPair('retryable', false));
  });

  test('secret targets reject text before indicator or input dispatch',
      () async {
    const channel = MethodChannel('test.cef.automation.secret');
    final dispatched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        return expression.contains('const limit=')
            ? _snapshotPayload(secret: true, role: 'textbox')
            : _revalidatedTarget(role: 'textbox');
      }
      dispatched.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 43, channel: channel);
    var indicatorCalls = 0;
    final broker = _broker(
      controller,
      beforeInput: (_, __) => indicatorCalls += 1,
    );
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    await expectLater(
      broker.type(
        snapshotId: snapshot.snapshotId,
        ref: snapshot.nodes.single.ref,
        text: 'not-a-real-secret',
      ),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_ACTION_CONFIRMATION_REQUIRED',
        ),
      ),
    );
    expect(indicatorCalls, 0);
    expect(dispatched, isEmpty);
  });

  test('scroll reports the advanced viewport generation', () async {
    const channel = MethodChannel('test.cef.automation.scroll-generation');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        return expression.contains('const limit=')
            ? _snapshotPayload(actions: const <String>['scroll'])
            : _revalidatedTarget(actions: const <String>['scroll']);
      }
      if (call.method == 'captureViewportScreenshot') {
        return base64Encode(const <int>[1, 2, 3]);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 45, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();
    final screenshot = await broker.screenshot();

    final result = await broker.scroll(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
      deltaX: 0,
      deltaY: 200,
    );

    expect(result, containsPair('viewportGeneration', 2));
    expect(broker.viewportGeneration, 2);
    expect(screenshot, containsPair('viewportGeneration', 1));
  });

  test('screenshot rejects an oversized viewport before native capture',
      () async {
    const channel = MethodChannel('test.cef.automation.screenshot-dimensions');
    var captureCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'captureViewportScreenshot') {
        captureCalls += 1;
        return base64Encode(const <int>[1, 2, 3]);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 451, channel: channel);
    final broker = _broker(controller, viewportWidth: 4097);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });

    await expectLater(
      broker.screenshot(),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_CONTENT_LIMIT',
        ),
      ),
    );
    expect(captureCalls, 0);
  });

  test('screenshot aligns its encoded payload limit with the public protocol',
      () async {
    const channel = MethodChannel('test.cef.automation.screenshot-bytes');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'captureViewportScreenshot') {
        return List<String>.filled(11184821, 'A').join();
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 452, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });

    await expectLater(
      broker.screenshot(),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_CONTENT_LIMIT',
        ),
      ),
    );
  });

  test('structural activation risk is revalidated before clicking', () async {
    const channel = MethodChannel('test.cef.automation.structural-risk');
    final dispatched = <String>[];
    final expressions = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        expressions.add(expression);
        return expression.contains('const limit=')
            ? _snapshotPayload()
            : _revalidatedTarget(clickConsequential: true);
      }
      dispatched.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 47, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    await expectLater(
      broker.click(
          snapshotId: snapshot.snapshotId, ref: snapshot.nodes.single.ref),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_ACTION_CONFIRMATION_REQUIRED',
        ),
      ),
    );
    expect(dispatched, isEmpty);
    expect(expressions.first, contains('clickConsequential'));
    expect(expressions.first, contains('el.form'));
    expect(expressions.first, contains("hasAttribute('download')"));
  });

  test('enter that can submit a form requires confirmation', () async {
    const channel = MethodChannel('test.cef.automation.enter-form');
    final dispatched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        return expression.contains('const limit=')
            ? _snapshotPayload(
                role: 'textbox',
                editable: true,
                actions: const <String>['press'],
              )
            : _revalidatedTarget(
                role: 'textbox',
                editable: true,
                actions: const <String>['press'],
                pressConsequential: true,
              );
      }
      dispatched.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 48, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    await expectLater(
      broker.press(
        snapshotId: snapshot.snapshotId,
        ref: snapshot.nodes.single.ref,
        key: 'Enter',
      ),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_ACTION_CONFIRMATION_REQUIRED',
        ),
      ),
    );
    expect(dispatched, isEmpty);
  });

  test('invalid dispatch permit after indicator prevents native input',
      () async {
    const channel = MethodChannel('test.cef.automation.dispatch-fence');
    final dispatched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        return expression.contains('const limit=')
            ? _snapshotPayload()
            : _revalidatedTarget();
      }
      dispatched.add(call.method);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 49, channel: channel);
    var indicatorAcknowledged = false;
    final broker = _broker(
      controller,
      beforeInput: (_, __) => indicatorAcknowledged = true,
      beforeDispatch: () => CefAutomationDispatchPermit(
        generation: 2,
        isCurrent: () => false,
      ),
    );
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    await expectLater(
      broker.click(
          snapshotId: snapshot.snapshotId, ref: snapshot.nodes.single.ref),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_LEASE_PAUSED',
        ),
      ),
    );
    expect(indicatorAcknowledged, isTrue);
    expect(dispatched, isEmpty);
  });

  test('permit loss after dispatch starts returns non-retryable unknown',
      () async {
    const channel = MethodChannel('test.cef.automation.dispatch-unknown');
    final dispatched = <String>[];
    var permitCurrent = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        return expression.contains('const limit=')
            ? _snapshotPayload()
            : _revalidatedTarget();
      }
      dispatched.add(call.method);
      if (call.method == 'sendMouseMove') permitCurrent = false;
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 50, channel: channel);
    final phases = <CefAutomationDispatchState>[];
    final broker = _broker(
      controller,
      beforeDispatch: () => CefAutomationDispatchPermit(
        generation: 3,
        isCurrent: () => permitCurrent,
        onStateChanged: phases.add,
      ),
    );
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    final result = await broker.click(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
    );

    expect(dispatched, <String>['setFocus', 'sendMouseMove']);
    expect(phases, <CefAutomationDispatchState>[
      CefAutomationDispatchState.started,
    ]);
    expect(result, containsPair('status', 'outcomeUnknown'));
    expect(result, containsPair('dispatchState', 'started'));
    expect(
        result, containsPair('resultCode', 'BROWSER_ACTION_OUTCOME_UNKNOWN'));
    expect(result, containsPair('retryable', false));
  });

  test('observation and action ids do not expose the CEF browser id', () async {
    const channel = MethodChannel('test.cef.automation.opaque-ids');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') {
        final expression = (call.arguments as Map)['expression'].toString();
        return expression.contains('const limit=')
            ? _snapshotPayload()
            : _revalidatedTarget();
      }
      if (call.method == 'captureViewportScreenshot') {
        return base64Encode(const <int>[1, 2, 3]);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller =
        CefBrowserController(browserId: 987654, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });

    final snapshot = await broker.snapshot();
    final screenshot = await broker.screenshot();
    final action = await broker.point(
      snapshotId: snapshot.snapshotId,
      ref: snapshot.nodes.single.ref,
    );

    for (final id in <String>[
      snapshot.snapshotId,
      screenshot['screenshotId'].toString(),
      action['actionId'].toString(),
    ]) {
      expect(id, isNot(contains('987654')));
      expect(id, matches(RegExp(r'^[a-z]+_[A-Za-z0-9_-]{20,}$')));
    }
  });

  test('navigation invalidates prior semantic snapshots', () async {
    const channel = MethodChannel('test.cef.automation.navigation');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') return _snapshotPayload();
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 45, channel: channel);
    controller.updateState(
      const BrowserState(browserId: 45, url: 'https://before.test'),
    );
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();
    controller.updateState(
      const BrowserState(browserId: 45, url: 'https://after.test'),
    );
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      broker.point(
        snapshotId: snapshot.snapshotId,
        ref: snapshot.nodes.single.ref,
      ),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_STALE_SNAPSHOT',
        ),
      ),
    );
  });

  test('load-state waits wake on CEF state events before the poll interval',
      () async {
    const channel = MethodChannel('test.cef.automation.event_wait');
    final controller = CefBrowserController(browserId: 54, channel: channel);
    controller.updateState(
      const BrowserState(
        browserId: 54,
        url: 'https://loading.test',
        isLoading: true,
      ),
    );
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });

    final stopwatch = Stopwatch()..start();
    final pending = broker.wait(
      condition: const <String, dynamic>{
        'kind': 'loadState',
        'value': 'idle',
      },
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    controller.updateState(
      const BrowserState(
        browserId: 54,
        url: 'https://loading.test',
        isLoading: false,
      ),
    );

    expect(await pending, containsPair('kind', 'matched'));
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 100)));
  });

  test('external human input invalidates prior semantic snapshots', () async {
    const channel = MethodChannel('test.cef.automation.human_input');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'evaluateJavaScript') return _snapshotPayload();
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 46, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });
    final snapshot = await broker.snapshot();

    broker.invalidateObservationsForExternalInput();

    await expectLater(
      broker.point(
        snapshotId: snapshot.snapshotId,
        ref: snapshot.nodes.single.ref,
      ),
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_STALE_SNAPSHOT',
        ),
      ),
    );
  });

  test('snapshot capture fails stale when human input arrives in flight',
      () async {
    const channel = MethodChannel('test.cef.automation.human_input_race');
    final captureStarted = Completer<void>();
    final captureResult = Completer<String?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'evaluateJavaScript') return null;
      captureStarted.complete();
      return captureResult.future;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final controller = CefBrowserController(browserId: 47, channel: channel);
    final broker = _broker(controller);
    addTearDown(() async {
      await broker.dispose();
      controller.dispose();
    });

    final snapshot = broker.snapshot();
    await captureStarted.future;
    broker.invalidateObservationsForExternalInput();
    captureResult.complete(_snapshotPayload());

    await expectLater(
      snapshot,
      throwsA(
        isA<CefBrowserAutomationException>().having(
          (error) => error.code,
          'code',
          'BROWSER_STALE_SNAPSHOT',
        ),
      ),
    );
  });
}

CefBrowserAutomationBroker _broker(
  CefBrowserController controller, {
  CefAutomationBeforeInput? beforeInput,
  CefAutomationBeforeDispatch? beforeDispatch,
  double viewportWidth = 800,
  double viewportHeight = 600,
}) =>
    CefBrowserAutomationBroker(
      controller: controller,
      lifecycleGeneration: 1,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      deviceScaleFactor: 2,
      beforeInput: beforeInput,
      beforeDispatch: beforeDispatch,
    );

String _snapshotPayload({
  bool secret = false,
  String role = 'button',
  String value = 'safe',
  bool editable = false,
  bool checked = false,
  bool focused = false,
  bool nativeSelect = false,
  List<String>? actions,
  bool clickConsequential = false,
  bool pressConsequential = false,
  double y = 20,
}) =>
    jsonEncode(<String, Object?>{
      'nodes': <Object?>[
        <String, Object?>{
          'ref': 'n1',
          'path': 'html>body>button:nth-of-type(1)',
          'signature': '$role|continue',
          'role': role,
          'name': 'Continue',
          'value': secret ? null : value,
          'states': <String, Object?>{
            'disabled': false,
            'checked': checked,
            'focused': focused,
          },
          'actions': actions ??
              _fixtureActions(
                role: role,
                editable: editable,
                nativeSelect: nativeSelect,
              ),
          'bounds': <String, Object?>{
            'x': 10,
            'y': y,
            'width': 40,
            'height': 60,
          },
          'secret': secret,
          'editable': editable,
          'nativeSelect': nativeSelect,
          'clickConsequential': clickConsequential,
          'pressConsequential': pressConsequential,
        },
      ],
      'truncated': false,
    });

String _revalidatedTarget({
  String role = 'button',
  List<String>? actions,
  bool clickConsequential = false,
  bool pressConsequential = false,
  bool editable = false,
  String? value,
  bool checked = false,
  bool focused = false,
  bool nativeSelect = false,
  double y = 20,
  bool viewportChanged = false,
}) =>
    jsonEncode(<String, Object?>{
      'signature': '$role|continue',
      'actions': actions ??
          _fixtureActions(
            role: role,
            editable: editable,
            nativeSelect: nativeSelect,
          ),
      'clickConsequential': clickConsequential,
      'pressConsequential': pressConsequential,
      'editable': editable,
      'typedValue': value,
      'checked': checked,
      'focused': focused,
      'nativeSelect': nativeSelect,
      'viewportChanged': viewportChanged,
      'bounds': <String, Object?>{
        'x': 10,
        'y': y,
        'width': 40,
        'height': 60,
      },
    });

List<String> _fixtureActions({
  required String role,
  required bool editable,
  required bool nativeSelect,
}) =>
    <String>[
      if (<String>{'button', 'link', 'checkbox', 'radio', 'combobox'}
          .contains(role))
        'click',
      if (editable) 'type',
      if (editable || nativeSelect) 'press',
      if (nativeSelect) 'select',
    ];
