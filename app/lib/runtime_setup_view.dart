import 'dart:async';

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'sidecar_api.dart';

const _requiredIds = {'qwen4b', 'qwen08b'};

class RuntimeSetupView extends StatefulWidget {
  const RuntimeSetupView({
    super.key,
    required this.api,
    required this.onContinue,
    required this.onOpenUrl,
  });

  final SidecarApi api;
  final VoidCallback onContinue;
  final void Function(String url) onOpenUrl;

  @override
  State<RuntimeSetupView> createState() => _RuntimeSetupViewState();
}

class _RuntimeSetupViewState extends State<RuntimeSetupView> {
  Timer? _timer;
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      final data = await widget.api.request('/setup');
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Setup status is unavailable right now.');
    } finally {
      _busy = false;
    }
  }

  Future<void> _post(String path, [Map<String, dynamic>? body]) async {
    if (_acting) return;
    setState(() => _acting = true);
    try {
      final data = await widget.api.request(path, body: body ?? {});
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'That setup action did not finish.');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      child: ColoredBox(
        color: scheme.background,
        child: Align(
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            padding: EdgeInsets.all(24.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Make Jet yours',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                      color: scheme.foreground,
                    ),
                  ),
                  SizedBox(height: 8.0),
                  Text(
                    'The browser and runtimes are included. Download the local models you want to use.',
                    style:
                        TextStyle(color: scheme.mutedForeground, height: 1.4),
                  ),
                  if (_data?['packaged'] == false) ...[
                    SizedBox(height: 8.0),
                    Text(
                      'Development runtime',
                      style: TextStyle(
                          fontSize: 12, color: scheme.mutedForeground),
                    ),
                  ],
                  SizedBox(height: 24.0),
                  if (_error != null) _errorBanner(scheme),
                  if (_data == null && _error == null)
                    Text(
                      'Preparing setup…',
                      style: TextStyle(color: scheme.mutedForeground),
                    )
                  else if (_data != null) ...[
                    _section(
                        scheme, 'Recommended', 'Required for the assistant'),
                    ..._rows(scheme, required: true),
                    SizedBox(height: 24.0),
                    _section(
                        scheme, 'Optional', 'Add these whenever you want them'),
                    ..._rows(scheme, required: false),
                    SizedBox(height: 24.0),
                    _grokCard(scheme),
                    SizedBox(height: 24.0),
                    if (!_requiredReady)
                      Padding(
                        padding: EdgeInsets.only(bottom: 8.0),
                        child: Text(
                          'You can browse now. The assistant starts after the recommended models finish downloading.',
                          style: TextStyle(
                              color: scheme.mutedForeground, height: 1.4),
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: PrimaryButton(
                        onPressed: widget.onContinue,
                        child: const Text('Open browser'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _requiredReady {
    final models = (_data?['models'] as List?) ?? const [];
    final installed = <String>{};
    for (final raw in models) {
      if (raw is Map && raw['status'] == 'installed') {
        installed.add('${raw['id']}');
      }
    }
    return _requiredIds.every(installed.contains);
  }

  Widget _errorBanner(ColorScheme scheme) {
    return Padding(
      padding: EdgeInsets.only(bottom: 16.0),
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child:
                    Text(_error!, style: TextStyle(color: scheme.destructive)),
              ),
              GhostButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(ColorScheme scheme, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: scheme.foreground)),
          Text(subtitle,
              style: TextStyle(fontSize: 13, color: scheme.mutedForeground)),
        ],
      ),
    );
  }

  List<Widget> _rows(ColorScheme scheme, {required bool required}) {
    final models = (_data?['models'] as List?) ?? const [];
    final rows = <Widget>[];
    for (final raw in models) {
      if (raw is! Map) continue;
      final id = '${raw['id']}';
      final isRequired = _requiredIds.contains(id);
      if (isRequired != required) continue;
      rows.add(Padding(
        padding: EdgeInsets.only(bottom: 8.0),
        child: _modelCard(scheme, Map<String, dynamic>.from(raw)),
      ));
    }
    if (rows.isEmpty) {
      rows.add(Text('Nothing in this group.',
          style: TextStyle(color: scheme.mutedForeground)));
    }
    return rows;
  }

  Widget _modelCard(ColorScheme scheme, Map<String, dynamic> model) {
    final id = '${model['id']}';
    final status = '${model['status']}';
    final received = (model['received'] as num?)?.toInt() ?? 0;
    final total = (model['total'] as num?)?.toInt() ??
        (model['bytes'] as num?)?.toInt() ??
        0;
    final bytes = (model['bytes'] as num?)?.toInt() ?? total;
    final active = _data?['downloading']?.toString();
    final showProgress = status == 'downloading' ||
        status == 'verifying' ||
        (received > 0 && status != 'installed');
    final fraction = total <= 0 ? 0.0 : (received / total).clamp(0.0, 1.0);
    final error = model['error']?.toString();
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${model['title'] ?? 'Model'}',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: scheme.foreground),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '${model['description'] ?? ''}',
                        style: TextStyle(
                            color: scheme.mutedForeground, height: 1.35),
                      ),
                      SizedBox(height: 4),
                      Text(_formatBytes(bytes),
                          style: TextStyle(
                              fontSize: 13, color: scheme.mutedForeground)),
                    ],
                  ),
                ),
                SizedBox(width: 8.0),
                _actions(id, status, received, total, active),
              ],
            ),
            if (showProgress) ...[
              SizedBox(height: 8.0),
              Text(
                status == 'verifying'
                    ? 'Checking ${_formatBytes(received)} / ${_formatBytes(total)}'
                    : '${_formatBytes(received)} / ${_formatBytes(total)}',
                style: TextStyle(fontSize: 12, color: scheme.mutedForeground),
              ),
              SizedBox(height: 6),
              _bar(scheme, fraction),
            ],
            if (error != null && error.isNotEmpty) ...[
              SizedBox(height: 8.0),
              Text(error,
                  style: TextStyle(color: scheme.destructive, height: 1.35)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _actions(
      String id, String status, int received, int total, String? active) {
    if (status == 'installed') {
      return Text('Ready');
    }
    if (status == 'downloading' || status == 'verifying') {
      return GhostButton(
        onPressed: _acting ? null : () => _post('/setup/cancel', const {}),
        child: const Text('Cancel'),
      );
    }
    final blocked = active != null && active.isNotEmpty && active != id;
    final resume = received > 0 && received < total;
    final label = status == 'failed'
        ? 'Retry'
        : resume || status == 'cancelled'
            ? 'Resume'
            : 'Download';
    final buttonChild = Text(label);
    void start() => _post('/setup/install', {'model_id': id});
    if (status == 'failed' || status == 'cancelled') {
      return SecondaryButton(
          onPressed: _acting || blocked ? null : start, child: buttonChild);
    }
    return PrimaryButton(
        onPressed: _acting || blocked ? null : start, child: buttonChild);
  }

  Widget _bar(ColorScheme scheme, double fraction) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: 6,
        width: double.infinity,
        child: ColoredBox(
          color: scheme.muted,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: fraction,
              heightFactor: 1,
              child: ColoredBox(color: scheme.primary),
            ),
          ),
        ),
      ),
    );
  }

  Widget _grokCard(ColorScheme scheme) {
    final grok = (_data?['grok'] as Map?) ?? const {};
    final available = grok['available'] == true;
    final authenticated = grok['authenticated'] == true ||
        grok['login_status'] == 'authenticated';
    final pending = grok['login_status'] == 'pending';
    final code = grok['user_code']?.toString();
    final url = grok['verification_url']?.toString();
    final error = grok['error']?.toString();
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Account',
                style: TextStyle(
                    fontWeight: FontWeight.w600, color: scheme.foreground)),
            SizedBox(height: 4),
            Text(
              authenticated
                  ? 'Signed in on this Mac.'
                  : available
                      ? 'Sign in to use the hosted assistant alongside local models.'
                      : 'Sign-in is not included in this runtime.',
              style: TextStyle(color: scheme.mutedForeground, height: 1.35),
            ),
            if (code != null && code.isNotEmpty) ...[
              SizedBox(height: 8.0),
              Text('Code $code',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: scheme.foreground)),
            ],
            if (pending && (code == null || code.isEmpty))
              Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: Text('Waiting for a sign-in code…',
                    style: TextStyle(color: scheme.mutedForeground)),
              ),
            if (error != null && error.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(top: 8.0),
                child: Text(error, style: TextStyle(color: scheme.destructive)),
              ),
            SizedBox(height: 8.0),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!authenticated && available)
                  SecondaryButton(
                    onPressed: _acting || pending
                        ? null
                        : () => _post('/setup/login', const {}),
                    child: const Text('Sign in'),
                  ),
                if (url != null && url.isNotEmpty)
                  GhostButton(
                    onPressed: () => widget.onOpenUrl(url),
                    child: const Text('Open sign-in link'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    const gib = 1024 * 1024 * 1024;
    const mib = 1024 * 1024;
    if (bytes >= gib) {
      final value = bytes / gib;
      return '${value.toStringAsFixed(value >= 10 ? 1 : 2)} GiB';
    }
    if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MiB';
    return '$bytes B';
  }
}
