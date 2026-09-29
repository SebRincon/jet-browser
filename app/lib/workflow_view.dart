import 'dart:async';

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'sidecar_api.dart';

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<dynamic> _list(dynamic v) => v is List ? v : const [];

int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : 0);

String _str(dynamic v) => v is String ? v : '';

String _clip(String raw, int n) {
  final t = raw.trim();
  return t.length <= n ? t : t.substring(0, n);
}

String _err(Object e) => _clip(e is StateError ? e.message : '$e', 160);

String _statusLabel(String raw) {
  switch (raw) {
    case 'running':
      return 'Running';
    case 'paused':
      return 'Paused';
    case 'prepared':
      return 'Ready';
    case 'stopped':
      return 'Stopped';
    case 'completed':
    case 'done':
      return 'Finished';
    case 'error':
    case 'failed':
      return 'Needs attention';
    default:
      return raw.isEmpty ? 'Working' : raw.replaceAll('_', ' ');
  }
}

String _minutes(dynamic ms) {
  if (ms is! num || !ms.isFinite || ms <= 0) return '0 min';
  final m = (ms / 60000).floor();
  return m < 1 ? '<1 min' : '$m min';
}

class WorkflowCard extends StatelessWidget {
  const WorkflowCard({super.key, required this.run, required this.onOpen});

  final Map<String, dynamic> run;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final counters = _map(run['counters']);
    final title = _str(run['title']).trim();
    final muted = TextStyle(fontSize: 12, color: scheme.mutedForeground);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _StatusDot(status: _str(run['status'])),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title.isEmpty ? 'Workflow' : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.foreground,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            '${_statusLabel(_str(run['status']))} · ${_minutes(counters['elapsed_ms'])} · Revision ${_int(run['revision'])}',
            style: muted,
          ),
          const SizedBox(height: 2),
          Text(
            '${_int(counters['saved'])} saved · ${_int(counters['classified'])} classified · ${_int(counters['scrolls'])} scrolls',
            style: muted,
          ),
          const SizedBox(height: 8),
          SecondaryButton(
            size: ButtonSize.small,
            onPressed: onOpen,
            child: const Text('Open workflow'),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: status == 'running' ? scheme.primary : scheme.mutedForeground,
      ),
    );
  }
}

class WorkflowView extends StatefulWidget {
  const WorkflowView({
    super.key,
    required this.api,
    required this.workflowId,
    required this.sessionId,
    required this.onClose,
    required this.onOpenUrl,
  });

  final SidecarApi api;
  final String workflowId;
  final String sessionId;
  final VoidCallback onClose;
  final ValueChanged<String> onOpenUrl;

  @override
  State<WorkflowView> createState() => _WorkflowViewState();
}

class _WorkflowViewState extends State<WorkflowView> {
  static const _page = 20;

  Map<String, dynamic> _run = {};
  List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _offset = 0;
  int _ticket = 0;
  String? _error;
  bool _inflight = false;
  bool _queued = false;
  bool _busy = false;
  bool _source = false;
  bool _saved = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(WorkflowView old) {
    super.didUpdateWidget(old);
    if (old.workflowId != widget.workflowId ||
        old.sessionId != widget.sessionId) {
      _ticket++;
      _offset = 0;
      _run = {};
      _items = [];
      _total = 0;
      _error = null;
      _saved = false;
      _arm();
    }
  }

  @override
  void dispose() {
    _ticket++;
    _timer?.cancel();
    super.dispose();
  }

  void _arm() {
    _timer?.cancel();
    _kick();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _kick());
  }

  void _kick() {
    if (_inflight) {
      _queued = true;
      return;
    }
    _load();
  }

  Future<void> _load() async {
    _inflight = true;
    final ticket = _ticket;
    final offset = _offset;
    final id = widget.workflowId;
    final sid = Uri.encodeQueryComponent(widget.sessionId);
    try {
      final data = await widget.api
          .request('/workflows/$id?session_id=$sid&offset=$offset');
      if (!mounted || ticket != _ticket || offset != _offset) return;
      final records = _map(data['records']);
      setState(() {
        _run = _map(data['run']);
        _items = [for (final raw in _list(records['items'])) _map(raw)];
        _total = _int(records['total']);
        _error = null;
      });
    } catch (e) {
      if (!mounted || ticket != _ticket) return;
      setState(() => _error = _err(e));
    } finally {
      _inflight = false;
      if (_queued && mounted) {
        _queued = false;
        _load();
      }
    }
  }

  Future<void> _post(String path, Map<String, dynamic> body, bool saved) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      if (!saved) _saved = false;
    });
    try {
      final data = await widget.api.request(path, body: body);
      if (!mounted) return;
      setState(() => _saved = saved && _map(data['file'])['name'] != null);
      _kick();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _control(String action) {
    _post(
        '/workflows/${widget.workflowId}/control',
        {
          'session_id': widget.sessionId,
          'action': action,
        },
        false);
  }

  void _changePage(int next) {
    setState(() => _offset = next);
    _kick();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.mutedForeground);
    final body = TextStyle(fontSize: 13, color: scheme.foreground);
    final status = _str(_run['status']);
    final running = status == 'running';
    final resume = status == 'prepared' || status == 'paused';
    final title = _str(_run['title']).trim();
    final runError = _str(_run['error']).trim();
    final counters = _map(_run['counters']);
    final end = (_offset + _items.length).clamp(0, _total);
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 420;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            _StatusDot(status: status),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title.isEmpty ? 'Workflow' : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: body.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            GhostButton(
              size: ButtonSize.small,
              onPressed: widget.onClose,
              child: const Text('Close'),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            '${_statusLabel(status)} · ${_int(counters['saved'])} saved · ${_int(counters['classified'])} classified · ${_int(counters['scrolls'])} scrolls · ${_minutes(counters['elapsed_ms'])}',
            style: muted,
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            GhostButton(
              size: ButtonSize.small,
              onPressed: () => setState(() => _source = !_source),
              child: Text(_source ? 'Records' : 'Source'),
            ),
            if (running)
              SecondaryButton(
                size: ButtonSize.small,
                onPressed: _busy || !running ? null : () => _control('pause'),
                child: const Text('Pause'),
              ),
            if (resume)
              SecondaryButton(
                size: ButtonSize.small,
                onPressed: _busy || !resume ? null : () => _control('resume'),
                child: const Text('Resume'),
              ),
            if (running)
              SecondaryButton(
                size: ButtonSize.small,
                onPressed: _busy || !running ? null : () => _control('stop'),
                child: const Text('Stop'),
              ),
            PrimaryButton(
              size: ButtonSize.small,
              onPressed: _busy
                  ? null
                  : () => _post(
                        '/workflows/${widget.workflowId}/export',
                        {'session_id': widget.sessionId},
                        true,
                      ),
              child: const Text('Export'),
            ),
          ]),
          if (_saved) ...[
            const SizedBox(height: 6),
            Text('Saved to workspace', style: muted),
          ],
          if (runError.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(runError, style: body),
          ],
          if (_error != null) ...[
            const SizedBox(height: 6),
            Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(_error!, style: muted),
                  GhostButton(
                    size: ButtonSize.small,
                    onPressed: _kick,
                    child: const Text('Retry'),
                  ),
                ]),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: _source
                ? _sourcePane(scheme, muted)
                : _records(scheme, body, muted, narrow, end),
          ),
        ],
      );
    });
  }

  Widget _sourcePane(ColorScheme scheme, TextStyle muted) {
    final source = _str(_run['source']);
    return ListView(children: [
      Text('Revision ${_int(_run['revision'])}', style: muted),
      const SizedBox(height: 4),
      Text('Read-only. Grok edits through chat.', style: muted),
      const SizedBox(height: 8),
      SelectableText(
        source.isEmpty ? 'No source yet' : source,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: scheme.foreground,
        ),
      ),
    ]);
  }

  Widget _records(
    ColorScheme scheme,
    TextStyle body,
    TextStyle muted,
    bool narrow,
    int end,
  ) {
    return Column(children: [
      Expanded(
        child: _items.isEmpty
            ? Align(
                alignment: Alignment.topLeft,
                child: Text(_run.isEmpty ? 'Loading…' : 'No pages yet',
                    style: muted),
              )
            : ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _RecordTile(
                  item: _items[i],
                  narrow: narrow,
                  onOpenUrl: widget.onOpenUrl,
                ),
              ),
      ),
      const SizedBox(height: 8),
      Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(_total == 0 ? '0 records' : '${_offset + 1}–$end of $_total',
                style: muted),
            GhostButton(
              size: ButtonSize.small,
              onPressed:
                  _offset == 0 ? null : () => _changePage(_offset - _page),
              child: const Text('Previous'),
            ),
            GhostButton(
              size: ButtonSize.small,
              onPressed: _offset + _page >= _total
                  ? null
                  : () => _changePage(_offset + _page),
              child: const Text('Next'),
            ),
          ]),
    ]);
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({
    required this.item,
    required this.narrow,
    required this.onOpenUrl,
  });

  final Map<String, dynamic> item;
  final bool narrow;
  final ValueChanged<String> onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.mutedForeground);
    final body = TextStyle(fontSize: 13, color: scheme.foreground);
    final url = _str(item['url']).trim();
    final author = _str(item['author']).trim();
    final date = _str(item['published_at']).trim();
    final summary = _str(item['summary']).trim();
    final text = _clip(_str(item['text']), 180);
    final tags = <Widget>[
      for (final raw in _list(item['tags']))
        if (_str(raw).trim().isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: scheme.border),
            ),
            child: Text(_str(raw).trim(), style: muted),
          ),
    ];
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (tags.isNotEmpty) Wrap(spacing: 6, runSpacing: 6, children: tags),
        if (summary.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(summary, style: body),
        ],
        if (text.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(text,
              maxLines: narrow ? 4 : 3,
              overflow: TextOverflow.ellipsis,
              style: muted),
        ],
        const SizedBox(height: 4),
        Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(author.isEmpty ? 'Author not observed' : author,
                  style: muted),
              Text(date.isEmpty ? 'Date not observed' : date.split('T').first,
                  style: muted),
              if (item['truncated'] == true) Text('Truncated', style: muted),
              if (url.isNotEmpty)
                GhostButton(
                  size: ButtonSize.small,
                  onPressed: () => onOpenUrl(url),
                  child: const Text('Open link'),
                ),
            ]),
      ]),
    );
  }
}
