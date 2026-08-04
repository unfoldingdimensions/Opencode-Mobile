import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Turns user input into a usable base URL: adds `http://` when no scheme
/// is present, strips a trailing slash.
String normalizeUrl(String input) {
  var url = input.trim();
  if (url.isEmpty) return url;
  if (!url.contains('://')) url = 'http://$url';
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key, this.initialUrl = '', this.initialError});

  final String initialUrl;
  final String? initialError;

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  late final TextEditingController _urlController;
  bool _testing = false;
  String? _testError;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.initialUrl);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String get _url => normalizeUrl(_urlController.text);

  Future<void> _test() async {
    final url = _url;
    if (url.isEmpty) {
      setState(() => _testError = 'Enter a server URL first.');
      return;
    }
    setState(() {
      _testing = true;
      _testError = null;
      _testResult = null;
    });
    final health = await ref.read(connectionProvider.notifier).testConnection(url);
    if (!mounted) return;
    setState(() {
      _testing = false;
      if (health == null) {
        _testError =
            'Cannot reach $url — is `opencode serve --hostname 0.0.0.0 --port 4096` running on the desktop?';
      } else {
        final version = health['version'];
        _testResult = version == null
            ? 'Server reachable.'
            : 'Server reachable — v$version';
      }
    });
  }

  Future<void> _connect() async {
    final url = _url;
    if (url.isEmpty) {
      setState(() => _testError = 'Enter a server URL first.');
      return;
    }
    FocusScope.of(context).unfocus();
    ref.read(connectionProvider.notifier).connect(url);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final error = widget.initialError;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.terminal, size: 56, color: scheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'OpenCode Mirror',
                    textAlign: TextAlign.center,
                    style: textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Connect to your desktop OpenCode server over Wi-Fi.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _urlController,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: '192.168.1.42:4096',
                      prefixIcon: Icon(Icons.lan_outlined),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _connect(),
                  ),
                  const SizedBox(height: 12),
                  if (error != null || _testError != null) ...[
                    _MessageCard(
                      kind: _MessageKind.error,
                      text: _testError ?? error!,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_testResult != null) ...[
                    _MessageCard(kind: _MessageKind.success, text: _testResult!),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _testing ? null : _test,
                          icon: _testing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.wifi_tethering),
                          label: const Text('Test Connection'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _connect,
                          icon: const Icon(Icons.link),
                          label: const Text('Connect'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Desktop: `opencode serve --hostname 0.0.0.0 --port 4096`\n'
                    'Your phone must be on the same Wi-Fi network.',
                    textAlign: TextAlign.center,
                    style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _MessageKind { error, success }

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.kind, required this.text});

  final _MessageKind kind;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, icon) = switch (kind) {
      _MessageKind.error => (scheme.errorContainer, Icons.error_outline),
      _MessageKind.success => (scheme.primaryContainer, Icons.check_circle_outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
