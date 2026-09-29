import 'package:flutter/widgets.dart' as fw;
import 'package:shadcn_flutter/shadcn_flutter.dart';

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<dynamic> _list(dynamic v) => v is List ? v : const [];

String _str(dynamic v) => v is String ? v : '';

int _int(dynamic v) => v is int ? v : (v is num ? v.toInt() : 0);

String _clip(String raw, int n) {
  final t = raw.trim();
  if (t.length <= n) return t;
  return t.substring(0, n);
}

String formatCollectionElapsed(dynamic elapsedMs) {
  if (elapsedMs is! num || !elapsedMs.isFinite || elapsedMs <= 0) {
    return '0:00';
  }
  final total = (elapsedMs / 1000).floor();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  if (h > 0) return '$h:${two(m)}:${two(s)}';
  return '$m:${two(s)}';
}

Map<String, dynamic> collectionControlBody(String action) {
  const marks = <String>['approve_checkpoints:', 'approve_continuous:'];
  for (final mark in marks) {
    if (!action.startsWith(mark)) continue;
    return {
      'action': mark.substring(0, mark.length - 1),
      'review_id': action.substring(mark.length),
    };
  }
  return {'action': action};
}

String _reasonLabel(String raw) {
  switch (raw) {
    case 'first_batch':
      return 'First sample';
    case 'interval':
      return 'Scheduled check-in';
    case 'category_drift':
      return 'Categories may have shifted';
    default:
      return raw.replaceAll('_', ' ');
  }
}

class CollectionReviewPanel extends StatelessWidget {
  const CollectionReviewPanel({
    super.key,
    required this.packet,
    required this.onControl,
    this.enabled = true,
  });

  final Map<String, dynamic> packet;
  final ValueChanged<String> onControl;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final pendingRaw = packet['pending'];
    if (pendingRaw is! Map) return const SizedBox.shrink();
    final pending = _map(pendingRaw);
    final scheme = Theme.of(context).colorScheme;
    final status = _str(pending['status']);
    final waiting = status == 'awaiting_user';
    final reviewing = status == 'queued' || status == 'reviewing';
    final summary = _str(pending['summary']).trim();
    final question = _str(pending['question']).trim();
    final prompt = question.isNotEmpty
        ? question
        : (waiting ? 'Does this sample and its categories look right?' : '');
    final counters = _map(packet['counters']);
    final pages = _int(counters['pages']);
    final muted = TextStyle(fontSize: 12, color: scheme.mutedForeground);
    final body = TextStyle(fontSize: 13, color: scheme.foreground);
    final reviewId = _str(pending['id']);
    final fields = _list(packet['fields']).map(_str).toSet();
    final coverage = _coverageLine(fields, _map(packet['coverage']), pages);
    final reason = _str(pending['reason']).trim();

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
          Row(
            children: [
              if (reviewing) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  waiting ? 'A quick check-in' : 'Reviewing your sample',
                  style: body.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${_int(counters['classified'])} classified · ${_int(counters['needs_review'])} to review · ${formatCollectionElapsed(counters['elapsed_ms'])}',
            style: muted,
          ),
          if (reason.isNotEmpty) Text(_reasonLabel(reason), style: muted),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(summary, style: body),
          ],
          if (prompt.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(prompt, style: body),
          ],
          const SizedBox(height: 8),
          _tags(scheme, pending),
          const SizedBox(height: 8),
          Text('Collected sample',
              style: body.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          _table(scheme),
          if (coverage.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(coverage, style: muted),
          ],
          const SizedBox(height: 6),
          Text('Ask in chat to adjust categories or fields.', style: muted),
          if (waiting) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                PrimaryButton(
                  key: const Key('review-checkpoints'),
                  size: ButtonSize.small,
                  onPressed: enabled
                      ? () => onControl('approve_checkpoints:$reviewId')
                      : null,
                  child: Text(
                      'Check in every ${(_int(packet['interval_seconds'] ?? 600) / 60).round()} min'),
                ),
                OutlineButton(
                  key: const Key('review-continuous'),
                  size: ButtonSize.small,
                  onPressed: enabled
                      ? () => onControl('approve_continuous:$reviewId')
                      : null,
                  child: const Text('Run until a limit'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _coverageLine(
    Set<String> fields,
    Map<String, dynamic> coverage,
    int pages,
  ) {
    final parts = <String>[];
    if (fields.contains('author')) {
      parts.add('Author ${_int(coverage['author'])}/$pages');
    }
    if (fields.contains('published_at')) {
      parts.add('Post date ${_int(coverage['published_at'])}/$pages');
    }
    return parts.join(' · ');
  }

  Widget _tags(ColorScheme scheme, Map<String, dynamic> pending) {
    final counts = _map(packet['counts']);
    final chips = <Widget>[];
    for (final raw in _list(packet['categories'])) {
      final cat = _map(raw);
      final id = _str(cat['id']);
      final name = _str(cat['name']).isEmpty ? id : _str(cat['name']);
      if (name.isEmpty) continue;
      chips.add(_chip(scheme, '$name ${_int(counts[id])}'));
    }
    for (final raw in _list(pending['suggested_categories'])) {
      final name = _str(_map(raw)['name']);
      if (name.isEmpty) continue;
      chips.add(_chip(scheme, 'Suggested: $name'));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }

  Widget _chip(ColorScheme scheme, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.border),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: scheme.foreground),
      ),
    );
  }

  String _categoryName(String id) {
    for (final raw in _list(packet['categories'])) {
      final category = _map(raw);
      if (category['id'] == id) return _str(category['name']);
    }
    return id;
  }

  Widget _table(ColorScheme scheme) {
    final header = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: scheme.mutedForeground,
    );
    final cell = TextStyle(fontSize: 12, color: scheme.foreground);
    Widget box(String text, double w, TextStyle style) {
      return SizedBox(
        width: w,
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      );
    }

    fw.TableRow line(List<String> cells, TextStyle style) {
      const widths = <double>[200, 120, 130, 130, 170];
      return fw.TableRow(
        children: [
          for (var i = 0; i < cells.length; i++)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: box(cells[i], widths[i] - 16, style)),
        ],
      );
    }

    final rows = <fw.TableRow>[
      line(const ['Excerpt', 'Category', 'Author', 'Date', 'Link'], header),
    ];
    for (final raw in _list(packet['samples']).take(5)) {
      final sample = _map(raw);
      final author = _str(sample['author']).trim();
      final date = _str(sample['published_at']).trim();
      rows.add(
        line([
          _clip(_str(sample['text']), 80),
          _str(sample['category']) == 'needs_review'
              ? 'Needs review'
              : _categoryName(_str(sample['category'])),
          author.isEmpty ? 'Not observed' : author,
          date.isEmpty ? 'Not observed' : date.split('T').first,
          _str(sample['url']),
        ], cell),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: fw.Table(
        defaultVerticalAlignment: fw.TableCellVerticalAlignment.top,
        columnWidths: const {
          0: fw.FixedColumnWidth(200),
          1: fw.FixedColumnWidth(120),
          2: fw.FixedColumnWidth(130),
          3: fw.FixedColumnWidth(130),
          4: fw.FixedColumnWidth(170),
        },
        children: rows,
      ),
    );
  }
}
