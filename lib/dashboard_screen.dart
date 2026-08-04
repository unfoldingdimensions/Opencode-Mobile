import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notifications.dart';
import 'providers.dart';
import 'widgets.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  String? _shownPermissionId;

  @override
  void initState() {
    super.initState();
    NotificationService.instance.permissionTap.addListener(_onPermissionTap);
    final tap = NotificationService.instance.takePermissionTap();
    if (tap != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openPermissionFromTap(tap));
    }
  }

  @override
  void dispose() {
    NotificationService.instance.permissionTap.removeListener(_onPermissionTap);
    super.dispose();
  }

  void _onPermissionTap() {
    final id = NotificationService.instance.takePermissionTap();
    if (id != null && mounted) _openPermissionFromTap(id);
  }

  void _openPermissionFromTap(String id) {
    if (!mounted) return;
    final request = ref
        .read(pendingPermissionsProvider)
        .where((p) => p.id == id)
        .firstOrNull;
    if (request == null) return;
    _shownPermissionId = id;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => PermissionSheet(request: request),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Foreground permission handling: surface the newest pending request
    // as a bottom sheet once; it disappears when replied.
    ref.listen(pendingPermissionsProvider, (prev, next) {
      final first = next.firstOrNull;
      if (first == null) {
        _shownPermissionId = null;
      } else if (first.id != _shownPermissionId) {
        _shownPermissionId = first.id;
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => PermissionSheet(request: first),
        );
      }
    });

    final connection = ref.watch(connectionProvider);
    final busy = ref.watch(busyForSelectedProvider);
    final selectedId = ref.watch(selectedSessionIdProvider);
    final sessions = ref.watch(sessionListProvider);
    final current = sessions.value
        ?.where((s) => s.id == selectedId)
        .firstOrNull;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                current?.title ?? 'OpenCode Mirror',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (current?.directory != null)
                Text(
                  current!.directory!,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
            ],
          ),
          actions: [
            _ConnectionDot(phase: connection.phase),
            const SizedBox(width: 8),
            if (busy) ...[
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              IconButton(
                onPressed: () =>
                    ref.read(connectionProvider.notifier).abortCurrent(),
                icon: const Icon(Icons.stop_circle_outlined),
                tooltip: 'Abort the agent',
              ),
            ],
            IconButton(
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              icon: const Icon(Icons.dynamic_feed_outlined),
              tooltip: 'Sessions',
            ),
            IconButton(
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => const ComposerSettingsSheet(),
              ),
              icon: const Icon(Icons.tune),
              tooltip: 'Model, agent and effort',
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Log'),
              Tab(text: 'Diffs'),
            ],
          ),
        ),
        drawer: const _SessionDrawer(),
        body: Column(
          children: [
            if (connection.phase == ConnectionPhase.error)
              _ReconnectBanner(error: connection.error),
            const Expanded(
              child: TabBarView(
                children: [LogTab(), DiffsTab()],
              ),
            ),
          ],
        ),
        bottomNavigationBar: const Composer(),
      ),
    );
  }
}

// ------------------------------------------------------------ connection dot

class _ConnectionDot extends StatelessWidget {
  const _ConnectionDot({required this.phase});

  final ConnectionPhase phase;

  @override
  Widget build(BuildContext context) {
    final color = switch (phase) {
      ConnectionPhase.connected => const Color(0xFF43A047),
      ConnectionPhase.connecting => Colors.amber,
      _ => const Color(0xFFE53935),
    };
    return Center(
      child: Tooltip(
        message: switch (phase) {
          ConnectionPhase.connected => 'Connected',
          ConnectionPhase.connecting => 'Connecting…',
          ConnectionPhase.error => 'Connection error',
          ConnectionPhase.disconnected => 'Disconnected',
        },
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------- reconnect banner

class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.sync_problem, size: 16, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Connection lost — reconnecting…${error == null ? '' : ' ($error)'}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onErrorContainer),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ log tab

class LogTab extends ConsumerStatefulWidget {
  const LogTab({super.key});

  @override
  ConsumerState<LogTab> createState() => _LogTabState();
}

class _LogTabState extends ConsumerState<LogTab> {
  final _scroll = ScrollController();
  bool _stickToBottom = true;
  bool _allCollapsed = false;
  final _collapsedKeys = <String>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(logEntriesProvider, (prev, next) {
      if (_stickToBottom && next.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    });

    final entries = ref.watch(logEntriesProvider);
    if (entries.isEmpty) {
      return const EmptyState(
        icon: Icons.terminal,
        message: 'No output yet.\nSend a prompt or start a task on the desktop.',
      );
    }

    final groups = buildLogGroups(entries);
    return Column(
      children: [
        _LogToolbar(
          groupCount: groups.length,
          onCollapseAll: () => setState(() {
            _allCollapsed = true;
            _collapsedKeys.clear();
          }),
          onExpandAll: () => setState(() {
            _allCollapsed = false;
            _collapsedKeys.clear();
          }),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              final atBottom = notification.metrics.maxScrollExtent <= 0 ||
                  notification.metrics.pixels >=
                      notification.metrics.maxScrollExtent - 32;
              if (atBottom != _stickToBottom) {
                setState(() => _stickToBottom = atBottom);
              }
              return false;
            },
            child: Stack(
              children: [
                ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: groups.length,
                  itemBuilder: (_, index) {
                    final group = groups[index];
                    return MessageGroup(
                      group: group,
                      collapsed: _allCollapsed || _collapsedKeys.contains(group.key),
                      onToggle: () => setState(() {
                        if (!_collapsedKeys.remove(group.key)) {
                          _collapsedKeys.add(group.key);
                        }
                      }),
                    );
                  },
                ),
                if (!_stickToBottom)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FloatingActionButton.small(
                      heroTag: 'jump-bottom',
                      onPressed: () {
                        _scroll.animateTo(
                          _scroll.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      },
                      child: const Icon(Icons.arrow_downward),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LogToolbar extends StatelessWidget {
  const _LogToolbar({
    required this.groupCount,
    required this.onCollapseAll,
    required this.onExpandAll,
  });

  final int groupCount;
  final VoidCallback onCollapseAll;
  final VoidCallback onExpandAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        IconButton(
          onPressed: onCollapseAll,
          icon: const Icon(Icons.unfold_less),
          tooltip: 'Collapse all',
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: onExpandAll,
          icon: const Icon(Icons.unfold_more),
          tooltip: 'Expand all',
          visualDensity: VisualDensity.compact,
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text(
            '$groupCount message${groupCount == 1 ? '' : 's'}',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- diff tab

class DiffsTab extends ConsumerWidget {
  const DiffsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diffs = ref.watch(diffsProvider);
    return RefreshIndicator(
      onRefresh: () => ref.read(diffsProvider.notifier).refresh(),
      child: diffs.when(
        data: (list) => list.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 160),
                  EmptyState(
                    icon: Icons.difference_outlined,
                    message: 'No diffs yet.',
                  ),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: list.length,
                itemBuilder: (_, index) => DiffTile(diff: list[index]),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 160),
            EmptyState(
              icon: Icons.error_outline,
              message: 'Failed to load diffs:\n$error',
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ session drawer

class _SessionDrawer extends ConsumerWidget {
  const _SessionDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionListProvider);
    final selected = ref.watch(selectedSessionIdProvider);
    final scheme = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sessions', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Newest is auto-selected',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: sessions.when(
                data: (list) => list.isEmpty
                    ? const Center(child: Text('No sessions yet.'))
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, index) {
                          final session = list[index];
                          final isSelected = session.id == selected;
                          return ListTile(
                            selected: isSelected,
                            leading: Icon(
                              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                              size: 20,
                            ),
                            title: Text(session.title, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [
                                if (session.directory != null && session.directory!.isNotEmpty)
                                  session.directory!,
                                if (session.timeCreated > 0)
                                  timeAgo(DateTime.fromMillisecondsSinceEpoch(session.timeCreated)),
                              ].join(' · '),
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              ref.read(selectedSessionIdProvider.notifier).select(session.id);
                              Navigator.of(context).pop();
                            },
                          );
                        },
                      ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(child: Text('Failed: $error')),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('Disconnect'),
              onTap: () {
                ref.read(connectionProvider.notifier).disconnect();
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      ),
    );
  }
}
