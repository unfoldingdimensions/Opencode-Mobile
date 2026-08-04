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

/// A contiguous block of log entries belonging to one message (or one
/// standalone system line). Mirrors the desktop app's message layout.
class LogGroup {
  LogGroup(this.key, this.entries);

  final String key;
  final List<LogEntry> entries;

  String? get role {
    for (final e in entries) {
      if (e.role != null) return e.role;
    }
    return null;
  }

  DateTime? get time => entries.isEmpty ? null : entries.first.time;

  String? get modelTag {
    for (final e in entries) {
      if (e.role == 'assistant' && e.rawJson != null) {
        final provider = e.rawJson!['providerID']?.toString();
        final model = e.rawJson!['modelID']?.toString();
        if (provider != null && model != null && provider.isNotEmpty) {
          return '$provider/$model';
        }
      }
    }
    return null;
  }
}

/// Groups a flat entry list into message blocks. Entries with a `messageID`
/// join their message's group (even non-consecutively); entries without one
/// become standalone groups.
List<LogGroup> buildLogGroups(List<LogEntry> entries) {
  final byKey = <String, LogGroup>{};
  final groups = <LogGroup>[];
  for (final e in entries) {
    final messageID = e.messageID;
    if (messageID == null) {
      groups.add(LogGroup('s:${groups.length}', [e]));
      continue;
    }
    final group = byKey.putIfAbsent('m:$messageID', () {
      final g = LogGroup('m:$messageID', []);
      groups.add(g);
      return g;
    });
    group.entries.add(e);
  }
  return groups;
}

const _toolStateColors = <String, Color>{
  'pending': Color(0xFF9E9E9E),
  'running': Color(0xFF1E88E5),
  'completed': Color(0xFF43A047),
  'error': Color(0xFFE53935),
};

IconData _toolStateIcon(String? state) => switch (state) {
      'running' => Icons.sync,
      'completed' => Icons.check_circle_outline,
      'error' => Icons.error_outline,
      _ => Icons.schedule,
    };

/// Desktop-style message block: header (role · time · model) plus
/// bubble-rendered text, collapsible tool cards and collapsible reasoning.
class MessageGroup extends StatelessWidget {
  const MessageGroup({
    super.key,
    required this.group,
    required this.collapsed,
    required this.onToggle,
  });

  final LogGroup group;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final role = group.role;
    if (role == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final e in group.entries) LogTile(entry: e)],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MessageHeader(
          role: role,
          time: group.time,
          modelTag: group.modelTag,
          collapsed: collapsed,
          onToggle: onToggle,
        ),
        if (!collapsed) ..._renderedItems(context, role),
      ],
    );
  }

  List<Widget> _renderedItems(BuildContext context, String role) {
    final merged = _mergeEntries(group.entries);
    return [
      for (final e in merged)
        switch (e.kind) {
          LogKind.text => _TextBubble(role: role, text: e.text),
          LogKind.tool => _ToolCard(entry: e),
          LogKind.reasoning => _ReasoningBlock(text: e.text),
          _ => LogTile(entry: e),
        },
    ];
  }

  /// Filters out the "─ role message ─" header markers (the header renders
  /// them). Text/tool coalescing is gone: the log notifier upserts by
  /// `partID`, so each part is a single entry and merging would wrongly
  /// collapse distinct parts.
  List<LogEntry> _mergeEntries(List<LogEntry> entries) {
    return [
      for (final e in entries)
        if (!(e.kind == LogKind.system && e.role != null && e.text.startsWith('─'))) e,
    ];
  }
}

class _MessageHeader extends StatelessWidget {
  const _MessageHeader({
    required this.role,
    required this.time,
    required this.modelTag,
    required this.collapsed,
    required this.onToggle,
  });

  final String role;
  final DateTime? time;
  final String? modelTag;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final roleLabel = role.toUpperCase();
    final roleColor = switch (role) {
      'user' => scheme.primary,
      'assistant' => scheme.tertiary,
      _ => scheme.onSurfaceVariant,
    };
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Row(
          children: [
            AnimatedRotation(
              turns: collapsed ? -0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 4),
            Text(
              roleLabel,
              style: textTheme.labelMedium?.copyWith(
                color: roleColor,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(width: 8),
            if (time != null)
              Text(
                formatTime(time!),
                style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            const Spacer(),
            if (modelTag != null && modelTag!.isNotEmpty)
              Text(
                modelTag!,
                style: textTheme.labelSmall?.copyWith(color: scheme.outline),
              ),
          ],
        ),
      ),
    );
  }
}

class _TextBubble extends StatelessWidget {
  const _TextBubble({required this.role, required this.text});

  final String role;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = role == 'user';
    final background =
        isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final foreground = isUser ? scheme.onPrimaryContainer : scheme.onSurface;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.86,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: foreground),
        ),
      ),
    );
  }
}

class _ReasoningBlock extends StatefulWidget {
  const _ReasoningBlock({required this.text});

  final String text;

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<_ReasoningBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              children: [
                Icon(Icons.psychology_outlined, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  'Reasoning · ${widget.text.length} chars',
                  style: textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: _expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            padding: const EdgeInsets.all(8),
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: Text(
                widget.text,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.entry});

  final LogEntry entry;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final entry = widget.entry;
    final stateColor = _toolStateColors[entry.toolState] ?? scheme.onSurfaceVariant;
    final title = entry.toolTitle;
    final output = entry.toolOutput;
    final stateInput = entry.rawJson?['state'] is Map<String, dynamic>
        ? (entry.rawJson!['state'] as Map<String, dynamic>)['input']
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  Icon(_toolStateIcon(entry.toolState), size: 16, color: stateColor),
                  const SizedBox(width: 8),
                  Text(
                    entry.tool ?? 'tool',
                    style: textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: stateColor,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    entry.toolState ?? 'unknown',
                    style: textTheme.bodySmall?.copyWith(color: stateColor),
                  ),
                  const Spacer(),
                  if (title != null && title.isNotEmpty)
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            if (entry.toolState == 'error' && entry.rawJson != null)
              Padding(
                padding: const EdgeInsets.only(left: 28, bottom: 4),
                child: Text(
                  'error: ${entry.rawJson!['state'] is Map<String, dynamic> ? (entry.rawJson!['state'] as Map<String, dynamic>)['error'] : ''}',
                  style: textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            if (output != null && output.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(left: 28, bottom: 4),
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    output,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ),
            if (stateInput is Map<String, dynamic> && stateInput.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(left: 28, bottom: 4),
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(maxHeight: 160),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    'input: ${jsonEncode(stateInput)}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: scheme.outline,
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class LogTile extends StatelessWidget {
  const LogTile({super.key, required this.entry});

  final LogEntry entry;

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

// ------------------------------------------------------- composer settings

/// Model / agent / effort selectors, backed by the live server catalogs.
class ComposerSettingsSheet extends ConsumerStatefulWidget {
  const ComposerSettingsSheet({super.key});

  @override
  ConsumerState<ComposerSettingsSheet> createState() => _ComposerSettingsSheetState();
}

class _ComposerSettingsSheetState extends ConsumerState<ComposerSettingsSheet> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final models = ref.watch(modelCatalogProvider);
    final agents = ref.watch(agentCatalogProvider);
    final model = ref.watch(composerModelProvider);
    final agent = ref.watch(composerAgentProvider);
    final variant = ref.watch(composerVariantProvider);

    final selected = model == null
        ? null
        : models.value
            ?.where((m) => m.key == '${model.providerID}/${model.modelID}')
            .firstOrNull;
    var variants = selected?.variants ?? const <String>[];
    if (model != null && selected == null) {
      variants = const ['minimal', 'low', 'medium', 'high', 'max'];
    }

    final query = _query.text.trim().toLowerCase();
    final filtered = models.value
            ?.where((m) =>
                query.isEmpty ||
                m.displayName.toLowerCase().contains(query) ||
                m.modelID.toLowerCase().contains(query) ||
                m.providerID.toLowerCase().contains(query))
            .toList() ??
        const <ModelEntry>[];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Composer settings', style: textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  _sectionHeader('Model'),
                  _selectTile(
                    title: 'Auto (inherit from desktop)',
                    subtitle: model == null ? null : 'currently ${model.modelID}',
                    selected: model == null,
                    onTap: () =>
                        ref.read(composerModelProvider.notifier).clear(),
                  ),
                  TextField(
                    controller: _query,
                    decoration: const InputDecoration(
                      hintText: 'Search models…',
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 20),
                    ),
                  ),
                  const SizedBox(height: 4),
                  models.when(
                    data: (_) => filtered.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text('No models', style: textTheme.bodySmall),
                          )
                        : Column(
                            children: [
                              for (final m in filtered)
                                _selectTile(
                                  title: m.displayName,
                                  subtitle: '${m.providerName} · ${m.status ?? 'active'}',
                                  selected: model != null &&
                                      model.providerID == m.providerID &&
                                      model.modelID == m.modelID,
                                  onTap: () {
                                    ref.read(composerModelProvider.notifier).set(
                                          ModelRef(
                                              providerID: m.providerID,
                                              modelID: m.modelID),
                                        );
                                    if (variant != null && !m.variants.contains(variant)) {
                                      ref.read(composerVariantProvider.notifier).set(null);
                                    }
                                  },
                                ),
                            ],
                          ),
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (e, _) => Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('Failed to load models: $e', style: textTheme.bodySmall),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _sectionHeader('Agent'),
                  _selectTile(
                    title: 'Auto (default agent)',
                    selected: agent == null,
                    onTap: () => ref.read(composerAgentProvider.notifier).set(null),
                  ),
                  agents.when(
                    data: (list) => Column(
                      children: [
                        for (final a in list)
                          _selectTile(
                            title: a.name,
                            subtitle: a.description,
                            selected: agent == a.name,
                            onTap: () =>
                                ref.read(composerAgentProvider.notifier).set(a.name),
                          ),
                      ],
                    ),
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (e, _) => Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text('Failed to load agents: $e', style: textTheme.bodySmall),
                    ),
                  ),
                  if (variants.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _sectionHeader('Effort (variant)'),
                    _selectTile(
                      title: 'Default',
                      selected: variant == null,
                      onTap: () => ref.read(composerVariantProvider.notifier).set(null),
                    ),
                    for (final v in variants)
                      _selectTile(
                        title: v,
                        selected: variant == v,
                        onTap: () =>
                            ref.read(composerVariantProvider.notifier).set(v),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
        child: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );

  Widget _selectTile({
    required String title,
    String? subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        size: 20,
        color: selected ? scheme.primary : scheme.outline,
      ),
      title: Text(title, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      selected: selected,
      onTap: onTap,
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
