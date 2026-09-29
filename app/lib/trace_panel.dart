import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'chat_widgets.dart';
import 'sidecar_api.dart';

String traceDuration(num value) => value >= 1000
    ? '${(value / 1000).toStringAsFixed(2)} s'
    : '${value.round()} ms';

class TracePanel extends StatefulWidget {
  const TracePanel(
      {super.key,
      required this.trace,
      required this.api,
      required this.sessionId});
  final Map<String, dynamic> trace;
  final SidecarApi api;
  final String? sessionId;
  @override
  State<TracePanel> createState() => _TracePanelState();
}

class _TracePanelState extends State<TracePanel> {
  bool expanded = false;
  bool loading = false;
  String? error;
  String? copied;
  Map<String, dynamic>? retained;
  String? get turnId => widget.trace['turn_id'] as String?;
  @override
  void didUpdateWidget(covariant TracePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.trace['turn_id'] != turnId) {
      retained = null;
      error = null;
      copied = null;
      loading = false;
      if (oldWidget.sessionId != widget.sessionId) expanded = false;
    }
  }

  Future<void> loadFull() async {
    final id = turnId;
    final session = widget.sessionId;
    if (id == null || loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
          '/traces?turn_id=${Uri.encodeQueryComponent(id)}&limit=2000');
      if (result['turn_id'] != id) {
        throw StateError('Unexpected trace identity');
      }
      if (mounted && turnId == id && widget.sessionId == session) {
        setState(() => retained = result);
      }
    } catch (e) {
      if (mounted && turnId == id && widget.sessionId == session) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted && turnId == id && widget.sessionId == session) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> copy(String kind, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) setState(() => copied = kind);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final byId = <String, Map<String, dynamic>>{};
    for (final event in [
      ...(retained?['events'] as List? ?? []),
      ...(widget.trace['events'] as List? ?? []),
    ].whereType<Map>()) {
      byId['${event['id']}'] = Map<String, dynamic>.from(event);
    }
    final events = byId.values.toList()
      ..sort((a, b) => a['ts'] is num && b['ts'] is num
          ? (a['ts'] as num).compareTo(b['ts'] as num)
          : '${a['ts']}'.compareTo('${b['ts']}'));
    if (turnId == null && events.isEmpty) return const SizedBox.shrink();
    final summary =
        widget.trace['summary'] as Map? ?? retained?['summary'] as Map? ?? {};
    final errors = events.where((event) => event['level'] == 'error').toList();
    final errorCount =
        (summary['error_count'] as num?)?.toInt() ?? errors.length;
    final duration = summary['duration_ms'] as num?;
    final total = (summary['event_count'] as num?)?.toInt() ?? events.length;
    final payload = {'turn_id': turnId, 'events': events, 'summary': summary};
    return Container(
        decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.border))),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          GhostButton(
              key: const ValueKey('trace-toggle'),
              size: ButtonSize.small,
              alignment: Alignment.centerLeft,
              onPressed: () => setState(() => expanded = !expanded),
              child: Row(children: [
                Icon(
                    errorCount > 0
                        ? LucideIcons.circleAlert
                        : LucideIcons.listTree,
                    size: 14,
                    color: errorCount > 0
                        ? colors.destructive
                        : colors.mutedForeground),
                const SizedBox(width: 7),
                Text('Activity',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: colors.mutedForeground)),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                        '${events.length < total ? '${events.length} of $total' : events.length} events'
                        '${duration == null ? '' : ' · ${traceDuration(duration)}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: colors.mutedForeground))),
                if (errorCount > 0)
                  Text('$errorCount ${errorCount == 1 ? 'error' : 'errors'}',
                      style:
                          TextStyle(fontSize: 12, color: colors.destructive)),
                const SizedBox(width: 8),
                Icon(
                    expanded
                        ? LucideIcons.chevronDown
                        : LucideIcons.chevronRight,
                    size: 13,
                    color: colors.mutedForeground),
              ])),
          if (expanded) ...[
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  Expanded(
                      child: Text(
                          turnId == null
                              ? 'Recent events'
                              : 'Turn ${turnId!.substring(0, turnId!.length.clamp(0, 10))}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11, color: colors.mutedForeground))),
                  GhostButton(
                      size: ButtonSize.small,
                      density: ButtonDensity.dense,
                      onPressed:
                          turnId == null ? null : () => copy('id', turnId!),
                      child: Text(copied == 'id' ? 'Copied' : 'Copy ID',
                          style: const TextStyle(fontSize: 11))),
                  GhostButton(
                      size: ButtonSize.small,
                      density: ButtonDensity.dense,
                      onPressed: () => copy('trace',
                          const JsonEncoder.withIndent('  ').convert(payload)),
                      child: Text(copied == 'trace' ? 'Copied' : 'Copy trace',
                          style: const TextStyle(fontSize: 11))),
                ])),
            if (summary['p50_ms'] is num || summary['p95_ms'] is num)
              Padding(
                  padding: const EdgeInsets.fromLTRB(12, 3, 12, 5),
                  child: Wrap(spacing: 12, children: [
                    for (final key in ['p50_ms', 'p95_ms'])
                      if (summary[key] is num)
                        Text(
                            '${key.split('_').first} ${traceDuration(summary[key] as num)}',
                            style: TextStyle(
                                fontSize: 11, color: colors.mutedForeground)),
                  ])),
            ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 230),
                child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                    itemCount: events.length,
                    itemBuilder: (_, index) {
                      final event = events[index];
                      final attributes = event['attributes'] as Map? ?? {};
                      final failed = event['level'] == 'error';
                      return ActivityDisclosure(
                          key: ValueKey('trace-event-${event['id']}'),
                          title: '${event['event'] ?? 'Event'}',
                          icon: LucideIcons.circleDot,
                          meta: event['duration_ms'] is num
                              ? traceDuration(event['duration_ms'] as num)
                              : null,
                          error: failed
                              ? '${attributes['error'] ?? attributes['message'] ?? event['event']}'
                              : null,
                          child: SelectableText(
                              const JsonEncoder.withIndent('  ').convert({
                                'time': event['ts'],
                                'level': event['level'],
                                if (event['span_id'] != null)
                                  'span_id': event['span_id'],
                                if (event['parent_span_id'] != null)
                                  'parent_span_id': event['parent_span_id'],
                                'attributes': attributes,
                              }),
                              style: TextStyle(
                                  fontFamily: 'GeistMono',
                                  package: 'shadcn_flutter',
                                  fontSize: 11,
                                  height: 1.5,
                                  color: colors.mutedForeground)));
                    })),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(error!,
                      style:
                          TextStyle(fontSize: 12, color: colors.destructive))),
            Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: GhostButton(
                    key: const ValueKey('trace-load-full'),
                    size: ButtonSize.small,
                    alignment: Alignment.centerLeft,
                    onPressed: loading || turnId == null ? null : loadFull,
                    leading: const Icon(LucideIcons.fileClock, size: 13),
                    child: Text(
                        loading ? 'Loading retained events…' : 'Load full turn',
                        style: const TextStyle(fontSize: 12)))),
          ],
        ]));
  }
}
