/// Snapshot of the collection job bound to one browser tab.
/// Built only from service state. No timers and no I/O.
class TabAgentState {
  final String collectionId;
  final bool isWorkflow;
  final String title;
  final String label;
  final int collected;
  final int categorized;
  final int elapsedMs;
  final bool isRunning;
  final bool isPaused;

  const TabAgentState({
    required this.collectionId,
    this.isWorkflow = false,
    required this.title,
    required this.label,
    required this.collected,
    required this.categorized,
    required this.elapsedMs,
    required this.isRunning,
    required this.isPaused,
  });

  String get shortLabel => isRunning ? 'Working' : 'Paused';

  String get tooltip =>
      '$title · $label · $collected collected · $categorized categorized · ${formatAgentElapsed(elapsedMs)}';

  /// First running/pausing summary for [tabId], else the latest paused one.
  static TabAgentState? fromState(Map<String, dynamic> state, String tabId) {
    final list = [
      ...(state['collections'] as List? ?? []),
      for (final w in state['workflows'] as List? ?? [])
        if (w is Map)
          <String, dynamic>{
            ...Map<String, dynamic>.from(w),
            'workflow': true,
            'plan': <String, dynamic>{
              'tab_id': w['tab_id'],
              'title': w['title']
            }
          }
    ];
    if (tabId.isEmpty) return null;
    Map<String, dynamic>? active;
    Map<String, dynamic>? paused;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      if (_tabOf(item) != tabId) continue;
      final status = item['status'];
      if (status == 'running' || status == 'pausing') {
        active ??= item;
      } else if (status == 'paused') {
        paused ??= item;
      }
    }
    final chosen = active ?? paused;
    return chosen == null ? null : _fromRow(chosen);
  }

  static TabAgentState? _fromRow(Map<String, dynamic> row) {
    final id = row['id'];
    final status = row['status'];
    if (id is! String || id.isEmpty || status is! String) return null;
    final running = status == 'running' || status == 'pausing';
    final paused = status == 'paused';
    if (!running && !paused) return null;
    final plan = row['plan'];
    final title = plan is Map<String, dynamic> && plan['title'] is String
        ? plan['title'] as String
        : '';
    final counters = row['counters'];
    final map = counters is Map<String, dynamic> ? counters : null;
    final supervision = row['supervision'];
    final pending =
        supervision is Map<String, dynamic> ? supervision['pending'] : null;
    final review =
        paused && pending is Map && pending['status'] == 'awaiting_user';
    return TabAgentState(
      collectionId: id,
      isWorkflow: row['workflow'] == true,
      title: title,
      label: status == 'pausing'
          ? 'Pausing…'
          : running
              ? 'Agent working'
              : (review ? 'Review ready' : 'Paused'),
      collected: _count(map?[row['workflow'] == true ? 'saved' : 'pages']),
      categorized: _count(map?['classified']),
      elapsedMs: _count(map?['elapsed_ms']),
      isRunning: running,
      isPaused: paused,
    );
  }

  static String? _tabOf(Map<String, dynamic> row) {
    final plan = row['plan'];
    if (plan is! Map<String, dynamic>) return null;
    final id = plan['tab_id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  static int _count(Object? value) {
    if (value is! num || !value.isFinite) return 0;
    return value < 0 ? 0 : value.clamp(0, 1 << 52).toInt();
  }
}

String formatAgentElapsed(int ms) {
  final safe = ms < 0 ? 0 : ms;
  final total = safe ~/ 1000;
  return '${total ~/ 60}m ${total % 60}s';
}
