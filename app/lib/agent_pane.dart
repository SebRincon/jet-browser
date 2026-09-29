import 'dart:math' as math;

import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:vten_chat/vten_chat.dart';

import 'browser_host.dart';
import 'collection_view.dart';
import 'collection_review.dart';
import 'chat_markdown.dart';
import 'chat_projection.dart';
import 'trace_panel.dart';
import 'workflow_view.dart';

const localModels = {
  'lfm_rlcd': 'LFM RLCD · 350M',
  'laya_mlx': 'Laya MLX · 421M',
  'laya_typed': 'Laya Typed · 421M',
  'qwen4b_semif_shared': 'SemIf · 4B',
};

class AgentPane extends StatefulWidget {
  const AgentPane({
    super.key,
    required this.host,
    this.onOpenCollection,
    this.onOpenWorkspace,
    this.onOpenWorkflow,
    this.onOpenSetup,
  });
  final BrowserHost host;
  final ValueChanged<String>? onOpenCollection;
  final VoidCallback? onOpenWorkspace;
  final ValueChanged<String>? onOpenWorkflow;
  final VoidCallback? onOpenSetup;
  @override
  State<AgentPane> createState() => _AgentPaneState();
}

class _AgentPaneState extends State<AgentPane> {
  final composer = TextEditingController();
  final composerFocus = FocusNode();
  final historyQuery = TextEditingController();
  final drafts = <String, String>{};
  bool historyOpen = false;
  bool settingsOpen = false;
  bool diagnosticsOpen = false;
  bool submitting = false;
  String? error;
  String? displayedSession;

  @override
  void dispose() {
    composer.dispose();
    composerFocus.dispose();
    historyQuery.dispose();
    super.dispose();
  }

  bool busyFor(Map state) {
    if (state.containsKey('chat_busy')) return state['chat_busy'] == true;
    if (state['busy'] == true) return true;
    return ['loading', 'running', 'queued', 'stopping']
            .contains((state['task'] as Map? ?? {})['status']) ||
        ['routing', 'local', 'connecting', 'running', 'stopping']
            .contains((state['provider'] as Map? ?? {})['status']);
  }

  bool _overallBusy(Map state) {
    if (state.containsKey('chat_busy')) return state['busy'] == true;
    return busyFor(state);
  }

  int _workspaceCount(Map state) {
    final workspace = state['workspace'];
    if (workspace is! Map) return 0;
    final files = workspace['files'];
    if (files is! List) return 0;
    var count = 0;
    for (final raw in files) {
      if (raw is Map) count++;
    }
    return count;
  }

  Future<void> perform(Future<void> Function() action) async {
    setState(() {
      error = null;
      submitting = true;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  void send() {
    final draft = composer.text;
    final text = draft.trim();
    final session = displayedSession;
    final state = widget.host.state;
    if (text.isEmpty ||
        submitting ||
        busyFor(state) ||
        !widget.host.connected) {
      return;
    }
    perform(() async {
      await widget.host.sendChat(text);
      if (displayedSession == session && composer.text == draft) {
        composer.clear();
      }
    });
  }

  void _trackSession(Map state) {
    final id = (state['session'] as Map? ?? {})['id'] as String?;
    if (id == null || id == displayedSession) return;
    final previous = displayedSession;
    if (previous != null) drafts[previous] = composer.text;
    displayedSession = id;
    composer.text = drafts[id] ?? (previous == null ? composer.text : '');
    error = null;
  }

  void _selectSession([String? id]) {
    final state = widget.host.state;
    if (_overallBusy(state) || submitting || !widget.host.connected) return;
    perform(() async {
      await widget.host.changeSession(sessionId: id);
      if (mounted) setState(() => historyOpen = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final state = host.state;
    _trackSession(state);
    final colors = Theme.of(context).colorScheme;
    final provider = state['provider'] as Map? ?? {};
    final selected =
        (state['settings'] as Map? ?? {})['local_model'] as String? ??
            'lfm_rlcd';
    final busy = busyFor(state);
    final shellBusy = _overallBusy(state);
    final phase = busyPhaseLabel(state);
    final workspaceCount = _workspaceCount(state);
    final projection = ChatProjection.fromState(state);
    final groups = _groups(
      projection,
      busy: busy,
      onOpenLink: (url) {
        perform(() async {
          await host.openTab(url);
        });
      },
      onOpenCollection: widget.onOpenCollection,
      onControlCollection: (id, action) {
        perform(() async {
          await host.api.request(
            '/collections/${Uri.encodeComponent(id)}/control',
            body: collectionControlBody(action),
          );
        });
      },
      canStartCollection: host.connected && !shellBusy && !submitting,
      collectionControlsEnabled: !submitting,
    );
    final version = projection.contentVersion;
    final title =
        '${(state['session'] as Map? ?? {})['title'] ?? 'New conversation'}';
    return DecoratedBox(
      decoration: BoxDecoration(
          color: colors.background,
          border: Border(left: BorderSide(color: colors.border))),
      child: VtenChatUiConfig(
        data: const VtenChatUiConfigData(
          compactToolCalls: true,
          compactStyle: VtenChatUiCompactStyle.vten,
        ),
        child: LayoutBuilder(builder: (context, constraints) {
          final cap = constraints.maxHeight.isFinite
              ? math.min(160.0, constraints.maxHeight * 0.32)
              : 160.0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(title, colors, shellBusy),
              if (workspaceCount > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: GhostButton(
                      size: ButtonSize.small,
                      onPressed: widget.onOpenWorkspace == null
                          ? null
                          : () {
                              widget.host.blurBrowser();
                              widget.onOpenWorkspace!();
                            },
                      child: Text(
                        '$workspaceCount files · Workspace',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: colors.mutedForeground),
                      ),
                    ),
                  ),
                ),
              if ((state['workflows'] as List? ?? []).isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                      child: Column(children: [
                    for (final raw in (state['workflows'] as List).take(3))
                      if (raw is Map)
                        Padding(
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                            child: WorkflowCard(
                                run: Map<String, dynamic>.from(raw),
                                onOpen: () => widget.onOpenWorkflow
                                    ?.call('${raw['id']}'))),
                  ])),
                ),
              if (!host.connected)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                  child: Text(
                    host.connectionError ??
                        'Reconnecting to the local service…',
                    key: const ValueKey('connection-notice'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, height: 1.35, color: colors.destructive),
                  ),
                ),
              if (historyOpen)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: math.max(72, cap)),
                  child: SingleChildScrollView(
                      child: _history(state, colors, shellBusy)),
                ),
              if (diagnosticsOpen)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: math.max(72, cap)),
                  child: SingleChildScrollView(
                    child: TracePanel(
                        trace: Map<String, dynamic>.from(
                            state['trace'] as Map? ?? {}),
                        api: host.api,
                        sessionId: displayedSession),
                  ),
                ),
              Expanded(
                child: ChatSessionTab(
                  onUserInteracted: host.blurBrowser,
                  messageList:
                      LayoutBuilder(builder: (context, listConstraints) {
                    final suggestionCap = listConstraints.maxHeight.isFinite
                        ? math.max(0.0, listConstraints.maxHeight * 0.62)
                        : 220.0;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (projection.turns.isEmpty)
                          ConstrainedBox(
                            constraints:
                                BoxConstraints(maxHeight: suggestionCap),
                            child: SingleChildScrollView(
                                child: _suggestions(colors)),
                          ),
                        Expanded(
                          child: MessageList(
                            sessionId: displayedSession,
                            contentVersion: version,
                            groups: groups,
                          ),
                        ),
                      ],
                    );
                  }),
                  activity: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (phase != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 6, bottom: 6),
                          child: Text(phase,
                              key: const ValueKey('chat-phase'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12, color: colors.mutedForeground)),
                        ),
                      TurnActivityIndicator(busy: busy),
                      if (settingsOpen) _settings(colors, selected, shellBusy),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: SelectableText(error!,
                              style: TextStyle(
                                  color: colors.destructive, fontSize: 13)),
                        ),
                    ],
                  ),
                  prompt: EnhancedPromptInput(
                    controller: composer,
                    focusNode: composerFocus,
                    busy: busy,
                    cancelling: provider['status'] == 'stopping',
                    enabled: host.connected && !submitting,
                    onTap: host.blurBrowser,
                    onSend: send,
                    onStop: host.connected
                        ? () => perform(() => host.stop('chat'))
                        : () {},
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _header(String title, ColorScheme colors, bool busy) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.mutedForeground)),
          ),
          ChromeIconButton(
            key: const ValueKey('chat-model'),
            tooltip: 'Browser action model',
            icon: LucideIcons.settings2,
            selected: settingsOpen,
            onPressed: () {
              widget.host.blurBrowser();
              setState(() {
                settingsOpen = !settingsOpen;
                historyOpen = false;
                diagnosticsOpen = false;
              });
            },
          ),
          const SizedBox(width: 4),
          ChromeIconButton(
            key: const ValueKey('chat-history'),
            tooltip: 'Chat history',
            icon: LucideIcons.history,
            selected: historyOpen,
            onPressed: () {
              widget.host.blurBrowser();
              setState(() {
                historyOpen = !historyOpen;
                settingsOpen = false;
                diagnosticsOpen = false;
              });
            },
          ),
          const SizedBox(width: 4),
          ChromeIconButton(
            key: const ValueKey('new-chat'),
            tooltip: 'New chat',
            icon: LucideIcons.squarePen,
            onPressed: !widget.host.connected || busy || submitting
                ? null
                : () => _selectSession(),
          ),
          const SizedBox(width: 4),
          ChromeIconButton(
            key: const ValueKey('chat-workspace'),
            tooltip: 'Workspace',
            icon: LucideIcons.folderOpen,
            onPressed: widget.onOpenWorkspace == null
                ? null
                : () {
                    widget.host.blurBrowser();
                    widget.onOpenWorkspace!();
                  },
          ),
          const SizedBox(width: 4),
          ChromeIconButton(
              tooltip: 'Models and setup',
              icon: LucideIcons.download,
              onPressed: widget.onOpenSetup),
          const SizedBox(width: 4),
          ChromeIconButton(
            key: const ValueKey('chat-diagnostics'),
            tooltip: 'Diagnostics',
            icon: LucideIcons.listTree,
            selected: diagnosticsOpen,
            onPressed: () {
              widget.host.blurBrowser();
              setState(() {
                diagnosticsOpen = !diagnosticsOpen;
                historyOpen = false;
                settingsOpen = false;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _settings(ColorScheme colors, String selected, bool busy) {
    final provider = widget.host.state['provider'] as Map? ?? {};
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Browser action model',
              style: TextStyle(fontSize: 12, color: colors.mutedForeground)),
          const SizedBox(height: 6),
          Select<String>(
              value: selected,
              enabled: widget.host.connected && !busy && !submitting,
              filled: true,
              constraints: const BoxConstraints(minHeight: 32),
              popupConstraints:
                  const BoxConstraints(maxHeight: 220, maxWidth: 390),
              onChanged: (value) {
                if (value != null) {
                  perform(() async {
                    await widget.host.api
                        .request('/settings', body: {'local_model': value});
                  });
                }
              },
              itemBuilder: (_, value) => Text(localModels[value] ?? value,
                  style: const TextStyle(fontSize: 13)),
              popup: SelectPopup<String>(
                  items: SelectItemList(children: [
                for (final entry in localModels.entries)
                  SelectItemButton(
                      value: entry.key,
                      child: Text(entry.value,
                          style: const TextStyle(fontSize: 13))),
              ])).call),
          const SizedBox(height: 6),
          Text(
              'Router · ${localModels[provider['router_model']] ?? provider['router_model'] ?? 'SemIf · 4B'}',
              style: TextStyle(fontSize: 12, color: colors.mutedForeground)),
          const SizedBox(height: 2),
          Text(
              'The local router handles simple tasks. Grok handles research and reasoning.',
              style: TextStyle(
                  fontSize: 12, height: 1.4, color: colors.mutedForeground)),
        ],
      ),
    );
  }

  void _prefill(String text) {
    widget.host.blurBrowser();
    composer.text = text;
    composer.selection = TextSelection.collapsed(offset: composer.text.length);
    composerFocus.requestFocus();
  }

  Widget _suggestions(ColorScheme colors) {
    const ideas = [
      'Open YouTube',
      "Open NASA's YouTube channel",
      'Find the Wikipedia page for Ada Lovelace',
      'Summarize this page',
    ];
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: composer,
      builder: (context, value, _) {
        final offer = value.text.trim().isEmpty;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Where do you want to go?',
                  key: const ValueKey('chat-empty-heading'),
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: colors.foreground)),
              if (offer) const SizedBox(height: 8),
              if (offer)
                for (final idea in ideas)
                  GhostButton(
                    key: ValueKey('suggest-$idea'),
                    alignment: Alignment.centerLeft,
                    onPressed: () => _prefill(idea),
                    child: Text(idea,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
            ],
          ),
        );
      },
    );
  }

  Widget _history(Map state, ColorScheme colors, bool busy) {
    final sessions =
        (state['sessions'] as List? ?? []).whereType<Map>().toList();
    final query = historyQuery.text.trim().toLowerCase();
    final visible = [
      for (final session in sessions)
        if (query.isEmpty ||
            '${session['title'] ?? 'Untitled chat'}'
                .toLowerCase()
                .contains(query))
          session,
    ];
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: colors.sidebar,
          border: Border(bottom: BorderSide(color: colors.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            child: Text('Chat history',
                style: TextStyle(
                    fontSize: 12,
                    color: colors.mutedForeground,
                    fontWeight: FontWeight.w600)),
          ),
          TextField(
            key: const ValueKey('history-search'),
            controller: historyQuery,
            onTap: widget.host.blurBrowser,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            placeholder: const Text('Search chats by title'),
          ),
          const SizedBox(height: 6),
          if (sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('No saved chats yet',
                  key: const ValueKey('history-empty'),
                  style:
                      TextStyle(fontSize: 13, color: colors.mutedForeground)),
            )
          else if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('No matching chats',
                  key: const ValueKey('history-no-results'),
                  style:
                      TextStyle(fontSize: 13, color: colors.mutedForeground)),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: visible.length,
                itemBuilder: (_, index) {
                  final session = visible[index];
                  final selected = '${session['id']}' == displayedSession;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: selected ? colors.muted : null,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: GhostButton(
                      key: ValueKey('session-${session['id']}'),
                      alignment: Alignment.centerLeft,
                      onPressed: busy ||
                              submitting ||
                              selected ||
                              !widget.host.connected
                          ? null
                          : () => _selectSession('${session['id']}'),
                      leading: Icon(
                          selected
                              ? LucideIcons.check
                              : LucideIcons.messageSquare,
                          size: 14),
                      child: Text('${session['title'] ?? 'Untitled chat'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  );
                },
              ),
            ),
          GhostButton(
            key: const ValueKey('history-new-chat'),
            alignment: Alignment.centerLeft,
            onPressed: busy || submitting || !widget.host.connected
                ? null
                : () => _selectSession(),
            leading: const Icon(LucideIcons.plus, size: 14),
            child: const Text('New chat', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _Turn {
  _Turn(this.id);
  final String id;
  String? userText;
  String? pinText;
  final visible = <Widget>[];
  final collapsed = <Widget>[];
  final responses = <Widget>[];
  final copy = StringBuffer();
}

Widget _collectionCard(
  Map<String, dynamic> collection, {
  required bool canStart,
  required bool controlsEnabled,
  required ValueChanged<String>? onOpen,
  required void Function(String id, String action) onControl,
}) {
  final id = '${collection['id'] ?? ''}';
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: CollectionRunCard(
      key: ValueKey('collection-$id'),
      collection: collection,
      showOpen: onOpen != null,
      controlsEnabled: controlsEnabled,
      canStart: canStart,
      onOpen: () => onOpen?.call(id),
      onControl: (action) => onControl(id, action),
    ),
  );
}

List<MessageListGroup> _groups(
  ChatProjection projection, {
  required bool busy,
  required ValueChanged<String> onOpenLink,
  required ValueChanged<String>? onOpenCollection,
  required void Function(String id, String action) onControlCollection,
  required bool canStartCollection,
  required bool collectionControlsEnabled,
}) {
  final groups = <MessageListGroup>[];
  for (final projected in projection.turns) {
    final turn = _Turn(projected.id);
    final userText = projected.userText;
    turn.userText = userText;
    turn.pinText = userText == null ? null : _pin(userText);
    for (final response in projected.responses) {
      final text = '${response['text'] ?? ''}';
      if (text.trim().isEmpty) continue;
      if (turn.copy.isNotEmpty) turn.copy.write('\n\n');
      turn.copy.write(text);
      final markdown = ChatMarkdown(text: text, onOpenLink: onOpenLink);
      if (response['phase'] == 'progress') {
        turn.collapsed.add(markdown);
      } else {
        turn.responses.add(markdown);
      }
    }
    groups.add(MessageListGroup(
      id: turn.id,
      pinText: turn.pinText,
      userRow: turn.userText == null
          ? null
          : MessageBubble.user(text: turn.userText!),
      child: _turnView(
        turn,
        [
          for (final activity in projected.activities)
            Map<String, dynamic>.from(activity),
        ],
        streaming: busy && projected.id == projection.liveTurnId,
        onOpenLink: onOpenLink,
        onOpenCollection: onOpenCollection,
        onControlCollection: onControlCollection,
        canStartCollection: canStartCollection,
        collectionControlsEnabled: collectionControlsEnabled,
      ),
    ));
  }
  return groups;
}

Widget _turnView(
  _Turn turn,
  List<Map<String, dynamic>> tools, {
  required bool streaming,
  required ValueChanged<String> onOpenLink,
  required ValueChanged<String>? onOpenCollection,
  required void Function(String id, String action) onControlCollection,
  required bool canStartCollection,
  required bool collectionControlsEnabled,
}) {
  final hasTask = tools.any((event) => event['event_type'] == 'task');
  final visible = <Widget>[];
  final collapsed = <Widget>[];
  for (final event in tools) {
    if (event['event_type'] == 'collection') {
      visible.add(_collectionCard(
        event,
        canStart: canStartCollection,
        controlsEnabled: collectionControlsEnabled,
        onOpen: onOpenCollection,
        onControl: onControlCollection,
      ));
      continue;
    }
    final built = event['event_type'] == 'task'
        ? _task(event)
        : _route(event, hideLocalSuccess: hasTask);
    if (built == null) continue;
    final keepOpen =
        built.pending || built.failed || built.handoff || built.interrupted;
    (keepOpen ? visible : collapsed).add(ToolCallActionWrapper(
      key: ValueKey(built.id),
      summary: built.summary,
      pending: built.pending,
      failed: built.failed,
      interrupted: built.interrupted,
      child: built.body,
    ));
  }
  final showAssistant = visible.isNotEmpty ||
      collapsed.isNotEmpty ||
      turn.collapsed.isNotEmpty ||
      turn.responses.isNotEmpty ||
      streaming;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (showAssistant)
        MessageBubble.assistant(
          markdown: turn.responses.isEmpty
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final response in turn.responses)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: response),
                  ],
                ),
          copyText: turn.copy.toString(),
          streaming: streaming,
          activity: visible,
          collapsedSteps: [...turn.collapsed, ...collapsed],
          planningSeed: turn.id,
        ),
    ],
  );
}

class _BuiltTool {
  _BuiltTool({
    required this.id,
    required this.summary,
    required this.body,
    required this.pending,
    required this.failed,
    required this.handoff,
    required this.interrupted,
  });
  final String id;
  final ChatToolSummary summary;
  final Widget body;
  final bool pending;
  final bool failed;
  final bool handoff;
  final bool interrupted;
}

Map? _navigationGoal(Map route) {
  final plan = route['plan'];
  if (plan is! Map) return null;
  final goal = plan['navigation_goal'];
  return goal is Map ? goal : null;
}

String? _turnId(Map state) {
  final trace = state['trace'];
  if (trace is Map && '${trace['turn_id'] ?? ''}'.isNotEmpty) {
    return '${trace['turn_id']}';
  }
  final users = (state['messages'] as List? ?? [])
      .whereType<Map>()
      .where((message) => message['role'] == 'user')
      .toList();
  if (users.isEmpty) return null;
  users.sort((a, b) => ((a['created_at'] as num?) ?? 0)
      .compareTo((b['created_at'] as num?) ?? 0));
  final id = users.last['turn_id'];
  return id == null || '$id'.isEmpty ? null : '$id';
}

/// Live route for the current turn only. A finished route cannot label a new turn.
Map<String, dynamic>? _liveRoute(Map state) {
  final turn = _turnId(state);
  final routes =
      (state['routes'] as List? ?? []).whereType<Map>().where((route) {
    if (turn != null && '${route['turn_id'] ?? ''}' != turn) return false;
    final status = '${route['status'] ?? ''}';
    return status == 'routing' || status == 'running' || status == 'local';
  }).toList();
  if (routes.isEmpty) return null;
  routes.sort((a, b) => ((a['created_at'] as num?) ?? 0)
      .compareTo((b['created_at'] as num?) ?? 0));
  return Map<String, dynamic>.from(routes.last);
}

/// Label for the provider's safe stage metadata (identifiers only, no content).
String grokStageLabel(Object? raw) {
  if (raw is! Map) return 'Grok is working';
  final stage = '${raw['stage'] ?? ''}';
  final tool = '${raw['tool'] ?? ''}';
  final done = (raw['completed_tools'] as List? ?? const []).map((e) => '$e');
  if (stage == 'tool') {
    switch (tool) {
      case 'list_tabs':
      case 'read_page':
      case 'inspect_collection_source':
        return 'Grok is checking the page';
      case 'workflow_sdk':
        return 'Grok is reading the workflow guide';
      case 'save_workflow':
        return 'Saving the workflow';
      case 'recover_workflow_record':
        return 'Opening a cut-off post';
      case 'retag_workflow_records':
        return 'Re-tagging locally';
      case 'run_workflow':
      case 'start_collection':
        return 'Starting the job';
      case 'web_search':
      case 'web_fetch':
        return 'Grok is searching the web';
    }
    return 'Grok is using the browser';
  }
  if (stage == 'responding') return 'Grok is replying';
  if (done.contains('recover_workflow_record') ||
      done.contains('retag_workflow_records') ||
      done.contains('patch_workflow_record') ||
      done.contains('patch_workflow_records')) {
    return 'Grok is repairing records';
  }
  if (done.contains('workflow_sdk') && !done.contains('save_workflow')) {
    return 'Grok is writing the workflow';
  }
  if (stage == 'thinking') return 'Grok is thinking';
  return 'Grok is working';
}

String? busyPhaseLabel(Map state) {
  for (final raw in state['collections'] as List? ?? const []) {
    if (raw is! Map) continue;
    if (raw['status'] == 'pausing') return 'Pausing collection';
    if (raw['status'] == 'running') return 'Organizing locally';
  }
  final provider = '${(state['provider'] as Map? ?? {})['status'] ?? ''}';
  final taskStatus = '${(state['task'] as Map? ?? {})['status'] ?? ''}';
  final active = state['busy'] == true ||
      ['loading', 'running', 'queued', 'stopping'].contains(taskStatus) ||
      ['routing', 'local', 'connecting', 'running', 'stopping']
          .contains(provider);
  if (!active) return null;
  if (provider == 'stopping' || taskStatus == 'stopping') return 'Stopping';
  if (provider == 'connecting' || provider == 'running') {
    return grokStageLabel((state['provider'] as Map? ?? {})['stage']);
  }
  if (provider == 'routing') return 'Choosing an action';
  final route = _liveRoute(state);
  final outcome = route?['outcome'];
  final outcomeStatus = outcome is Map ? '${outcome['status'] ?? ''}' : '';
  final outcomeReason = outcome is Map ? '${outcome['reason'] ?? ''}' : '';
  final goal = route == null ? null : _navigationGoal(route);
  final checking = outcomeStatus == 'running' ||
      outcomeStatus == 'checking' ||
      outcomeReason == 'continue';
  if (checking) return 'Checking the destination';
  if (goal != null && provider == 'local') return 'Opening a page';
  if (state['busy'] == true && route == null && taskStatus.isEmpty) {
    return 'Choosing an action';
  }
  if (provider == 'local' || taskStatus == 'loading') return 'Opening a page';
  if (['running', 'queued'].contains(taskStatus)) return 'Opening a page';
  return 'Choosing an action';
}

String _siteName(String provider) {
  switch (provider) {
    case 'youtube':
      return 'YouTube';
    case 'wikipedia':
      return 'Wikipedia';
    case 'github':
      return 'GitHub';
    case 'google':
      return 'Google';
    default:
      return provider;
  }
}

String _goalTitle(Map goal) {
  final kind = '${goal['kind'] ?? ''}';
  final site = _siteName('${goal['provider'] ?? goal['site'] ?? ''}'.trim());
  final query = '${goal['query'] ?? ''}'.trim();
  final url = '${goal['url'] ?? ''}'.trim();
  switch (kind) {
    case 'homepage':
      return site.isEmpty ? 'Open a site' : 'Open $site';
    case 'channel':
      final where = site.isEmpty ? 'channel' : '$site channel';
      return query.isEmpty ? 'Open a $where' : "Open $query's $where";
    case 'video':
      return query.isEmpty ? 'Open a video' : 'Find a video about $query';
    case 'playlist':
      return query.isEmpty ? 'Open a playlist' : 'Open the playlist for $query';
    case 'article':
      return query.isEmpty
          ? 'Open an article'
          : 'Open the ${site.isEmpty ? '' : '$site '}article for $query';
    case 'search_results':
      return query.isEmpty
          ? 'Show search results'
          : 'Search ${site.isEmpty ? '' : '$site '}for $query';
    case 'explicit_url':
      return url.isEmpty ? 'Open a page' : 'Open $url';
    default:
      return query.isEmpty ? 'Local browser action' : query;
  }
}

String? _timing(Map route) {
  final total = route['total_ms'];
  final elapsed = route['elapsed_ms'];
  final value = total is num ? total : (elapsed is num ? elapsed : null);
  return value == null ? null : traceDuration(value);
}

bool _stoppedStatus(String status) =>
    status == 'cancelled' || status == 'canceled' || status == 'stopped';

_BuiltTool? _route(Map<String, dynamic> route,
    {required bool hideLocalSuccess}) {
  final decision = '${route['decision'] ?? ''}';
  final status = '${route['status'] ?? 'routing'}';
  final error = route['error']?.toString();
  final stopped = _stoppedStatus(status);
  final failed = !stopped &&
      ((error != null && error.isNotEmpty) ||
          status == 'error' ||
          status == 'blocked');
  final handoff = decision == 'grok' || decision.toLowerCase().contains('grok');
  final local = decision == 'local' || decision == 'Local browser action';
  final goal = _navigationGoal(route);
  if (local && goal == null && !failed && !stopped && hideLocalSuccess) {
    return null;
  }
  final title = stopped
      ? 'Stopped'
      : failed
          ? 'Routing failed'
          : handoff
              ? 'Handed off to Grok'
              : goal != null
                  ? _goalTitle(goal)
                  : local
                      ? 'Local browser action'
                      : (decision.isEmpty ? 'Choosing an action' : decision);
  final reason = '${route['reason'] ?? ''}';
  final outcome = route['outcome'];
  final timing = _timing(route);
  return _BuiltTool(
    id: 'route-${route['id']}',
    pending:
        !failed && !stopped && (status == 'routing' || status == 'running'),
    failed: failed,
    handoff: handoff,
    interrupted: stopped,
    summary: ChatToolSummary(
      title: title,
      detail: failed ? (error ?? reason) : '',
      meta: timing ?? (stopped ? 'Stopped' : status),
    ),
    body: _toolBody(
      lines: [
        if (goal?['kind'] == 'homepage')
          'Direct navigation · ${stopped ? 'Stopped' : status}'
        else
          '${localModels[route['model']] ?? route['model'] ?? 'Local router'} · ${stopped ? 'Stopped' : status}',
        if (goal != null)
          'Goal · ${goal['kind'] ?? 'request'}'
              '${goal['provider'] == null ? '' : ' · ${goal['provider']}'}'
              '${'${goal['query'] ?? ''}'.trim().isEmpty ? '' : ' · ${goal['query']}'}',
        if (reason.isNotEmpty) reason,
        if (outcome is Map)
          'Outcome · ${outcome['status'] ?? 'recorded'}'
              '${'${outcome['reason'] ?? ''}'.isEmpty ? '' : ' · ${outcome['reason']}'}',
        if (!stopped &&
            status == 'done' &&
            outcome is Map &&
            '${outcome['status']}' == 'done' &&
            outcome['kind'] == 'proof')
          'URL and visible page matched the destination.',
        if (!stopped &&
            status == 'done' &&
            outcome is Map &&
            '${outcome['status']}' == 'done' &&
            outcome['kind'] != null &&
            outcome['kind'] != 'proof')
          'The local model matched this page to your request.',
        if (error != null && error.isNotEmpty) error,
      ],
      error: failed,
    ),
  );
}

_BuiltTool _task(Map<String, dynamic> task) {
  final actions = (task['actions'] as List? ?? []).whereType<Map>().toList();
  final status = '${task['status'] ?? 'pending'}';
  final error = task['error']?.toString();
  final stopped = _stoppedStatus(status);
  final failed = !stopped &&
      ((error != null && error.isNotEmpty) ||
          status == 'error' ||
          status == 'blocked');
  final pending = !failed &&
      !stopped &&
      ['loading', 'running', 'queued', 'stopping', 'pending'].contains(status);
  final goal = '${task['goal'] ?? ''}';
  final timing = task['total_ms'] is num
      ? task['total_ms'] as num
      : (task['elapsed_ms'] is num ? task['elapsed_ms'] as num : null);
  return _BuiltTool(
    id: 'task-${task['id']}',
    pending: pending,
    failed: failed,
    handoff: false,
    interrupted: stopped || status == 'stopping',
    summary: ChatToolSummary(
      title: stopped
          ? 'Stopped'
          : failed
              ? 'Browser task failed'
              : 'Browser task',
      detail: failed ? (error ?? 'Browser task $status') : '',
      meta: timing == null
          ? (stopped ? 'Stopped' : status)
          : traceDuration(timing),
    ),
    body: _toolBody(
      lines: [
        if (goal.isNotEmpty) goal,
        '${localModels[task['model']] ?? task['model'] ?? 'Local model'} · ${timing == null ? (stopped ? 'Stopped' : status) : traceDuration(timing)} · ${stopped ? 'Stopped' : status}',
        for (final action in actions)
          '${action['kind'] ?? action['operation'] ?? 'Action'} · ${action['action'] ?? ''}'
              '${action['page_changed'] == false ? ' · no page change' : ''}',
        if (status == 'done')
          'Model finished. Check the visible page to confirm the result.',
        if (task['verification'] != null)
          'Recorded check · ${task['verification']}. Model completion is not an independent verification.',
        if (error != null && error.isNotEmpty) error,
      ],
      error: failed,
    ),
  );
}

Widget _toolBody({required List<String> lines, required bool error}) {
  return Builder(builder: (context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            if (line.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SelectableText(line,
                    style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: error && line == lines.last
                            ? colors.destructive
                            : colors.foreground)),
              ),
        ],
      ),
    );
  });
}

String? _pin(String text) {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}
