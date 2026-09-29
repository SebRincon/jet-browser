import 'dart:async';

import 'package:flutter/services.dart';
import 'package:vten_chat/vten_chat.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'sidecar_api.dart';
import 'collection_review.dart';

const _pageSize = 50;
const _clip = 600;

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<dynamic> _list(dynamic v) => v is List ? v : const [];

String _str(dynamic v) => v is String ? v : '';

int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : 0);

String _capturedWhen(dynamic value) {
  num? epoch;
  if (value is num) {
    epoch = value;
  } else {
    final text = _str(value).trim();
    if (text.isEmpty) return 'time not reported';
    epoch = num.tryParse(text);
    if (epoch == null) return text;
  }
  if (!epoch.isFinite) return 'time not reported';
  final scaled = epoch * 1000;
  if (!scaled.isFinite) return 'time not reported';
  final millis = scaled.round();
  if (millis < -8640000000000000 || millis > 8640000000000000) {
    return 'time not reported';
  }
  final local =
      DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String _humanStatus(String raw) {
  switch (raw) {
    case 'prepared':
      return 'Prepared';
    case 'running':
      return 'Running';
    case 'pausing':
      return 'Pausing';
    case 'paused':
      return 'Paused';
    case 'completed':
      return 'Completed';
    case 'partial':
      return 'Partial';
    case 'failed':
      return 'Failed';
    case 'cancelled':
    case 'canceled':
      return 'Cancelled';
    default:
      return raw.isEmpty ? 'Unknown' : raw.replaceAll('_', ' ');
  }
}

String _humanReason(String raw) {
  const known = {
    'user_stopped': 'Stopped by you',
    'user_stop': 'Stopped by you',
    'disconnected': 'Sidecar disconnected',
    'connection_lost': 'Connection lost',
    'model_error': 'Model error',
    'page_budget': 'Stopped at page budget',
    'budget': 'Stopped at page budget',
    'cancelled': 'Cancelled',
    'canceled': 'Cancelled',
    'error': 'Collection failed',
    'observed_frontier_exhausted': 'Observed pages collected',
    'capture_limited': 'Some page content or links were truncated',
    'time_budget': 'Stopped at time budget',
    'observed_pages_collected': 'Observed pages collected',
    'observed_pages': 'Observed pages collected',
    'pages_collected': 'Observed pages collected',
    'partial': 'Partial',
    'partial_page': 'Partial',
    'partial_capture': 'Partial',
    'feed_stalled': 'No new posts appeared — resume to check again',
    'item_budget': 'Pass limit reached — progress saved',
    'scroll_budget': 'Scroll limit reached — progress saved',
    'source_mismatch': 'Open the requested feed before resuming',
    'scroll_uncertain': 'Scroll result uncertain — paused',
    'source_changed': 'Page or scroll position changed — paused',
    'supervisor_review': 'Progress saved for review',
  };
  final key = raw.trim().toLowerCase();
  if (key.isEmpty) return '';
  return known[key] ?? raw.replaceAll('_', ' ');
}

String _humanModel(String raw) {
  final key = raw.trim().toLowerCase();
  if (key.isEmpty) return 'not reported';
  if (key == 'lfm_rlcd' || (key.contains('lfm') && key.contains('350'))) {
    return 'LFM 350M';
  }
  if (key.contains('semif') && key.contains('4b')) return 'SemIf 4B';
  if (key.contains('laya') && key.contains('mlx')) return 'Laya MLX';
  if (key.contains('laya') && key.contains('typed')) return 'Laya Typed';
  return raw.trim();
}

class CollectionRunCard extends StatefulWidget {
  const CollectionRunCard({
    super.key,
    required this.collection,
    required this.onOpen,
    required this.onControl,
    this.controlsEnabled = true,
    this.canStart = true,
    this.showOpen = true,
  });

  final Map<String, dynamic> collection;
  final VoidCallback onOpen;
  final ValueChanged<String> onControl;
  final bool controlsEnabled;
  final bool canStart;
  final bool showOpen;

  @override
  State<CollectionRunCard> createState() => _CollectionRunCardState();
}

bool _plainCollectionReason(String raw, String status) {
  const plain = {
    'user_stopped',
    'user_stop',
    'page_budget',
    'budget',
    'time_budget',
    'item_budget',
    'scroll_budget',
    'observed_frontier_exhausted',
    'observed_pages_collected',
    'observed_pages',
    'pages_collected',
    'capture_limited',
    'feed_stalled',
    'scroll_uncertain',
    'source_changed',
    'source_mismatch',
    'cancelled',
    'canceled',
    'partial',
    'partial_page',
    'partial_capture',
  };
  final key = raw.trim().toLowerCase();
  if (plain.contains(key)) return true;
  if (status == 'failed') return false;
  return true;
}

String _jobLabel(String sourceKind) {
  if (sourceKind == 'x_bookmarks') return 'Organizing bookmarks';
  if (sourceKind.isNotEmpty && sourceKind != 'website') {
    return 'Organizing posts';
  }
  return 'Collecting pages';
}

class _CollectionRunCardState extends State<CollectionRunCard> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final collection = widget.collection;
    final plan = _map(collection['plan']);
    final counters = _map(collection['counters']);
    final progress = _map(collection['progress']);
    final sourceKind = _str(plan['source_kind']);
    final isFeed = sourceKind.isNotEmpty && sourceKind != 'website';
    final id = _str(collection['id']);
    final status = _str(collection['status']);
    final rawReason = _str(collection['reason']);
    final reason = _humanReason(rawReason);
    final title =
        _str(plan['title']).isEmpty ? 'Collection' : _str(plan['title']);
    final scope = [_str(plan['origin']), _str(plan['section_path'])]
        .where((s) => s.isNotEmpty)
        .join(' · ');
    final muted = TextStyle(fontSize: 12, color: scheme.mutedForeground);
    final spinning = status == 'running' || status == 'pausing';
    final plain = _plainCollectionReason(rawReason, status);
    final saved = _int(counters['pages']);
    final review = _int(counters['needs_review']);
    final limitLine = _limitLine(plan);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (spinning) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  _jobLabel(sourceKind),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.foreground,
                  ),
                ),
              ),
            ],
          ),
          if (status.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(_humanStatus(status), style: muted),
          ],
          const SizedBox(height: 2),
          Wrap(spacing: 12, runSpacing: 4, children: [
            Text('$saved collected', style: muted),
            Text('${_int(counters['classified'])} categorized', style: muted),
            Text('$review to review', style: muted),
            Text(formatCollectionElapsed(counters['elapsed_ms']), style: muted),
          ]),
          if (_map(collection['supervision']).isNotEmpty &&
              _map(collection['review']).isEmpty)
            Text(
                _map(collection['supervision'])['approved'] != true
                    ? 'First check-in after ${_map(collection['supervision'])['first_items'] ?? 10} items'
                    : _map(collection['supervision'])['mode'] == 'continuous'
                        ? 'Local loop · pauses when it needs you'
                        : 'Grok checks in every ${(_int(_map(collection['supervision'])['interval_seconds']) / 60).round()} min',
                style: muted),
          if (reason.isNotEmpty)
            Text(
              reason,
              style: plain ? muted : muted.copyWith(color: scheme.destructive),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (widget.showOpen)
                Semantics(
                  button: true,
                  label: 'Open collection $id',
                  child: GhostButton(
                    key: Key('collection-open-$id'),
                    size: ButtonSize.small,
                    onPressed: widget.onOpen,
                    child: const Text('Open'),
                  ),
                ),
              ..._controls(id, status),
              Semantics(
                button: true,
                expanded: _details,
                label: _details
                    ? 'Hide collection details'
                    : 'Show collection details',
                child: GhostButton(
                  size: ButtonSize.small,
                  onPressed: () => setState(() => _details = !_details),
                  child: Text(_details ? 'Hide details' : 'Details'),
                ),
              ),
            ],
          ),
          if (_map(collection['review']).isNotEmpty) ...[
            const SizedBox(height: 8),
            CollectionReviewPanel(
                packet: _map(collection['review']),
                onControl: widget.onControl,
                enabled: widget.controlsEnabled && widget.canStart),
          ],
          if (_details) ...[
            const SizedBox(height: 8),
            Text(title,
                style: TextStyle(fontSize: 13, color: scheme.foreground)),
            Text('Local model · ${_humanModel(_str(plan['model']))}',
                style: muted),
            if (scope.isNotEmpty) Text(scope, style: muted),
            Text(
              isFeed
                  ? '${_int(counters['pages'])} posts · ${_int(counters['classified'])} classified · ${_int(counters['needs_review'])} need review · ${_int(progress['scrolls'])} scrolls'
                  : '${_int(counters['pages'])} collected · ${_int(counters['classified'])} classified · ${_int(counters['needs_review'])} need review',
              style: muted,
            ),
            if (limitLine.isNotEmpty) Text(limitLine, style: muted),
            Text(
              isFeed
                  ? 'Posts from the current feed • progress saved locally'
                  : 'Linked pages in this scope only',
              style: muted,
            ),
          ],
        ],
      ),
    );
  }

  String _limitLine(Map<String, dynamic> plan) {
    const fields = [
      ('time_budget', 'Time limit'),
      ('time_limit', 'Time limit'),
      ('max_seconds', 'Time limit'),
      ('page_budget', 'Page limit'),
      ('max_pages', 'Page limit'),
      ('item_budget', 'Pass limit'),
      ('scroll_budget', 'Scroll limit'),
    ];
    final parts = <String>[];
    for (final entry in fields) {
      final value = plan[entry.$1];
      if (value == null || '$value'.trim().isEmpty) continue;
      parts.add('${entry.$2} $value');
    }
    return parts.join(' · ');
  }

  List<Widget> _controls(String id, String status) {
    final resumable = widget.collection['resumable'] == true &&
        _map(_map(widget.collection['supervision'])['pending']).isEmpty;
    Widget button(String action, String label,
        {required bool enabled, bool primary = false}) {
      final onPressed = enabled && widget.controlsEnabled
          ? () => widget.onControl(action)
          : null;
      final child = Text(label);
      return Semantics(
        button: true,
        label: '$label collection $id',
        child: primary
            ? PrimaryButton(
                key: Key('collection-control-$id-$action'),
                size: ButtonSize.small,
                onPressed: onPressed,
                child: child,
              )
            : GhostButton(
                key: Key('collection-control-$id-$action'),
                size: ButtonSize.small,
                onPressed: onPressed,
                child: child,
              ),
      );
    }

    switch (status) {
      case 'running':
        return [
          button('pause', 'Pause', enabled: true),
          button('stop', 'Stop', enabled: true),
        ];
      case 'pausing':
        return [
          button('pause', 'Pausing', enabled: false),
          button('stop', 'Stop', enabled: true),
        ];
      case 'prepared':
        return [
          button('start', 'Start', enabled: widget.canStart, primary: true)
        ];
      case 'paused':
        return [
          if (resumable)
            button('resume', 'Resume', enabled: widget.canStart, primary: true),
          button('stop', 'Stop', enabled: true),
        ];
      default:
        return const [];
    }
  }
}

class CollectionView extends StatefulWidget {
  const CollectionView({
    super.key,
    required this.api,
    required this.collectionId,
    required this.sessionId,
    required this.onClose,
    required this.onOpenSource,
    this.summary,
    this.canStart = true,
  });

  final SidecarApi api;
  final String collectionId;
  final String sessionId;
  final VoidCallback onClose;
  final ValueChanged<String> onOpenSource;
  final Map<String, dynamic>? summary;
  final bool canStart;

  @override
  State<CollectionView> createState() => _CollectionViewState();
}

class _CollectionViewState extends State<CollectionView> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final _expanded = <String>{};
  Timer? _debounce;
  int _gen = 0;
  int _identity = 0;
  int _offset = 0;
  int _total = 0;
  String _category = '';
  String? _error;
  String? _copyNote;
  bool _loading = false;
  bool _controlBusy = false;
  bool _exportBusy = false;
  Map<String, dynamic> _collection = {};
  List<Map<String, dynamic>> _items = const [];

  bool get _busy => _controlBusy || _exportBusy;

  @override
  void initState() {
    super.initState();
    if (widget.summary != null) _collection = _map(widget.summary);
    _load();
  }

  @override
  void didUpdateWidget(CollectionView old) {
    super.didUpdateWidget(old);
    final identity = old.collectionId != widget.collectionId ||
        old.sessionId != widget.sessionId;
    if (identity) {
      _identity++;
      _gen++;
      _debounce?.cancel();
      _query.clear();
      _category = '';
      _offset = 0;
      _expanded.clear();
      _copyNote = null;
      _items = const [];
      _collection = {};
      _total = 0;
      _error = null;
      _loading = true;
      _controlBusy = false;
      _exportBusy = false;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _load();
      return;
    }
    if (widget.summary != null &&
        _int(widget.summary?['event_seq']) != _int(old.summary?['event_seq'])) {
      _load();
    }
  }

  @override
  void dispose() {
    _gen++;
    _identity++;
    _debounce?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _listCurrent(int gen, String id, String session) =>
      mounted &&
      gen == _gen &&
      widget.collectionId == id &&
      widget.sessionId == session;

  bool _sameIdentity(int identity, String id, String session) =>
      mounted &&
      identity == _identity &&
      widget.collectionId == id &&
      widget.sessionId == session;

  void _onQuery(String value) {
    if (value.length > 200) {
      _query.text = value.substring(0, 200);
      _query.selection = const TextSelection.collapsed(offset: 200);
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _offset = 0);
      _load();
    });
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final id = widget.collectionId;
    final session = widget.sessionId;
    final rawQuery = _query.text;
    final query = rawQuery.length > 200 ? rawQuery.substring(0, 200) : rawQuery;
    final category = _category;
    final offset = _offset;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final path = '/collections/${Uri.encodeComponent(id)}'
          '?query=${Uri.encodeQueryComponent(query)}'
          '&category=${Uri.encodeQueryComponent(category)}'
          '&offset=$offset&limit=$_pageSize';
      final data = await widget.api.request(path);
      if (!_listCurrent(gen, id, session)) return;
      setState(() {
        _collection = _map(data['collection']);
        _items = [for (final row in _list(data['items'])) _map(row)];
        _total = _int(data['total']);
        _offset = _int(data['offset']);
        _loading = false;
      });
    } catch (e) {
      if (!_listCurrent(gen, id, session)) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _control(String action) async {
    if (_controlBusy) return;
    final identity = _identity;
    final id = widget.collectionId;
    final session = widget.sessionId;
    setState(() => _controlBusy = true);
    try {
      await widget.api.request(
        '/collections/${Uri.encodeComponent(id)}/control',
        body: collectionControlBody(action),
      );
      if (_sameIdentity(identity, id, session)) await _load();
    } catch (e) {
      if (_sameIdentity(identity, id, session)) {
        setState(() => _error = '$e');
      }
    } finally {
      if (_sameIdentity(identity, id, session)) {
        setState(() => _controlBusy = false);
      }
    }
  }

  Future<void> _export(String format) async {
    if (_exportBusy) return;
    final identity = _identity;
    final id = widget.collectionId;
    final session = widget.sessionId;
    setState(() => _exportBusy = true);
    try {
      final data = await widget.api.request(
        '/collections/${Uri.encodeComponent(id)}/export?format=$format',
      );
      if (!_sameIdentity(identity, id, session)) return;
      final text = _str(data['content']);
      if (!_sameIdentity(identity, id, session)) return;
      await Clipboard.setData(ClipboardData(text: text));
      if (!_sameIdentity(identity, id, session)) return;
      setState(() {
        _copyNote = format == 'csv' ? 'CSV copied' : 'Markdown copied';
      });
    } catch (e) {
      if (_sameIdentity(identity, id, session)) {
        setState(() => _error = '$e');
      }
    } finally {
      if (_sameIdentity(identity, id, session)) {
        setState(() => _exportBusy = false);
      }
    }
  }

  String _categoryName(Map<String, dynamic> item) {
    final label = _str(_map(item['classification'])['label_id']);
    if (label.isEmpty || label == 'needs_review') return 'Needs review';
    for (final raw in _list(_map(_collection['plan'])['categories'])) {
      final cat = _map(raw);
      if (_str(cat['id']) == label) {
        final name = _str(cat['name']);
        return name.isEmpty ? label : name;
      }
    }
    return label.replaceAll('_', ' ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: scheme.mutedForeground);
    final categories = _list(_map(_collection['plan'])['categories']);
    final from = _total == 0 ? 0 : _offset + 1;
    final to = (_offset + _items.length).clamp(0, _total);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height),
      child: ColoredBox(
        color: scheme.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  GhostButton(
                    size: ButtonSize.small,
                    onPressed: widget.onClose,
                    child: const Text('Back to page'),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Text(
                      _str(_map(_collection['plan'])['title']).isEmpty
                          ? 'Collection'
                          : _str(_map(_collection['plan'])['title']),
                      style: TextStyle(
                          fontSize: 13,
                          color: scheme.foreground,
                          fontWeight: FontWeight.w600),
                      softWrap: true,
                    ),
                  ),
                  GhostButton(
                    size: ButtonSize.small,
                    onPressed: _busy ? null : () => _export('csv'),
                    child: const Text('Copy CSV'),
                  ),
                  GhostButton(
                    size: ButtonSize.small,
                    onPressed: _busy ? null : () => _export('markdown'),
                    child: const Text('Copy Markdown'),
                  ),
                  ChromeIconButton(
                    tooltip: 'Refresh',
                    onPressed: _busy ? null : _load,
                    icon: Icons.refresh,
                  ),
                  if (_copyNote != null) Text(_copyNote!, style: muted),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: CollectionRunCard(
                collection: _collection,
                onOpen: () {},
                onControl: _control,
                showOpen: false,
                controlsEnabled: !_controlBusy,
                canStart: widget.canStart,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _query,
                onChanged: _onQuery,
                inputFormatters: [LengthLimitingTextInputFormatter(200)],
                placeholder: const Text('Search results'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _filterChip('', 'All'),
                  for (final raw in categories)
                    _filterChip(
                        _str(_map(raw)['id']),
                        _str(_map(raw)['name']).isEmpty
                            ? _str(_map(raw)['id'])
                            : _str(_map(raw)['name'])),
                  _filterChip('needs_review', 'Needs review'),
                ],
              ),
            ),
            Expanded(child: _body(muted)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('$from–$to of $_total', style: muted),
                  GhostButton(
                    size: ButtonSize.small,
                    onPressed: _offset <= 0 || _loading
                        ? null
                        : () {
                            setState(() => _offset =
                                (_offset - _pageSize).clamp(0, _offset));
                            _load();
                          },
                    child: const Text('Prev'),
                  ),
                  GhostButton(
                    size: ButtonSize.small,
                    onPressed: _offset + _pageSize >= _total || _loading
                        ? null
                        : () {
                            setState(() => _offset += _pageSize);
                            _load();
                          },
                    child: const Text('Next'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String id, String label) {
    final selected = _category == id;
    final scheme = Theme.of(context).colorScheme;
    return GhostButton(
      size: ButtonSize.small,
      onPressed: () {
        setState(() {
          _category = id;
          _offset = 0;
        });
        _load();
      },
      leading: selected
          ? Icon(Icons.check, size: 14, color: scheme.foreground)
          : null,
      child: Text(label,
          style: TextStyle(
              fontSize: 13,
              color: selected ? scheme.foreground : scheme.mutedForeground)),
    );
  }

  Widget _body(TextStyle muted) {
    if (_loading && _items.isEmpty) {
      return Center(child: Text('Loading…', style: muted));
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: muted),
            const SizedBox(height: 8),
            GhostButton(
                size: ButtonSize.small,
                onPressed: _load,
                child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      final filtered = _query.text.isNotEmpty || _category.isNotEmpty;
      return Center(
          child:
              Text(filtered ? 'No filter matches' : 'No items', style: muted));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _items.length,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: _item(_items[index]),
      ),
    );
  }

  Widget _item(Map<String, dynamic> item) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontSize: 13, color: scheme.foreground);
    final muted = TextStyle(fontSize: 13, color: scheme.mutedForeground);
    final id = _str(item['id']);
    final text = _str(item['text']);
    final open = _expanded.contains(id);
    final shown = text.length > _clip ? text.substring(0, _clip) : text;
    final cls = _map(item['classification']);
    final confidence = cls['confidence'];
    return Container(
      key: ValueKey(id.isEmpty ? item.hashCode : id),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_categoryName(item), style: muted),
          Text(_str(item['title']).isEmpty ? 'Untitled' : _str(item['title']),
              style: style),
          GhostButton(
            size: ButtonSize.small,
            onPressed: _str(item['url']).isEmpty
                ? null
                : () => widget.onOpenSource(_str(item['url'])),
            child: SizedBox(
              width: double.infinity,
              child: Text(_str(item['url']), style: muted, softWrap: true),
            ),
          ),
          if (item['truncated'] == true)
            Text('Partial page capture', style: muted),
          SelectableText(open ? text : shown, style: style),
          if (!open && text.length > _clip)
            Text('Showing first $_clip characters', style: muted),
          GhostButton(
            size: ButtonSize.small,
            onPressed: () =>
                setState(() => open ? _expanded.remove(id) : _expanded.add(id)),
            child: Text(open ? 'Hide details' : 'Details'),
          ),
          if (open) ...[
            Text('Captured ${_capturedWhen(item['captured_at'])}',
                style: muted),
            Text(
                'Model ${_str(cls['model']).isEmpty ? 'not reported' : _str(cls['model'])}',
                style: muted),
            Text(
              'Excerpt ${_int(cls['excerpt_chars'])} classified characters · page text ${text.length}',
              style: muted,
            ),
            Text(
              confidence == null
                  ? 'Confidence not reported'
                  : 'Confidence $confidence',
              style: muted,
            ),
            if (_str(cls['reason']).isNotEmpty)
              Text(_humanReason(_str(cls['reason'])), style: muted),
          ],
        ],
      ),
    );
  }
}
