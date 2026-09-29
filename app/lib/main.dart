import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'agent_pane.dart';
import 'browser_host.dart';
import 'jet_theme.dart';
import 'shell_chrome.dart';
import 'shell_shortcuts.dart';
import 'collection_view.dart';
import 'workspace_view.dart';
import 'workflow_view.dart';
import 'runtime_setup_view.dart';
import 'sidecar_api.dart';
import 'tab_agent_badge.dart';
import 'tab_agent_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const compiledRoot = String.fromEnvironment('JET_ROOT');
  final root = Platform.environment['JET_DATA_ROOT'] ??
      (compiledRoot.isNotEmpty
          ? compiledRoot
          : Platform.environment['JET_ROOT'] ??
              '${Platform.environment['HOME']}/.jet-browser');
  final port = int.tryParse(Platform.environment['JET_PORT'] ?? '') ?? 9148;
  BrowserHost? host;
  String? error;
  try {
    final token = (await File('$root/.runtime/token').readAsString()).trim();
    if (token.isEmpty) throw StateError('Local service token is empty');
    host = BrowserHost(root, SidecarApi(token, port: port));
  } catch (_) {
    error =
        'Jet could not connect to its local service. Close and reopen the application.';
  }
  runApp(JetApp(host: host, startupError: error));
}

class JetApp extends StatelessWidget {
  const JetApp({super.key, this.host, this.startupError});
  final BrowserHost? host;
  final String? startupError;
  @override
  Widget build(BuildContext context) => ShadcnApp(
        debugShowCheckedModeBanner: false,
        title: 'Jet Browser',
        theme: jetTheme(),
        darkTheme: jetTheme(),
        themeMode: ThemeMode.dark,
        home: host == null
            ? Scaffold(
                child: Center(
                    child: SelectableText(startupError ?? 'Unable to start')))
            : BrowserShell(host: host!),
      );
}

class BrowserShell extends StatefulWidget {
  const BrowserShell({super.key, required this.host});
  final BrowserHost host;
  @override
  State<BrowserShell> createState() => _BrowserShellState();
}

class _BrowserShellState extends State<BrowserShell> {
  final address = TextEditingController();
  final addressFocus = FocusNode();
  final viewportKey = GlobalKey();
  final agentKey = GlobalKey();
  String? uiError;
  String? lastTab;
  String? lastUrl;
  double preferredChat = 420;
  bool chatCollapsed = false;
  String? openCollectionId;
  String? openCollectionSession;
  bool workspaceOpen = false;
  String? openWorkflowId;
  bool setupOpen = false;
  bool setupChecked = false;
  String? _sessionSeen;
  final _shortcutGate = ShellShortcutGate();
  BrowserHost get host => widget.host;

  @override
  void initState() {
    super.initState();
    // Let the native accessibility bridge request semantics. Forcing a Dart
    // handle before that bridge exists can leave it with partial tree updates.
    host.addListener(_changed);
    bindShellShortcuts(_onShellShortcut);
    WidgetsBinding.instance.addPostFrameCallback((_) => host.initialize());
  }

  void _changed() {
    if (!mounted) return;
    final setup = host.state['setup'];
    if (!setupChecked && setup is Map) {
      setupChecked = true;
      if (setup['packaged'] == true && setup['ready'] != true) {
        setupOpen = true;
        host.setBrowserVisible(false);
      }
    }
    if (!addressFocus.hasFocus &&
        (host.active?.id != lastTab || host.active?.url != lastUrl)) {
      address.text = host.active?.url ?? '';
      lastTab = host.active?.id;
      lastUrl = host.active?.url;
    }
    final rawSession = (host.state['session'] as Map?)?['id'];
    final session = rawSession == null ? null : '$rawSession';
    if ((openCollectionId != null || workspaceOpen || openWorkflowId != null) &&
        _sessionSeen != null &&
        session != null &&
        session != _sessionSeen) {
      openWorkflowId = null;
      openCollectionId = null;
      openCollectionSession = null;
      workspaceOpen = false;
      _sessionSeen = session;
      host.setBrowserVisible(true);
    } else if (session != null) {
      _sessionSeen = session;
    }
    setState(() {});
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
      if (mounted) setState(() => uiError = null);
    } catch (error) {
      if (mounted) setState(() => uiError = error.toString());
    }
  }

  void _positionBrowser() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = viewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        unawaited(
            host.updateViewport(box.localToGlobal(Offset.zero) & box.size));
      }
    });
  }

  @override
  void dispose() {
    unbindShellShortcuts();
    host.removeListener(_changed);
    host.dispose();
    address.dispose();
    addressFocus.dispose();
    super.dispose();
  }

  void _onShellShortcut(String action) {
    _restoreBrowser();
    switch (action) {
      case shellShortcutSelectAddress:
        _selectAddress();
      case shellShortcutNewTab:
        _newTab();
      case shellShortcutReload:
        _reload();
    }
  }

  /// CEF blur is asynchronous and can reclaim the first responder after the
  /// text field asks for focus. Blur first, then select, then again next frame.
  void _selectAddress() {
    _restoreBrowser();
    if (!_shortcutGate.claim(shellShortcutSelectAddress)) return;
    unawaited(() async {
      try {
        await host.blurBrowser();
        if (!mounted) return;
        _focusAddress();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _focusAddress();
        });
      } finally {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _shortcutGate.release(shellShortcutSelectAddress);
        });
      }
    }());
  }

  void _focusAddress() {
    addressFocus.requestFocus();
    address.selection =
        TextSelection(baseOffset: 0, extentOffset: address.text.length);
  }

  void _newTab() {
    _restoreBrowser();
    if (!host.ready || !_shortcutGate.claim(shellShortcutNewTab)) return;
    unawaited(_perform(() => host.openTab('about:blank')).whenComplete(() {
      _shortcutGate.release(shellShortcutNewTab);
    }));
  }

  void _reload() {
    _restoreBrowser();
    if (!_shortcutGate.claim(shellShortcutReload)) return;
    unawaited(_perform(host.reloadActive).whenComplete(() {
      _shortcutGate.release(shellShortcutReload);
    }));
  }

  void _restoreBrowser() {
    if (openCollectionId == null &&
        !workspaceOpen &&
        openWorkflowId == null &&
        !setupOpen) {
      return;
    }
    setState(() {
      openWorkflowId = null;
      openCollectionId = null;
      openCollectionSession = null;
      workspaceOpen = false;
      setupOpen = false;
    });
    host.setBrowserVisible(true);
  }

  void _controlTabJob(TabAgentState job, String action) {
    _perform(() async {
      await host.api.request(
          '/${job.isWorkflow ? 'workflows' : 'collections'}/${job.collectionId}/control',
          body: {
            'action': action,
            if (job.isWorkflow)
              'session_id': (host.state['session'] as Map?)?['id']
          });
    });
  }

  Widget _tabJobBadge(String tabId) {
    final job = TabAgentState.fromState(host.state, tabId);
    if (job == null) return const SizedBox.shrink();
    return TabAgentBadge(
        job: job,
        onPause: () => _controlTabJob(job, 'pause'),
        onStop: () => _controlTabJob(job, 'stop'),
        onOpen: () => job.isWorkflow
            ? _openWorkflow(job.collectionId)
            : _openCollection(job.collectionId));
  }

  void _continueSetup() {
    unawaited(_perform(() async {
      await host.continueStartup();
      _restoreBrowser();
    }));
  }

  void _openSetupLink(String url) {
    unawaited(_perform(() async {
      await host.continueStartup();
      _restoreBrowser();
      await host.openTab(url);
    }));
  }

  void _openSetup() {
    _restoreBrowser();
    setState(() => setupOpen = true);
    host.setBrowserVisible(false);
  }

  void _openWorkflow(String id) {
    _restoreBrowser();
    setState(() => openWorkflowId = id);
    host.setBrowserVisible(false);
  }

  void _openCollection(String id) {
    _restoreBrowser();
    final rawSession = (host.state['session'] as Map?)?['id'];
    final session = rawSession == null ? '' : '$rawSession';
    if (session.isNotEmpty) _sessionSeen = session;
    setState(() {
      openCollectionId = id;
      openCollectionSession = session;
      workspaceOpen = false;
    });
    host.setBrowserVisible(false);
  }

  void _openWorkspace() {
    _restoreBrowser();
    final rawSession = (host.state['session'] as Map?)?['id'];
    final session = rawSession == null ? '' : '$rawSession';
    if (session.isNotEmpty) _sessionSeen = session;
    setState(() {
      workspaceOpen = true;
      openWorkflowId = null;
      openCollectionId = null;
      openCollectionSession = null;
    });
    host.setBrowserVisible(false);
  }

  void _openSource(String url) {
    _restoreBrowser();
    unawaited(_perform(() => host.openTab(url)));
  }

  void _openWorkspaceInBrowser(String url) {
    if (!host.connected || host.state['busy'] == true) return;
    _openSource(url);
  }

  List<Map<String, dynamic>> _workspaceFiles() {
    final workspace = host.state['workspace'];
    if (workspace is! Map) return const [];
    final files = workspace['files'];
    if (files is! List) return const [];
    return [
      for (final raw in files)
        if (raw is Map) Map<String, dynamic>.from(raw),
    ];
  }

  bool _workspaceCanOpenBrowser() {
    if (!host.connected || host.state['busy'] == true) return false;
    final collections = host.state['collections'];
    if (collections is List) {
      for (final raw in collections) {
        if (raw is Map &&
            (raw['status'] == 'running' || raw['status'] == 'pausing')) {
          return false;
        }
      }
    }
    return !_chatActive(host.state);
  }

  Map<String, dynamic>? _collectionSummary(String id) {
    final rawList = host.state['collections'];
    if (rawList is! List) return null;
    for (final raw in rawList) {
      if (raw is Map && '${raw['id']}' == id) {
        return Map<String, dynamic>.from(raw);
      }
    }
    return null;
  }

  bool _chatActive(Map state) {
    if (state['busy'] == true) return true;
    return ['loading', 'running', 'queued', 'stopping']
            .contains((state['task'] as Map? ?? {})['status']) ||
        ['routing', 'local', 'connecting', 'running', 'stopping']
            .contains((state['provider'] as Map? ?? {})['status']);
  }

  @override
  Widget build(BuildContext context) {
    _positionBrowser();
    final tab = host.active;
    final tabJob =
        tab == null ? null : TabAgentState.fromState(host.state, tab.id);
    final colors = Theme.of(context).colorScheme;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.keyL, meta: true):
            _SelectAddressIntent(),
        SingleActivator(LogicalKeyboardKey.keyT, meta: true): _NewTabIntent(),
        SingleActivator(LogicalKeyboardKey.keyR, meta: true): _ReloadIntent(),
      },
      child: Actions(
          actions: {
            _SelectAddressIntent:
                CallbackAction<_SelectAddressIntent>(onInvoke: (_) {
              _onShellShortcut(shellShortcutSelectAddress);
              return null;
            }),
            _NewTabIntent: CallbackAction<_NewTabIntent>(onInvoke: (_) {
              _onShellShortcut(shellShortcutNewTab);
              return null;
            }),
            _ReloadIntent: CallbackAction<_ReloadIntent>(onInvoke: (_) {
              _onShellShortcut(shellShortcutReload);
              return null;
            }),
          },
          child: Focus(
              autofocus: true,
              child: Scaffold(
                  child: LayoutBuilder(builder: (context, constraints) {
                final totalWidth = math.max(0.0, constraints.maxWidth);
                final totalHeight = math.max(0.0, constraints.maxHeight);
                final chatWidth = chatCollapsed
                    ? 0.0
                    : clampChatWidth(preferredChat, totalWidth, reserved: 6);
                final showChat = chatWidth >= 1;
                final compact = totalWidth < 980;
                final chromeBudget = math.max(0.0, totalHeight - 48);
                final tabH = chromeBudget >= 100 ? 40.0 : chromeBudget * 0.42;
                final navH = chromeBudget >= 100 ? 48.0 : chromeBudget * 0.58;
                return Column(children: [
                  Container(
                      height: tabH,
                      color: colors.sidebar,
                      child: Row(children: [
                        Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: compact ? 8 : 14),
                            child: const Text('JET',
                                style: TextStyle(
                                    letterSpacing: 2,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800))),
                        Expanded(
                            child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                              for (final item in host.tabs)
                                Container(
                                    width: 180,
                                    margin:
                                        const EdgeInsets.fromLTRB(0, 4, 3, 0),
                                    decoration: BoxDecoration(
                                        color: item == tab
                                            ? colors.background
                                            : colors.sidebar,
                                        border: item == tab
                                            ? Border(
                                                top: BorderSide(
                                                    color: colors.ring,
                                                    width: 2))
                                            : null,
                                        borderRadius:
                                            const BorderRadius.vertical(
                                                top: Radius.circular(6))),
                                    child: Row(children: [
                                      Expanded(
                                          child: GhostButton(
                                              size: ButtonSize.small,
                                              onPressed: () {
                                                _restoreBrowser();
                                                _perform(
                                                    () => host.select(item));
                                              },
                                              alignment: Alignment.centerLeft,
                                              child: Text(item.title,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      fontSize: 13)))),
                                      _tabJobBadge(item.id),
                                      ChromeButton(
                                          label: 'Close tab',
                                          icon: LucideIcons.x,
                                          onPressed: () => _perform(
                                              () => host.closeTab(item))),
                                    ])),
                              ChromeButton(
                                  label: 'New tab',
                                  icon: LucideIcons.plus,
                                  onPressed: !host.ready
                                      ? null
                                      : () {
                                          _restoreBrowser();
                                          _perform(() async {
                                            await host.openTab('about:blank');
                                          });
                                        }),
                            ])),
                        if (!compact)
                          Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Text('Local first · Grok when needed',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: colors.mutedForeground))),
                      ])),
                  Container(
                      height: navH,
                      decoration: BoxDecoration(
                          border:
                              Border(bottom: BorderSide(color: colors.border))),
                      child: Row(children: [
                        const SizedBox(width: 4),
                        ChromeButton(
                            label: 'Back',
                            icon: LucideIcons.arrowLeft,
                            onPressed: tab?.controller.state.canGoBack == true
                                ? () {
                                    _restoreBrowser();
                                    _perform(tab!.controller.goBack);
                                  }
                                : null),
                        ChromeButton(
                            label: 'Forward',
                            icon: LucideIcons.arrowRight,
                            onPressed:
                                tab?.controller.state.canGoForward == true
                                    ? () {
                                        _restoreBrowser();
                                        _perform(tab!.controller.goForward);
                                      }
                                    : null),
                        ChromeButton(
                            label: 'Reload',
                            icon: LucideIcons.rotateCw,
                            onPressed: tab == null
                                ? null
                                : () {
                                    _restoreBrowser();
                                    _perform(host.reloadActive);
                                  }),
                        const SizedBox(width: 4),
                        Expanded(
                            child: Semantics(
                                label: 'Address or search',
                                textField: true,
                                child: TextField(
                                    key: const ValueKey('address-field'),
                                    controller: address,
                                    focusNode: addressFocus,
                                    onTap: () {
                                      _restoreBrowser();
                                      host.blurBrowser();
                                    },
                                    style: const TextStyle(fontSize: 14),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    placeholder:
                                        const Text('Search or enter a URL'),
                                    onSubmitted: (value) {
                                      _restoreBrowser();
                                      _perform(() async {
                                        await tab?.controller
                                            .loadUrl(navigationUrl(value));
                                        addressFocus.unfocus();
                                      });
                                    }))),
                        const SizedBox(width: 4),
                        ChatVisibilityButton(
                          collapsed: !showChat,
                          onPressed: () {
                            if (showChat) {
                              FocusManager.instance.primaryFocus?.unfocus();
                            }
                            setState(() => chatCollapsed = !chatCollapsed);
                          },
                        ),
                        Semantics(
                          label: 'Open the local demo form',
                          button: true,
                          child: Tooltip(
                            alignment: Alignment.bottomCenter,
                            anchorAlignment: Alignment.topCenter,
                            tooltip: (_) => const TooltipContainer(
                                child: Text('Open the local demo form')),
                            child: GhostButton(
                                size: ButtonSize.small,
                                onPressed: tab == null
                                    ? null
                                    : () {
                                        _restoreBrowser();
                                        _perform(() => tab.controller.loadUrl(
                                            'http://127.0.0.1:${host.api.port}/fixture'));
                                      },
                                leading: const Icon(LucideIcons.flaskConical,
                                    size: 15),
                                child: compact
                                    ? const SizedBox.shrink()
                                    : const Text('Demo form')),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ])),
                  if (tabJob != null && totalHeight >= 240)
                    Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: AgentTabStatusBar(
                            job: tabJob,
                            onPause: () => _controlTabJob(tabJob, 'pause'),
                            onStop: () => _controlTabJob(tabJob, 'stop'),
                            onOpen: () =>
                                _openCollection(tabJob.collectionId))),
                  if (host.pageLoading)
                    const LinearProgressIndicator(
                        key: ValueKey('page-loading'), minHeight: 2),
                  if (uiError != null ||
                      host.startupError != null ||
                      host.connectionError != null)
                    Container(
                        width: double.infinity,
                        color: colors.muted,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        child: SelectableText(
                            uiError ??
                                host.startupError ??
                                host.connectionError!,
                            maxLines: 2,
                            style: TextStyle(
                                fontSize: 11, color: colors.destructive))),
                  Expanded(
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                        Expanded(
                            child: SizedBox(
                                key: viewportKey,
                                child: setupOpen
                                    ? RuntimeSetupView(
                                        api: host.api,
                                        onContinue: _continueSetup,
                                        onOpenUrl: _openSetupLink)
                                    : openWorkflowId != null
                                        ? WorkflowView(
                                            api: host.api,
                                            workflowId: openWorkflowId!,
                                            sessionId:
                                                '${(host.state['session'] as Map?)?['id'] ?? ''}',
                                            onClose: _restoreBrowser,
                                            onOpenUrl: _openWorkspaceInBrowser)
                                        : openCollectionId != null
                                            ? CollectionView(
                                                api: host.api,
                                                collectionId: openCollectionId!,
                                                sessionId:
                                                    openCollectionSession ?? '',
                                                summary: _collectionSummary(
                                                    openCollectionId!),
                                                canStart: host.connected &&
                                                    !_chatActive(host.state),
                                                onClose: _restoreBrowser,
                                                onOpenSource: _openSource,
                                              )
                                            : workspaceOpen
                                                ? WorkspaceView(
                                                    api: host.api,
                                                    sessionId: ((host.state[
                                                                    'session']
                                                                as Map?)?['id'] ==
                                                            null)
                                                        ? ''
                                                        : '${(host.state['session'] as Map?)?['id']}',
                                                    files: _workspaceFiles(),
                                                    onClose: _restoreBrowser,
                                                    onOpenBrowser:
                                                        _openWorkspaceInBrowser,
                                                    canOpenBrowser:
                                                        _workspaceCanOpenBrowser(),
                                                  )
                                                : !host.ready
                                                    ? const Center(
                                                        child: Text(
                                                            'Starting Chromium…'))
                                                    : const SizedBox.expand())),
                        if (showChat)
                          ChatResizeHandle(onAdjust: (delta) {
                            setState(() {
                              preferredChat = clampChatWidth(
                                  chatWidth + delta, totalWidth,
                                  reserved: 6);
                            });
                          }),
                        SizedBox(
                          key: const ValueKey('chat-slot'),
                          width: showChat ? chatWidth : 0,
                          child: ClipRect(
                            child: LayoutBuilder(builder: (context, slot) {
                              final paneWidth = math.max(chatWidth, 280.0);
                              final paneHeight = slot.maxHeight.isFinite
                                  ? slot.maxHeight
                                  : 0.0;
                              return OverflowBox(
                                alignment: Alignment.topLeft,
                                minWidth: paneWidth,
                                maxWidth: paneWidth,
                                minHeight: paneHeight,
                                maxHeight: paneHeight,
                                child: ExcludeFocus(
                                  excluding: !showChat,
                                  child: ExcludeSemantics(
                                    excluding: !showChat,
                                    child: TickerMode(
                                      enabled: showChat,
                                      child: Offstage(
                                        key: const ValueKey('chat-offstage'),
                                        offstage: !showChat,
                                        child: AgentPane(
                                            key: agentKey,
                                            host: host,
                                            onOpenCollection: _openCollection,
                                            onOpenWorkspace: _openWorkspace,
                                            onOpenWorkflow: _openWorkflow,
                                            onOpenSetup: _openSetup),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ),
                        ),
                      ])),
                ]);
              })))),
    );
  }
}

class _SelectAddressIntent extends Intent {
  const _SelectAddressIntent();
}

class _NewTabIntent extends Intent {
  const _NewTabIntent();
}

class _ReloadIntent extends Intent {
  const _ReloadIntent();
}
