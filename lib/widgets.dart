import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'models.dart';
import 'providers.dart';

String formatTime(DateTime t) {
  final h = t.hour.toString().padLeft(2, '0');
  final m = t.minute.toString().padLeft(2, '0');
  final s = t.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}

String timeAgo(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

// ------------------------------------------------------------------ empty

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ log

class LogTile extends StatelessWidget {
  const LogTile({super.key, required this.entry});

  final LogEntry entry;

  static const _toolStateColors = <String, Color>{
    'pending': Color(0xFF9E9E9E),
    'running': Color(0xFF1E88E5),
    'completed': Color(0xFF43A047),
    'error': Color(0xFFE53935),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final time = formatTime(entry.time);

    switch (entry.kind) {
      case LogKind.text:
        return _LogRow(
          child: Text.rich(TextSpan(children: [
            TextSpan(
              text: '$time  ',
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            TextSpan(text: entry.text),
          ])),
        );

      case LogKind.reasoning:
        return _LogRow(
          child: Text.rich(TextSpan(children: [
            TextSpan(
              text: '$time  ',
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            TextSpan(
              text: '··· ${entry.text}',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ])),
        );

      case LogKind.tool:
        final stateColor = _toolStateColors[entry.toolState] ?? scheme.onSurfaceVariant;
        final icon = switch (entry.toolState) {
          'running' => Icons.sync,
          'completed' => Icons.check_circle_outline,
          'error' => Icons.error_outline,
          _ => Icons.schedule,
        };
        final title = entry.toolTitle;
        return _LogRow(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(time, style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(width: 8),
              Icon(icon, size: 16, color: stateColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(
                    text: '${entry.tool ?? 'tool'} ',
                    style: textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: stateColor,
                    ),
                  ),
                  TextSpan(
                    text: '(${entry.toolState ?? 'unknown'})',
                    style: textTheme.bodySmall?.copyWith(color: stateColor),
                  ),
                  if (title != null && title.isNotEmpty)
                    TextSpan(text: ' — $title', style: textTheme.bodySmall),
                ])),
              ),
            ],
          ),
        );

      case LogKind.error:
        return _LogRow(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(time, style: textTheme.bodySmall?.copyWith(color: scheme.error)),
              const SizedBox(width: 8),
              Icon(Icons.error_outline, size: 16, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.text,
                  style: textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            ],
          ),
        );

      case LogKind.permission:
        return _LogRow(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(time, style: textTheme.bodySmall?.copyWith(color: scheme.tertiary)),
              const SizedBox(width: 8),
              Icon(Icons.shield_outlined, size: 16, color: scheme.tertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.text,
                  style: textTheme.bodySmall?.copyWith(color: scheme.tertiary),
                ),
              ),
            ],
          ),
        );

      case LogKind.system:
        return _LogRow(
          child: Text(
            '$time  ${entry.text}',
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        );

      case LogKind.raw:
        final raw = entry.rawJson == null ? '' : jsonEncode(entry.rawJson);
        final shown = raw.length > 400 ? '${raw.substring(0, 400)}…' : raw;
        return _LogRow(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$time  raw event',
                style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 2),
              Text(
                shown,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ],
          ),
        );
    }
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: child,
    );
  }
}

// ------------------------------------------------------------------ diff

class DiffTile extends StatelessWidget {
  const DiffTile({super.key, required this.diff});

  final FileDiff diff;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final statusColor = switch (diff.status) {
      'added' => const Color(0xFF43A047),
      'deleted' => const Color(0xFFE53935),
      _ => scheme.primary,
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    diff.status,
                    style: textTheme.labelSmall?.copyWith(color: statusColor),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    diff.file,
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '+${diff.additions} −${diff.deletions}',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            if (diff.patch.isNotEmpty) ...[
              const SizedBox(height: 8),
              _PatchView(patch: diff.patch),
            ],
          ],
        ),
      ),
    );
  }
}

class _PatchView extends StatelessWidget {
  const _PatchView({required this.patch});

  final String patch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lines = patch.split('\n');
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 240),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        child: Text.rich(
          TextSpan(
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: scheme.onSurface,
            ),
            children: lines.map((line) {
              final style = line.startsWith('+')
                  ? TextStyle(color: dark ? const Color(0xFF81C784) : const Color(0xFF2E7D32))
                  : line.startsWith('-')
                      ? TextStyle(color: dark ? const Color(0xFFE57373) : const Color(0xFFC62828))
                      : line.startsWith('@@')
                          ? TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)
                          : TextStyle(color: scheme.onSurfaceVariant);
              return TextSpan(text: '$line\n', style: style);
            }).toList(),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- permissions

class PermissionSheet extends ConsumerWidget {
  const PermissionSheet({super.key, required this.request});

  final PermissionRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final metadata = request.metadata;

    void reply(String response) {
      ref.read(connectionProvider.notifier).replyPermission(request.id, response);
      Navigator.of(context).pop();
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, color: scheme.tertiary),
                const SizedBox(width: 8),
                Text('Permission requested', style: textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              request.permission,
              style: textTheme.titleLarge?.copyWith(
                fontFamily: 'monospace',
                color: scheme.tertiary,
              ),
            ),
            if (request.patterns.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: request.patterns
                    .map((p) => Chip(
                          label: Text(p, style: textTheme.labelSmall),
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
            ],
            if (metadata != null && metadata.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                jsonEncode(metadata),
                style: textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: () => reply('reject'),
                  child: Text('Reject', style: TextStyle(color: scheme.error)),
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () => reply('always'),
                  child: const Text('Always'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => reply('once'),
                  child: const Text('Allow once'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- composer

class Composer extends ConsumerStatefulWidget {
  const Composer({super.key});

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _text = TextEditingController();
  final _stt = stt.SpeechToText();
  bool _listening = false;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    _stt.cancel();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    final ok = await ref.read(connectionProvider.notifier).sendPrompt(text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) {
      _text.clear();
    } else {
      _snack('Not connected or no session selected');
    }
  }

  Future<void> _toggleMic() async {
    if (_listening) {
      await _stt.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    var ready = await _stt.initialize();
    if (!ready) {
      if (mounted) _snack('Speech recognition unavailable');
      return;
    }
    await _stt.listen(
      onResult: (result) {
        if (result.recognizedWords.isNotEmpty) {
          _text.text = result.recognizedWords;
        }
      },
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        listenMode: stt.ListenMode.dictation,
      ),
    );
    if (mounted) setState(() => _listening = true);
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final hasSession = ref.watch(selectedSessionIdProvider) != null;
    final canSend = conn.isConnected && hasSession && !_sending;

    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'Prompt the agent…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: _toggleMic,
                icon: Icon(
                  _listening ? Icons.mic : Icons.mic_none,
                  color: _listening ? Colors.redAccent : null,
                ),
                tooltip: _listening ? 'Stop listening' : 'Speak your prompt',
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                onPressed: canSend ? _send : null,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                tooltip: 'Send',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
