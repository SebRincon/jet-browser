import 'dart:async';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_cef_browser/flutter_cef_browser.dart';
import 'native_bridge.dart';
import 'sidecar_api.dart';

String navigationUrl(String input) {
  final value = input.trim();
  if (value.isEmpty) throw ArgumentError('Enter a URL or search');
  if (value == 'about:blank') return value;
  final uri = Uri.tryParse(value);
  if (uri != null &&
      ['https', 'http'].contains(uri.scheme) &&
      uri.host.isNotEmpty) {
    return uri.toString();
  }
  if (!value.contains(' ') &&
      !value.contains('://') &&
      (value.contains('.') || value.startsWith('localhost:'))) {
    return '${value.startsWith('localhost:') || value.startsWith('127.0.0.1:') ? 'http' : 'https'}://$value';
  }
  return Uri.https('www.google.com', '/search', {'q': value}).toString();
}

class BrowserTab {
  BrowserTab(this.controller, this.initialUrl);
  final CefBrowserController controller;
  final String initialUrl;
  String get id => 'tab-${controller.browserId}';
  String get url =>
      controller.state.url.isEmpty ? initialUrl : controller.state.url;
  String get title =>
      controller.state.title.isEmpty ? 'New tab' : controller.state.title;
  Map<String, dynamic> toJson() => {'id': id, 'url': url, 'title': title};
}

/// Chromium otherwise treats a covered Jet window as hidden: pages throttle, and
/// acknowledged mouse presses from an agent task can be dropped (the prefilled-form
/// failure; see docs/VERIFICATION.md). Agent work must continue while the user
/// works in other apps.
const jetChromiumSwitches = <String, String?>{
  'disable-backgrounding-occluded-windows': null,
  'disable-renderer-backgrounding': null,
};

class BrowserHost extends ChangeNotifier {
  BrowserHost(this.root, this.api);
  final String root;
  final SidecarApi api;
  final manager = CefManager();
  final bridge = NativeBridge();
  final String hostId = 'jet-${DateTime.now().microsecondsSinceEpoch}';
  final List<BrowserTab> tabs = [];
  final List<StreamSubscription<dynamic>> subscriptions = [];
  BrowserTab? active;
  Map<String, dynamic> state = {};
  String? startupError;
  String? connectionError;
  bool ready = false;
  bool _initializing = false;
  bool _allowBrowserStartup = false;
  bool connected = false;
  bool _disposed = false;
  bool _changingSession = false;
  bool _browserVisible = true;
  int _stateGeneration = 0;
  Rect viewport = const Rect.fromLTWH(0, 92, 800, 600);

  Future<void> continueStartup() async {
    _allowBrowserStartup = true;
    await initialize();
  }

  Future<void> initialize() async {
    if (ready || _initializing) return;
    _initializing = true;
    try {
      if (!connected) {
        state = await api.request('/state');
        connected = true;
        _notify();
      }
      final setup = state['setup'];
      if (!_allowBrowserStartup &&
          setup is Map &&
          setup['packaged'] == true &&
          setup['ready'] != true) {
        return; // First-run downloads and sign-in UI work before Chromium starts.
      }
      final profile = Directory('$root/.runtime/browser-profile');
      await profile.create(recursive: true);
      final result = await manager.initialize(
        cachePath: profile.path,
        rootCachePath: profile.path,
        remoteDebuggingPort: 0,
        deterministicCreate: true,
        deterministicCreateTimeoutMs: 10000,
        launchMode: 'jet-standalone',
        logFilePath: '$root/.runtime/cef.log',
        extraSwitches: jetChromiumSwitches,
      );
      if (!result.success) {
        throw StateError(result.message ?? 'CEF initialization failed');
      }
      subscriptions.add(manager.browserEvents.listen((event) {
        if (event.type == BrowserEventType.browserClosed) {
          tabs.removeWhere(
              (tab) => tab.controller.browserId == event.browserId);
          if (active?.controller.browserId == event.browserId) {
            active = tabs.isEmpty ? null : tabs.last;
            if (active != null) unawaited(select(active!));
          }
        }
        _notify();
      }));
      subscriptions.add(manager.popupStream.listen((popup) {
        if (popup.targetUrl.startsWith('https://') ||
            popup.targetUrl.startsWith('http://')) {
          unawaited(openTab(popup.targetUrl).catchError((Object error) {
            connectionError = error.toString();
            _notify();
            return '';
          }));
        }
      }));
      await openTab('http://127.0.0.1:${api.port}/fixture');
      ready = true;
      _notify();
      unawaited(_heartbeat());
      unawaited(_commands());
    } catch (error) {
      startupError = error.toString();
      _notify();
    } finally {
      _initializing = false;
    }
  }

  Future<String> openTab(String url, {bool background = false}) async {
    final browser = await manager.createBrowser(
        url: navigationUrl(url),
        x: background ? -10000 : viewport.left,
        y: viewport.top,
        width: viewport.width,
        height: viewport.height,
        renderBackend: CefRenderBackend.nativeView);
    if (browser == null) throw StateError('Chromium could not create this tab');
    final tab = BrowserTab(browser, navigationUrl(url));
    tabs.add(tab);
    subscriptions.add(browser.stateStream.listen((_) => _notify()));
    if (background && active != null) {
      await browser.setVisible(false);
      await browser.setFocus(false);
    } else {
      await select(tab);
    }
    _notify();
    return tab.id;
  }

  Future<void> select(BrowserTab tab) async {
    if (!tabs.contains(tab)) return;
    if (active != null && active != tab) {
      await active!.controller.setVisible(false);
    }
    active = tab;
    await _applyFrame(tab.controller);
    await tab.controller.setVisible(_browserVisible);
    _notify();
  }

  Future<void> closeTab(BrowserTab tab) async {
    tabs.remove(tab);
    if (active == tab) {
      active = null;
      if (tabs.isNotEmpty) await select(tabs.last);
    }
    await manager.closeBrowser(tab.controller.browserId, force: true);
    if (tabs.isEmpty) await openTab('about:blank');
    _notify();
  }

  Future<void> updateViewport(Rect next) async {
    if (next.width < 1 || next.height < 1 || next == viewport) return;
    viewport = next;
    if (active != null) await _applyFrame(active!.controller);
  }

  Future<void> _applyFrame(CefBrowserController browser) =>
      browser.setViewFrame(
          x: viewport.left,
          y: viewport.top,
          width: viewport.width,
          height: viewport.height);

  Future<void> blurBrowser() async => active?.controller.setFocus(false);

  void setBrowserVisible(bool visible) {
    final changed = _browserVisible != visible;
    _browserVisible = visible;
    void guard(Future<void> future) {
      unawaited(() async {
        try {
          await future;
        } catch (error) {
          connectionError = error.toString();
          _notify();
        }
      }());
    }

    if (!visible) guard(blurBrowser());
    if (!changed) return;
    final tab = active;
    if (tab != null) guard(tab.controller.setVisible(visible));
    _notify();
  }

  bool get pageLoading => active?.controller.state.isLoading ?? false;

  Future<void> reloadActive() async {
    final tab = active;
    if (tab == null) return;
    await tab.controller.reload();
  }

  Future<void> sendChat(String message) async {
    await api.request('/chat', body: {'message': message});
  }

  Future<void> changeSession({String? sessionId}) async {
    if (_changingSession) throw StateError('A chat is already being selected');
    _changingSession = true;
    _stateGeneration++;
    try {
      await api.request(sessionId == null ? '/sessions' : '/sessions/select',
          body: sessionId == null ? {} : {'session_id': sessionId});
      final next = await api.request('/state');
      if (!_disposed) {
        state = next;
        _notify();
      }
    } finally {
      _changingSession = false;
      // Discard any heartbeat response begun while a session was changing.
      _stateGeneration++;
    }
  }

  Future<void> runTask(String goal, String model) async {
    if (active == null) throw StateError('Open a browser tab first');
    await api.request('/tasks',
        body: {'goal': goal, 'model': model, 'tab_id': active!.id});
  }

  Future<void> stop(String lane) =>
      api.request('/$lane/stop', body: {}).then((_) {});

  Map<String, dynamic> get _tabState => {
        'host_id': hostId,
        'capabilities': {'background_tabs': true},
        'active_tab_id': active?.id,
        'tabs': tabs.map((tab) => tab.toJson()).toList(),
      };

  Future<void> _heartbeat() async {
    while (!_disposed) {
      try {
        await api.request('/browser/sync', body: _tabState);
        final generation = _stateGeneration;
        final next = await api.request('/state');
        if (!_changingSession && generation == _stateGeneration) state = next;
        connected = true;
        connectionError = null;
      } catch (error) {
        connected = false;
        connectionError = 'Reconnecting to local service. ${error.toString()}';
      }
      _notify();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  /// The authenticated host dispatcher. Navigation has a finite vocabulary;
  /// every operation resolves the observed tab handle before native dispatch.
  Future<Map<String, dynamic>> executeCommand(
      String? tabId, String method, Map<String, dynamic> params,
      {String? backgroundOwner}) async {
    if (method == 'Browser.openTab') {
      final result = {
        'tab_id': await openTab(params['url'] as String,
            background: params['background'] == true)
      };
      await api.request('/browser/sync', body: _tabState);
      return result;
    }
    final matches =
        tabs.where((tab) => tab.id == tabId && !tab.controller.isDisposed);
    if (matches.length != 1) {
      throw StateError('Requested tab no longer exists');
    }
    final tab = matches.single;
    if (method == 'Browser.selectTab' || method == 'Browser.closeTab') {
      if (method == 'Browser.selectTab') {
        await select(tab);
      } else {
        await closeTab(tab);
      }
      await api.request('/browser/sync', body: _tabState);
      return {'tab_id': tabId, 'active_tab_id': active?.id};
    }
    final backgroundAllowed = backgroundOwner != null &&
        backgroundOwner.isNotEmpty &&
        const {'Runtime.evaluate', 'Page.navigate'}.contains(method);
    if (tab != active && !backgroundAllowed) {
      throw StateError('Requested tab is no longer active');
    }
    switch (method) {
      case 'Browser.back':
        await tab.controller.goBack();
      case 'Browser.forward':
        await tab.controller.goForward();
      case 'Browser.reload':
        await tab.controller.reload();
      default:
        return bridge
            .execute(tab.controller, method, params)
            .timeout(const Duration(seconds: 12));
    }
    return {'tab_id': tabId, 'active_tab_id': active?.id};
  }

  Future<void> _commands() async {
    final seen = <String>{};
    while (!_disposed) {
      try {
        if (!connected) {
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        final command = await api.request('/browser/commands?host_id=$hostId');
        final id = command['command_id'] as String?;
        if (id == null) continue;
        if (!seen.add(id)) continue; // Never replay a dispatched mutation.
        if (seen.length > 10000) {
          throw StateError('Native command limit reached; restart browser');
        }
        final response = <String, dynamic>{'host_id': hostId, 'command_id': id};
        try {
          final params =
              Map<String, dynamic>.from(command['params'] as Map? ?? {});
          final method = command['method'] as String;
          response['result'] = await executeCommand(
              command['tab_id'] as String?, method, params,
              backgroundOwner: command['background_owner'] as String?);
        } catch (error) {
          response['error'] = error.toString();
        }
        // A lost reply is an uncertain result, never a reason to retry input.
        await api.request('/browser/results', body: response);
      } catch (error) {
        connectionError = 'Native bridge: $error';
        _notify();
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    api.close();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(manager.closeAllBrowsersImmediately());
    super.dispose();
  }
}
