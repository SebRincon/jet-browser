import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_cef_browser/flutter_cef_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CefRenderBackend', () {
    test('serializes stable channel names', () {
      expect(CefRenderBackend.nativeView.channelName, 'nativeView');
      expect(CefRenderBackend.osrTexture.channelName, 'osrTexture');
      expect(
        CefRenderBackend.acceleratedOsrTexture.channelName,
        'acceleratedOsrTexture',
      );
      expect(CefRenderBackend.fromChannelName('nativeView'),
          CefRenderBackend.nativeView);
      expect(CefRenderBackend.fromChannelName('osrTexture'),
          CefRenderBackend.osrTexture);
      expect(
        CefRenderBackend.fromChannelName('acceleratedOsrTexture'),
        CefRenderBackend.acceleratedOsrTexture,
      );
      expect(CefRenderBackend.fromChannelName('unknown'),
          CefRenderBackend.nativeView);
    });
  });

  group('CefRuntimeConfig', () {
    test('defaults windowless rendering support off', () {
      final config = _runtimeConfig();

      expect(config.enableWindowlessRendering, isFalse);
      expect(config.toMap()['enableWindowlessRendering'], isFalse);
      expect(
        CefRuntimeConfig.fromMap(config.toMap()).enableWindowlessRendering,
        isFalse,
      );
    });

    test('round trips windowless rendering support', () {
      final config = _runtimeConfig(enableWindowlessRendering: true);

      expect(config.enableWindowlessRendering, isTrue);
      expect(config.toMap()['enableWindowlessRendering'], isTrue);
      expect(
        CefRuntimeConfig.fromMap(config.toMap()).enableWindowlessRendering,
        isTrue,
      );
    });
  });

  group('CefOsrPerformanceStats', () {
    test('parses native counters and derives an average copy time', () {
      final stats = CefOsrPerformanceStats.fromMap(<String, Object?>{
        'backend': 'acceleratedOsrTexture',
        'frameCount': 10,
        'acceleratedFrameCount': 9,
        'cpuFrameCount': 1,
        'textureReadCount': 8,
        'uniqueTextureReadCount': 6,
        'textureReadAttemptCount': 11,
        'droppedFrameCount': 2,
        'coalescedFrameCount': 3,
        'width': 1920,
        'height': 1080,
        'totalCopyDurationMicros': 12500,
        'maxCopyDurationMicros': 2200,
        'lastCopyDurationMicros': 900,
        'copiedBytes': 82944000,
        'fullFrameCopies': 4,
        'partialCopies': 6,
        'averageDamageCoverage': 0.25,
        'targetFps': 100,
        'effectiveScale': 2.0,
        'zeroCopyFrameCount': 7,
        'leasedAsyncBlitFrameCount': 4,
        'staleAsyncLeaseDropCount': 1,
        'frameLeaseFallbackCount': 2,
        'frameTransferMode': 'leased_direct',
        'requestedFrameTransferMode': 'leased_direct',
        'frameLeaseApiAvailable': 1,
        'gpuCompletionApiObserved': 1,
        'lastError': '',
      });

      expect(stats.backend, CefRenderBackend.acceleratedOsrTexture);
      expect(stats.frameCount, 10);
      expect(stats.acceleratedFrameCount, 9);
      expect(stats.cpuFrameCount, 1);
      expect(stats.textureReadCount, 8);
      expect(stats.uniqueTextureReadCount, 6);
      expect(stats.textureReadAttemptCount, 11);
      expect(stats.droppedFrameCount, 2);
      expect(stats.coalescedFrameCount, 3);
      expect(stats.averageCopyDurationMicros, 1250);
      expect(stats.maxCopyDurationMicros, 2200);
      expect(stats.pixelRateBytesPerSecond(60), 497664000);
      expect(stats.copiedBytes, 82944000);
      expect(stats.fullFrameCopies, 4);
      expect(stats.partialCopies, 6);
      expect(stats.averageDamageCoverage, 0.25);
      expect(stats.targetFps, 100);
      expect(stats.effectiveScale, 2.0);
      expect(stats.zeroCopyFrameCount, 7);
      expect(stats.leasedAsyncBlitFrameCount, 4);
      expect(stats.staleAsyncLeaseDropCount, 1);
      expect(stats.frameLeaseFallbackCount, 2);
      expect(stats.frameTransferMode, 'leased_direct');
      expect(stats.requestedFrameTransferMode, 'leased_direct');
      expect(stats.frameLeaseApiAvailable, isTrue);
      expect(stats.gpuCompletionApiObserved, isTrue);
    });

    test('uses safe defaults for partial native responses', () {
      final stats = CefOsrPerformanceStats.fromMap(const <String, Object?>{});

      expect(stats.backend, CefRenderBackend.nativeView);
      expect(stats.frameCount, 0);
      expect(stats.uniqueTextureReadCount, 0);
      expect(stats.textureReadAttemptCount, 0);
      expect(stats.averageCopyDurationMicros, 0);
      expect(stats.pixelRateBytesPerSecond(60), 0);
      expect(stats.copiedBytes, 0);
      expect(stats.fullFrameCopies, 0);
      expect(stats.partialCopies, 0);
      expect(stats.averageDamageCoverage, 0);
      expect(stats.targetFps, 0);
      expect(stats.effectiveScale, 0);
      expect(stats.zeroCopyFrameCount, 0);
      expect(stats.leasedAsyncBlitFrameCount, 0);
      expect(stats.staleAsyncLeaseDropCount, 0);
      expect(stats.frameLeaseFallbackCount, 0);
      expect(stats.frameTransferMode, 'copied');
      expect(stats.requestedFrameTransferMode, 'copied');
      expect(stats.frameLeaseApiAvailable, isFalse);
      expect(stats.gpuCompletionApiObserved, isFalse);
    });

    test('averages copy duration over copied frames, not direct frames', () {
      final stats = CefOsrPerformanceStats.fromMap(<String, Object?>{
        'frameCount': 10,
        'totalCopyDurationMicros': 1200,
        'fullFrameCopies': 1,
        'partialCopies': 2,
        'zeroCopyFrameCount': 7,
      });

      expect(stats.averageCopyDurationMicros, 400);
    });
  });

  group('CefOsrFrameTransferMode', () {
    test('uses stable native names and fails closed for unknown values', () {
      expect(CefOsrFrameTransferMode.copied.channelName, 'copied');
      expect(
        CefOsrFrameTransferMode.leasedAsyncBlit.channelName,
        'leased_async_blit',
      );
      expect(
        CefOsrFrameTransferMode.leasedDirect.channelName,
        'leased_direct',
      );
      expect(
        CefOsrFrameTransferMode.fromChannelName('leased_direct'),
        CefOsrFrameTransferMode.leasedDirect,
      );
      expect(
        CefOsrFrameTransferMode.fromChannelName('future_mode'),
        CefOsrFrameTransferMode.copied,
      );
    });
  });

  group('CefParityEvent', () {
    test('parses known parity types and rejects unknown maps', () {
      final tooltip = CefParityEvent.fromMap(<String, dynamic>{
        'type': 'tooltip',
        'browserId': 4,
        'text': 'Open link',
      });
      expect(tooltip, isNotNull);
      expect(tooltip!.type, CefParityEventType.tooltip);
      expect(tooltip.browserId, 4);
      expect(tooltip.data['text'], 'Open link');

      final statusMessage = CefParityEvent.fromMap(<String, dynamic>{
        'type': 'statusMessage',
        'browserId': 4,
        'text': 'https://target.test/path',
      });
      expect(statusMessage?.type, CefParityEventType.statusMessage);
      expect(statusMessage?.data['text'], 'https://target.test/path');

      final zoomChanged = CefParityEvent.fromMap(<String, dynamic>{
        'type': 'zoomChanged',
        'browserId': 4,
        'level': 1.5,
        'reset': false,
      });
      expect(zoomChanged?.type, CefParityEventType.zoomChanged);
      expect(zoomChanged?.data['level'], 1.5);

      final contextMenu = CefParityEvent.fromMap(<String, dynamic>{
        'type': 'contextMenu',
        'browserId': 4,
        'menuId': 12,
        'x': 20,
        'y': 30,
        'items': <Object?>[],
      });
      expect(contextMenu, isNotNull);
      expect(contextMenu!.type, CefParityEventType.contextMenu);
      expect(contextMenu.data['menuId'], 12);

      expect(
        CefParityEvent.fromMap(
            <String, dynamic>{'type': 'titleChanged', 'browserId': 4}),
        isNull,
        reason: 'existing browser events must not be captured as parity',
      );
      expect(
        CefParityEvent.fromMap(<String, dynamic>{'type': 'tooltip'}),
        isNull,
        reason: 'missing browserId must not produce an event',
      );
    });

    test('controller emits parity events and drops them after dispose',
        () async {
      final controller = CefBrowserController(
        browserId: 9,
        channel: const MethodChannel('com.example/cef_browser'),
      );
      final received = <CefParityEvent>[];
      final subscription = controller.parityEvents.listen(received.add);

      controller.addParityEvent(const CefParityEvent(
        type: CefParityEventType.fullscreenModeChange,
        browserId: 9,
        data: <String, dynamic>{'fullscreen': true},
      ));
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(received.single.type, CefParityEventType.fullscreenModeChange);

      await subscription.cancel();
      controller.dispose();
      // Must be a silent no-op on a disposed controller (teardown races).
      controller.addParityEvent(const CefParityEvent(
        type: CefParityEventType.tooltip,
        browserId: 9,
        data: <String, dynamic>{},
      ));
    });
  });

  group('browser event additions', () {
    test('parses load-end and audible-state events without ambiguity', () {
      final loadEnd = BrowserEvent.fromMap(<String, dynamic>{
        'type': 'loadEnd',
        'browserId': 8,
        'url': 'https://example.test/path',
      });
      final audio = BrowserEvent.fromMap(<String, dynamic>{
        'type': 'audioStateChanged',
        'browserId': 8,
        'audible': true,
      });

      expect(loadEnd?.type, BrowserEventType.loadEnd);
      expect(loadEnd?.data['url'], 'https://example.test/path');
      expect(audio?.type, BrowserEventType.audioStateChanged);
      expect(audio?.data['audible'], isTrue);
    });

    test('browser state carries audible playback through copies', () {
      const initial = BrowserState(browserId: 8);
      final audible = initial.copyWith(isAudible: true);

      expect(initial.isAudible, isFalse);
      expect(audible.isAudible, isTrue);
    });
  });

  group('native audio playback', () {
    test('does not replace Chromium playback with an unconsumed PCM capture',
        () {
      final clientHeader =
          File('macos/Classes/Bridge/CEFClientImpl.h').readAsStringSync();
      final clientImplementation =
          File('macos/Classes/Bridge/CEFClientImpl.mm').readAsStringSync();

      expect(clientHeader, isNot(contains('public CefAudioHandler')));
      expect(clientHeader, isNot(contains('GetAudioHandler()')));
      expect(clientImplementation, isNot(contains('OnAudioStreamPacket')));
    });
  });

  group('browser-parity controller methods', () {
    test('serialize the exact plugin-bridge contract payloads', () async {
      const channel = MethodChannel('com.example/cef_parity_methods');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final controller = CefBrowserController(browserId: 21, channel: channel);
      addTearDown(controller.dispose);

      await controller.setZoomLevel(1.5);
      await controller.imeSetComposition(
        text: 'かn',
        selectionStart: 1,
        selectionEnd: 2,
      );
      await controller.imeCommitText('か');
      await controller.imeFinishComposing(keepSelection: true);
      await controller.imeFinishComposing();
      await controller.imeCancelComposition();
      await controller.resolveJsDialog(
        callbackId: 7,
        success: true,
        userInput: 'hello',
      );
      await controller.resolveJsDialog(callbackId: 8, success: false);
      await controller.resolveContextMenu(menuId: 12, commandId: 100);
      await controller.cancelContextMenu(menuId: 13);
      final selectedMode = await controller.setOsrFrameTransferMode(
        CefOsrFrameTransferMode.leasedDirect,
      );

      // Method and key names are binding per
      // specs/016-cef-browser-parity/contracts/plugin-bridge.md.
      expect(calls.map((call) => call.method).toList(), <String>[
        'setZoomLevel',
        'imeSetComposition',
        'imeCommitText',
        'imeFinishComposing',
        'imeFinishComposing',
        'imeCancelComposition',
        'resolveJsDialog',
        'resolveJsDialog',
        'resolveContextMenu',
        'cancelContextMenu',
        'setOsrFrameTransferMode',
      ]);
      expect(calls[0].arguments, {'id': 21, 'level': 1.5});
      expect(calls[1].arguments,
          {'id': 21, 'text': 'かn', 'selStart': 1, 'selEnd': 2});
      expect(calls[2].arguments, {'id': 21, 'text': 'か'});
      expect(calls[3].arguments, {'id': 21, 'keepSelection': true});
      expect(calls[4].arguments, {'id': 21, 'keepSelection': false});
      expect(calls[5].arguments, {'id': 21});
      expect(calls[6].arguments,
          {'id': 21, 'callbackId': 7, 'success': true, 'userInput': 'hello'});
      expect(
        calls[7].arguments,
        {'id': 21, 'callbackId': 8, 'success': false},
        reason: 'null userInput must be omitted, not sent as null',
      );
      expect(
        calls[8].arguments,
        {'id': 21, 'menuId': 12, 'commandId': 100},
      );
      expect(calls[9].arguments, {'id': 21, 'menuId': 13});
      expect(calls[10].arguments, {'id': 21, 'mode': 'leased_direct'});
      expect(selectedMode, CefOsrFrameTransferMode.copied);
    });
  });

  group('macOS context menu bridge', () {
    test('serializes the model and resolves retained callbacks asynchronously',
        () {
      final source =
          File('macos/Classes/Bridge/CEFBridge.mm').readAsStringSync();

      expect(source, isNot(contains('CefContextMenuSession')));
      expect(source, isNot(contains('BuildNSMenuFromCefModel')));
      expect(source, isNot(contains('popUpMenuPositioningItem')));
      expect(source, isNot(contains('NSEventTrackingRunLoopMode')));

      expect(source, contains('SerializeCefMenuModel'));
      expect(source, contains('@"commandId"'));
      expect(source, contains('@"submenu"'));
      expect(source, contains('_pendingContextMenuCallbacks'));
      expect(source, contains('onContextMenuForBrowserId'));
      expect(source, contains('resolveContextMenu'));
      expect(source, contains('cancelContextMenu'));
      expect(source, contains('onResetDialogStateForCefBrowserId'));
      expect(source, contains('callback->Continue(commandId, EVENTFLAG_NONE)'));
      expect(source, contains('callback->Cancel()'));
    });
  });

  group('macOS native browser-feel bridge', () {
    test('keeps zoom and document scroll commands native', () {
      final bridge =
          File('macos/Classes/Bridge/CEFBridge.mm').readAsStringSync();
      final plugin =
          File('macos/Classes/FlutterCefBrowserPlugin.mm').readAsStringSync();

      expect(bridge, contains('performBrowserCommand'));
      expect(bridge, contains('GetZoomLevel() + 0.5'));
      expect(bridge, contains('GetZoomLevel() - 0.5'));
      expect(bridge, contains('window.scrollTo({top: 0})'));
      expect(
        bridge,
        contains('window.scrollTo({top: document.body.scrollHeight})'),
      );
      expect(plugin, contains('performFocusedBrowserCommand'));
    });

    test('routes precise and momentum wheel events without Flutter duplication',
        () {
      final bridge =
          File('macos/Classes/Bridge/CEFBridge.mm').readAsStringSync();

      expect(bridge, contains('handleNativeScrollWheelEvent'));
      expect(bridge, contains('hasPreciseScrollingDeltas'));
      expect(bridge, contains('scrollingDeltaX'));
      expect(bridge, contains('scrollingDeltaY'));
      expect(bridge, contains('momentumPhase'));
      expect(bridge, contains('SendMouseWheelEvent'));
    });

    test('persists Chromium cursor feedback across Flutter mouse dispatch', () {
      final bridge =
          File('macos/Classes/Bridge/CEFBridge.mm').readAsStringSync();
      final client =
          File('macos/Classes/Bridge/CEFClientImpl.mm').readAsStringSync();

      expect(client, contains('onCursorChangeForCefBrowserId'));
      expect(bridge, contains('onCursorChangeForCefBrowserId'));
      expect(bridge, contains('CursorForCefType'));
      expect(bridge, contains('applyOsrCursorForEvent'));
    });
  });

  group('macOS keychain startup', () {
    test('runtime mock-keychain environment overrides explicit config', () {
      final sources = <String, ({String source, String configLookup})>{
        'plugin': (
          source: File(
            'macos/Classes/FlutterCefBrowserPlugin.mm',
          ).readAsStringSync(),
          configLookup: 'valueForKey(@"useMockKeychain")',
        ),
        'bridge': (
          source: File('macos/Classes/Bridge/CEFBridge.mm').readAsStringSync(),
          configLookup: 'config[@"useMockKeychain"]',
        ),
      };

      for (final entry in sources.entries) {
        final assignmentStart = entry.value.source.indexOf(
          '@"useMockKeychain": @(',
        );
        final assignmentEnd = entry.value.source.indexOf(
          '@"remoteDebuggingPort"',
          assignmentStart,
        );
        expect(
          assignmentStart,
          greaterThanOrEqualTo(0),
          reason: '${entry.key} must normalize useMockKeychain',
        );
        expect(assignmentEnd, greaterThan(assignmentStart));
        final assignment = entry.value.source.substring(
          assignmentStart,
          assignmentEnd,
        );
        expect(assignment, contains('useMockKeychainEnv'));
        expect(
          assignment.indexOf('useMockKeychainEnv'),
          lessThan(assignment.indexOf(entry.value.configLookup)),
          reason: '${entry.key} must check the launch-time environment before '
              'falling back to the method-channel config',
        );
      }
    });
  });

  group('macOS accelerated frame lease bridge', () {
    test('debounces transient hidden parks and cleans up delayed generations',
        () {
      final bridge =
          File('macos/Classes/Bridge/CEFBridge.mm').readAsStringSync();

      expect(bridge, contains('_osrPendingParkGenerations'));
      expect(bridge, contains('kOsrHiddenParkDebounceMs = 180'));
      expect(
        bridge,
        contains('kOsrHiddenParkDebounceMs * NSEC_PER_MSEC'),
      );
      expect(bridge, contains('debounceIfHiding:NO'));
      expect(
        RegExp(r'_osrPendingParkGenerations\.erase\(')
            .allMatches(bridge)
            .length,
        greaterThanOrEqualTo(8),
        reason: 'delayed parks must be invalidated on resume and every browser '
            'teardown path',
      );
      expect(
        bridge,
        contains('debounceIfHiding:!occluded'),
        reason: 'whole-window occlusion must still park immediately',
      );
    });

    test('rebuilds CEF helpers whenever their ABI inputs change', () {
      final podspec =
          File('macos/flutter_cef_browser.podspec').readAsStringSync();

      expect(podspec, contains(':input_files => ['));
      expect(podspec, contains(r'${PODS_TARGET_SRCROOT}/Helper/main.mm'));
      expect(
        podspec,
        contains(r'${PODS_TARGET_SRCROOT}/Frameworks/libcef_dll_wrapper.a'),
      );
      expect(
        podspec,
        contains(
          r'${PODS_TARGET_SRCROOT}/Frameworks/include/cef_api_hash.h',
        ),
      );
    });

    test('invalidates older async completions before synchronous publication',
        () {
      final plugin =
          File('macos/Classes/FlutterCefBrowserPlugin.mm').readAsStringSync();

      expect(
        plugin,
        contains('- (void)invalidatePendingAsyncFrameLeases'),
        reason:
            'a newer copied fallback needs an ordering barrier against older '
            'leased Metal completions',
      );
      expect(
        RegExp(r'\[self invalidatePendingAsyncFrameLeases\]')
            .allMatches(plugin)
            .length,
        greaterThanOrEqualTo(3),
        reason:
            'CPU paint, popup republish, and synchronous IOSurface copy must '
            'all invalidate queued async completions before publishing',
      );
      expect(plugin, contains('CEF_LEASE_COMPLETION_DELAY_US'));
      expect(plugin, contains('[commandBuffer encodeWaitForEvent:'));
      expect(
        plugin,
        contains('MIN(parsed, 5000000L)'),
        reason: 'the stress-only completion gate must remain bounded',
      );
      expect(
        plugin,
        contains('[self noteUnleasedAcceleratedFrameFallbackIfRequested]'),
        reason: 'CEF admission saturation returns through the legacy paint '
            'callback and must remain visible in fallback telemetry',
      );
    });

    test('rejected leases preserve the surface for legacy fallback', () {
      final client = File(
        'macos/Classes/Bridge/CEFClientImpl.mm',
      ).readAsStringSync();
      final callbackStart = client.indexOf(
        'bool CEFClientImpl::OnAcceleratedFrame(',
      );
      final callbackEnd = client.indexOf('#endif', callbackStart);

      expect(callbackStart, greaterThanOrEqualTo(0));
      expect(callbackEnd, greaterThan(callbackStart));
      final callback = client.substring(callbackStart, callbackEnd);
      expect(
        client,
        contains('- (void)abandonFrame'),
        reason: 'a rejected wrapper must drop its client reference without '
            'returning the producer frame to CEF',
      );
      expect(callback, contains('[lease abandonFrame];'));
      expect(
        callback,
        isNot(contains('[lease releaseFrame];')),
        reason: 'CEF invokes legacy OnAcceleratedPaint after rejection, so '
            'early release leaves that callback with a dangling IOSurface',
      );
    });

    test('pins callback IOSurfaces across metadata and delegate handoff', () {
      final client = File(
        'macos/Classes/Bridge/CEFClientImpl.mm',
      ).readAsStringSync();

      expect(
        RegExp(r'CFRetain\(surface\);').allMatches(client).length,
        greaterThanOrEqualTo(2),
        reason: 'legacy fallback and leased callbacks must both pin the CEF '
            'surface before querying metadata',
      );
      expect(
        RegExp(r'CFRelease\(surface\);').allMatches(client).length,
        greaterThanOrEqualTo(2),
        reason: 'every callback-local surface retain must be balanced',
      );
      expect(client, contains('AcceleratedPaintExtra(info, surface)'));
    });
  });
}

CefRuntimeConfig _runtimeConfig({bool enableWindowlessRendering = false}) {
  return CefRuntimeConfig(
    cachePath: '/tmp/cache',
    rootCachePath: '/tmp/root',
    chromeRuntime: true,
    extensionPaths: const <String>[],
    cefProfile: 'test',
    profileSwitches: const <String, String?>{},
    extraSwitches: const <String, String?>{},
    removeSwitches: const <String>[],
    closePolicy: 'graceful_then_force',
    gracefulCloseTimeoutMs: 1200,
    messagePumpMode: 'cef_sample_compatible',
    maxPumpDelayMs: 33,
    enableMessagePumpFallbackTimer: true,
    deterministicCreate: false,
    deterministicCreateTimeoutMs: 5000,
    requireHelper: true,
    useMockKeychain: false,
    launchMode: 'test',
    remoteDebuggingPort: 0,
    logFilePath: '',
    crashDumpsPath: '',
    uncaughtExceptionStackSize: 10,
    enableWindowlessRendering: enableWindowlessRendering,
  );
}
