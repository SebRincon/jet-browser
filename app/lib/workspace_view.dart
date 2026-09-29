import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'chat_markdown.dart';
import 'sidecar_api.dart';

Map<String, dynamic> _wsMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

String _wsStr(dynamic value) => value is String ? value : '';

int _wsInt(dynamic value) =>
    value is int ? value : (value is num ? value.toInt() : 0);

String _fileSize(dynamic value) {
  final bytes = _wsInt(value);
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

int _stamp(Map<String, dynamic> file) {
  for (final key in ['created_at', 'updated_at', 'mtime', 'version']) {
    final value = file[key];
    if (value is num && value.isFinite) return value.round();
  }
  return 0;
}

String _ext(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

String _kind(Map<String, dynamic> file, String name) {
  final mime = _wsStr(file['media_type']).toLowerCase();
  final ext = _ext(name);
  if (mime.contains('markdown') || ext == 'md' || ext == 'markdown') {
    return 'md';
  }
  if (mime.contains('html') || ext == 'html' || ext == 'htm') return 'html';
  if (mime.contains('json') || ext == 'json') return 'json';
  if (mime.contains('csv') || ext == 'csv') return 'csv';
  return 'txt';
}

class WorkspaceView extends StatefulWidget {
  const WorkspaceView({
    super.key,
    required this.api,
    required this.sessionId,
    required this.files,
    required this.onClose,
    required this.onOpenBrowser,
    required this.canOpenBrowser,
  });

  final SidecarApi api;
  final String sessionId;
  final List<Map<String, dynamic>> files;
  final VoidCallback onClose;
  final ValueChanged<String> onOpenBrowser;
  final bool canOpenBrowser;

  @override
  State<WorkspaceView> createState() => _WorkspaceViewState();
}

class _WorkspaceViewState extends State<WorkspaceView> {
  int _token = 0;
  String? _selected;
  String _content = '';
  Map<String, dynamic> _file = {};
  int? _nextOffset;
  String? _error;
  bool _loading = false;
  bool _previewBusy = false;

  @override
  void didUpdateWidget(WorkspaceView old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) {
      _token++;
      _selected = null;
      _content = '';
      _file = {};
      _nextOffset = null;
      _error = null;
      _loading = false;
      _previewBusy = false;
      return;
    }
    if (_selected != null &&
        !widget.files.any((file) => _wsStr(file['id']) == _selected)) {
      _token++;
      _selected = null;
      _content = '';
      _file = {};
      _nextOffset = null;
      _error = null;
      _loading = false;
    }
  }

  @override
  void dispose() {
    _token++;
    super.dispose();
  }

  bool _current(int token, String id, String session) =>
      mounted &&
      token == _token &&
      _selected == id &&
      widget.sessionId == session;

  List<Map<String, dynamic>> get _ordered {
    final copy = [
      for (final file in widget.files) Map<String, dynamic>.from(file)
    ];
    final ranked = [
      for (var i = 0; i < copy.length; i++) (file: copy[i], index: i),
    ];
    ranked.sort((a, b) {
      final byStamp = _stamp(b.file).compareTo(_stamp(a.file));
      if (byStamp != 0) return byStamp;
      return a.index.compareTo(b.index);
    });
    return [for (final row in ranked) row.file];
  }

  List<Map<String, dynamic>> _area(String area) => [
        for (final file in _ordered)
          if (_wsStr(file['area']).isEmpty
              ? area == 'artifacts'
              : _wsStr(file['area']) == area)
            file,
      ];

  void _select(String id) {
    if (_selected == id) return;
    _token++;
    setState(() {
      _selected = id;
      _content = '';
      _file = {};
      _nextOffset = null;
      _error = null;
      _loading = true;
    });
    _load();
  }

  Future<void> _load({bool more = false}) async {
    final id = _selected;
    if (id == null || id.isEmpty) return;
    final token = _token;
    final session = widget.sessionId;
    final offset = more ? (_nextOffset ?? 0) : 0;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.request(
        '/workspace/${Uri.encodeComponent(id)}?offset=$offset',
      );
      if (!_current(token, id, session)) return;
      final chunk = data['content'] is String ? data['content'] as String : '';
      final next = data['next_offset'];
      int? nextOffset = next is num ? next.toInt() : null;
      if (more && chunk.isEmpty && nextOffset == offset) nextOffset = null;
      setState(() {
        _content = more ? '$_content$chunk' : chunk;
        final meta = _wsMap(data['file']);
        if (meta.isNotEmpty) _file = meta;
        _nextOffset = nextOffset;
        _loading = false;
      });
    } catch (error) {
      if (!_current(token, id, session)) return;
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _openPreview() async {
    final id = _selected;
    if (id == null || !widget.canOpenBrowser || _previewBusy) return;
    final token = _token;
    final session = widget.sessionId;
    setState(() => _previewBusy = true);
    try {
      final data = await widget.api.request(
        '/workspace/${Uri.encodeComponent(id)}/preview',
        body: const {},
      );
      if (!_current(token, id, session) || !widget.canOpenBrowser) return;
      final path = _wsStr(data['url']);
      if (path.isEmpty) {
        setState(() => _error = 'Preview URL missing');
        return;
      }
      widget.onOpenBrowser('http://127.0.0.1:${widget.api.port}$path');
    } catch (error) {
      if (_current(token, id, session)) setState(() => _error = '$error');
    } finally {
      if (_current(token, id, session)) setState(() => _previewBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.mutedForeground);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height),
      child: ColoredBox(
        color: scheme.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  GhostButton(
                    key: const Key('workspace-close'),
                    size: ButtonSize.small,
                    onPressed: widget.onClose,
                    child: const Text('Back to page'),
                  ),
                  Text(
                    'Workspace',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.foreground,
                    ),
                  ),
                  Text(
                    'Files in ~/.jet-browser/workspaces',
                    style: muted,
                  ),
                ],
              ),
            ),
            Expanded(
              child: widget.files.isEmpty
                  ? _empty(scheme)
                  : LayoutBuilder(builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 700;
                      final list = _sidebar(scheme, muted);
                      final preview = _preview(scheme, muted);
                      if (!wide) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 180),
                              child: list,
                            ),
                            const SizedBox(height: 8),
                            Expanded(child: preview),
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: 240, child: list),
                          Expanded(child: preview),
                        ],
                      );
                    }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Your agent workspace',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Ask the agent to save a document or create an artifact.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.mutedForeground),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebar(ColorScheme scheme, TextStyle muted) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [
        _areaBlock('Artifacts', _area('artifacts'), scheme, muted),
        _areaBlock('Scratch', _area('scratch'), scheme, muted),
      ],
    );
  }

  Widget _areaBlock(
    String label,
    List<Map<String, dynamic>> files,
    ColorScheme scheme,
    TextStyle muted,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child:
                Text(label, style: muted.copyWith(fontWeight: FontWeight.w600)),
          ),
          if (files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text('None', style: muted),
            ),
          for (final file in files) _fileButton(file, scheme, muted),
        ],
      ),
    );
  }

  Widget _fileButton(
    Map<String, dynamic> file,
    ColorScheme scheme,
    TextStyle muted,
  ) {
    final id = _wsStr(file['id']);
    final name = _wsStr(file['name']).isEmpty ? id : _wsStr(file['name']);
    final selected = id.isNotEmpty && id == _selected;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? scheme.muted : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: GhostButton(
        key: Key('workspace-file-$id'),
        size: ButtonSize.small,
        alignment: Alignment.centerLeft,
        onPressed: id.isEmpty ? null : () => _select(id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.foreground),
            ),
            Text(_fileSize(file['size']), style: muted),
          ],
        ),
      ),
    );
  }

  Widget _preview(ColorScheme scheme, TextStyle muted) {
    if (_selected == null) {
      return Center(
        child: Text('Select a file', style: muted.copyWith(fontSize: 13)),
      );
    }
    if (_loading && _content.isEmpty && _error == null) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_error != null && _content.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: muted.copyWith(fontSize: 13)),
            const SizedBox(height: 8),
            GhostButton(
              key: const Key('workspace-retry'),
              size: ButtonSize.small,
              onPressed: _load,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    final name = _wsStr(_file['name']).isEmpty
        ? _wsStr(_ordered.cast<Map<String, dynamic>?>().firstWhere(
              (file) => file != null && _wsStr(file['id']) == _selected,
              orElse: () => const {},
            )?['name'])
        : _wsStr(_file['name']);
    final shownName = name.isEmpty ? _selected! : name;
    final meta = _file.isEmpty
        ? _ordered.cast<Map<String, dynamic>>().firstWhere(
              (file) => _wsStr(file['id']) == _selected,
              orElse: () => const {},
            )
        : _file;
    final kind = _kind(meta, shownName);
    final bodyStyle = TextStyle(fontSize: 13, color: scheme.foreground);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  shownName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.foreground,
                  ),
                ),
              ),
              Text(_fileSize(meta['size'] ?? _file['size']), style: muted),
              GhostButton(
                key: const Key('workspace-open-browser'),
                size: ButtonSize.small,
                onPressed: widget.canOpenBrowser && !_previewBusy
                    ? _openPreview
                    : null,
                child: const Text('Open in browser'),
              ),
              if (!widget.canOpenBrowser)
                Text('Pause the browser job to open a tab', style: muted),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(_error!, style: muted.copyWith(fontSize: 13)),
                GhostButton(
                  key: const Key('workspace-retry'),
                  size: ButtonSize.small,
                  onPressed: _load,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: kind == 'md'
                ? ChatMarkdown(
                    text: _content,
                    onOpenLink:
                        widget.canOpenBrowser ? widget.onOpenBrowser : (_) {},
                  )
                : SelectableText(_content, style: bodyStyle),
          ),
        ),
        if (_nextOffset != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: GhostButton(
                key: const Key('workspace-more'),
                size: ButtonSize.small,
                onPressed: _loading ? null : () => _load(more: true),
                child: const Text('Load more'),
              ),
            ),
          ),
      ],
    );
  }
}
