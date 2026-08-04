/// Riverpod state layer for OpenCode Mirror.
///
/// One controller (`ConnectionController`) owns the client lifecycle and SSE
/// subscription, and fans parsed events out to per-concern notifiers:
/// log buffer, pending permissions, per-session busy flags, session list,
/// diffs, selected session and the inherited composer model.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'event_parser.dart';
import 'models.dart';
import 'notifications.dart';
import 'opencode_client.dart';

const _kBaseUrlPrefsKey = 'baseUrl';

// ------------------------------------------------------------- connection

enum ConnectionPhase { disconnected, connecting, connected, error }

class ConnectionState {
  const ConnectionState({
    required this.phase,
    this.baseUrl,
    this.error,
    this.client,
  });

  final ConnectionPhase phase;
  final String? baseUrl;
  final String? error;
  final OpenCodeClient? client;

  bool get isConnected => phase == ConnectionPhase.connected;

  ConnectionState copyWith({ConnectionPhase? phase, String? error, OpenCodeClient? client}) =>
      ConnectionState(
        phase: phase ?? this.phase,
        baseUrl: baseUrl,
        error: error ?? this.error,
        client: client ?? this.client,
      );
}

/// Persisted server URL. Loaded once in `main()` and saved on connect.
class BaseUrlNotifier extends Notifier<String> {
  BaseUrlNotifier([this._initial = '']);

  final String _initial;

  @override
  String build() => _initial;

  Future<void> set(String url) async {
    state = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrlPrefsKey, url);
  }
}

final baseUrlProvider = NotifierProvider<BaseUrlNotifier, String>(BaseUrlNotifier.new);

class ConnectionController extends Notifier<ConnectionState> {
  OpenCodeClient? _client;
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  ConnectionState build() {
    ref.onDispose(_teardown);
    ref.listen(selectedSessionIdProvider, (prev, next) {
      if (next != null && next != prev) _replay(next);
    });
    final saved = ref.read(baseUrlProvider);
    if (saved.isNotEmpty) {
      Future.microtask(() => connect(saved));
    }
    return const ConnectionState(phase: ConnectionPhase.disconnected);
  }

  /// Health check only — used by the connect screen's "Test Connection".
  /// Returns the health payload (e.g. `{version: …}`) or `null` if the
  /// server is unreachable or the URL is invalid.
  Future<Map<String, dynamic>?> testConnection(String url) async {
    final base = Uri.tryParse(url);
    if (base == null || !base.hasScheme) return null;
    final probe = OpenCodeClient(base);
    try {
      return await probe.health();
    } catch (_) {
      return null;
    } finally {
      probe.dispose();
    }
  }

  /// Full connect: health check, persist URL, open SSE, load sessions,
  /// auto-select the newest, replay its history.
  Future<void> connect(String url) async {
    _teardown();
    final base = Uri.tryParse(url);
    if (base == null || !base.hasScheme) {
      state = const ConnectionState(
        phase: ConnectionPhase.error,
        error: 'Invalid URL — expected http://host:port',
      );
      return;
    }
    final client = OpenCodeClient(base);
    _client = client;
    state = ConnectionState(phase: ConnectionPhase.connecting, baseUrl: url, client: client);
    try {
      await client.health();
    } catch (e) {
      state = ConnectionState(phase: ConnectionPhase.error, error: 'Unreachable: $e');
      _client = null;
      return;
    }
    unawaited(ref.read(baseUrlProvider.notifier).set(url));
    _sub = client.eventStream().listen(_onEvent, onError: (_) {}, onDone: () {});
    state = ConnectionState(phase: ConnectionPhase.connected, baseUrl: url, client: client);
    unawaited(NotificationService.instance.startKeepalive());
    ref.invalidate(modelCatalogProvider);
    ref.invalidate(agentCatalogProvider);
    _selectNewest();
  }

  void disconnect() {
    unawaited(NotificationService.instance.stopKeepalive());
    _teardown();
    state = const ConnectionState(phase: ConnectionPhase.disconnected);
  }

  void _teardown() {
    _sub?.cancel();
    _sub = null;
    _client?.dispose();
    _client = null;
  }

  void _onEvent(Map<String, dynamic> raw) {
    final type = raw['type'];
    switch (type) {
      case 'stream.connected':
        state = state.copyWith(phase: ConnectionPhase.connected);
        ref.invalidate(sessionListProvider);
        return;
      case 'stream.reconnecting':
        state = state.copyWith(
          phase: ConnectionPhase.error,
          error: 'Connection lost — reconnecting (${raw['error'] ?? '…'})',
        );
        return;
    }

    final parsed = parseEvent(raw);
    ref.read(logEntriesProvider.notifier).append(parsed.entry);

    final inBackground =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

    final permission = parsed.permission;
    if (permission != null) {
      ref.read(pendingPermissionsProvider.notifier).add(permission);
      if (inBackground) {
        unawaited(NotificationService.instance.showPermission(permission));
      }
    }
    final permissionId = parsed.permissionId;
    if (permissionId != null) {
      ref.read(pendingPermissionsProvider.notifier).remove(permissionId);
      unawaited(NotificationService.instance.cancelPermission());
    }
    final model = parsed.model;
    if (model != null) {
      ref.read(composerModelProvider.notifier).set(model);
    }

    final sessionId = parsed.sessionId;
    switch (parsed.type) {
      case 'session.status':
        if (sessionId != null) {
          ref.read(sessionBusyProvider.notifier).setBusy(sessionId, true);
        }
        ref.invalidate(sessionListProvider);
      case 'session.idle':
        if (sessionId != null) {
          ref.read(sessionBusyProvider.notifier).setBusy(sessionId, false);
          if (sessionId == ref.read(selectedSessionIdProvider)) {
            ref.invalidate(diffsProvider);
          }
        }
        if (inBackground) {
          unawaited(NotificationService.instance.showIdle('The agent finished its task.'));
        }
        ref.invalidate(sessionListProvider);
      case 'session.error':
        if (sessionId != null) {
          ref.read(sessionBusyProvider.notifier).setBusy(sessionId, false);
        }
        if (inBackground) {
          unawaited(NotificationService.instance.showError(parsed.entry.text));
        }
      case 'server.connected':
        ref.invalidate(sessionListProvider);
    }
  }

  Future<void> _selectNewest() async {
    final client = _client;
    if (client == null) return;
    try {
      final raw = await client.listSessions();
      if (raw.isEmpty) return;
      final sessions = raw.map(_sessionFromRaw).toList()
        ..sort((a, b) => b.timeCreated.compareTo(a.timeCreated));
      final current = ref.read(selectedSessionIdProvider);
      final target = sessions.any((s) => s.id == current)
          ? current
          : sessions.first.id;
      if (target != current) {
        ref.read(selectedSessionIdProvider.notifier).select(target);
      }
    } catch (_) {
      // Session list refresh will surface errors in the log.
    }
  }

  Future<void> _replay(String sessionId) async {
    final client = _client;
    if (client == null) return;
    try {
      final messages = await client.sessionHistory(sessionId);
      final entries = <LogEntry>[];
      for (final message in messages) {
        entries.addAll(_entriesFromMessage(message));
        final model = modelFromMessage(message);
        if (model != null) {
          ref.read(composerModelProvider.notifier).set(model);
        }
      }
      if (entries.isNotEmpty) {
        ref.read(logEntriesProvider.notifier).replaceAll(entries);
      }
    } catch (e) {
      ref.read(logEntriesProvider.notifier).append(LogEntry(
        kind: LogKind.error,
        time: DateTime.now(),
        sessionID: sessionId,
        text: 'history load failed: $e',
      ));
    }
  }

  List<LogEntry> _entriesFromMessage(Map<String, dynamic> message) {
    final sessionID = message['sessionID'] as String?;
    final messageID = message['id']?.toString();
    final role = message['role']?.toString() ?? 'message';
    final out = <LogEntry>[];
    if (message['error'] != null) {
      out.add(LogEntry(
        kind: LogKind.error,
        time: DateTime.now(),
        sessionID: sessionID,
        messageID: messageID,
        role: role,
        text: '$role error: ${message['error']}',
        rawJson: message,
      ));
      return out;
    }
    out.add(LogEntry(
      kind: LogKind.system,
      time: DateTime.now(),
      sessionID: sessionID,
      messageID: messageID,
      role: role,
      text: '─ $role message ─',
      rawJson: message,
    ));
    final parts = message['parts'];
    if (parts is List) {
      for (final p in parts.whereType<Map<String, dynamic>>()) {
        final partType = p['type'];
        final partMessageID = p['messageID']?.toString() ?? messageID;
        if (partType == 'text' && p['text'] is String) {
          out.add(LogEntry(
            kind: LogKind.text,
            time: DateTime.now(),
            sessionID: sessionID,
            messageID: partMessageID,
            role: role,
            text: p['text'] as String,
            rawJson: p,
          ));
        } else if (partType == 'reasoning' && p['text'] is String) {
          out.add(LogEntry(
            kind: LogKind.reasoning,
            time: DateTime.now(),
            sessionID: sessionID,
            messageID: partMessageID,
            role: role,
            text: p['text'] as String,
            rawJson: p,
          ));
        } else if (partType == 'tool') {
          final state = p['state'];
          final stateMap = state is Map<String, dynamic> ? state : const <String, dynamic>{};
          final status = stateMap['status']?.toString() ?? 'unknown';
          final title = stateMap['title']?.toString();
          out.add(LogEntry(
            kind: LogKind.tool,
            time: DateTime.now(),
            sessionID: sessionID,
            messageID: partMessageID,
            role: role,
            text: 'tool: ${p['tool'] ?? '?'} ($status)${title == null || title.isEmpty ? '' : ' — $title'}',
            tool: p['tool']?.toString(),
            toolCallID: p['callID']?.toString(),
            toolState: status,
            toolTitle: title,
            toolOutput: stateMap['output']?.toString(),
            rawJson: p,
          ));
        } else if (partType == 'step-start' ||
            partType == 'step-finish' ||
            partType == 'snapshot') {
          // Lifecycle noise — skip in history replay too.
        } else {
          out.add(LogEntry(
            kind: LogKind.system,
            time: DateTime.now(),
            sessionID: sessionID,
            messageID: partMessageID,
            role: role,
            text: '[part: $partType]',
            rawJson: p,
          ));
        }
      }
    }
    return out;
  }

  // ------------------------------------------------------------- actions

  Future<bool> sendPrompt(String text) async {
    final client = _client;
    final sessionId = ref.read(selectedSessionIdProvider);
    if (client == null || sessionId == null) return false;
    var model = ref.read(composerModelProvider);
    model ??= await _modelFromConfig(client);
    final agent = ref.read(composerAgentProvider);
    final variant = ref.read(composerVariantProvider);
    await client.sendPrompt(
      sessionId,
      model: model,
      agent: agent,
      variant: variant,
      text: text,
    );
    return true;
  }

  Future<void> abortCurrent() async {
    final client = _client;
    final sessionId = ref.read(selectedSessionIdProvider);
    if (client == null || sessionId == null) return;
    await client.abort(sessionId);
  }

  Future<void> replyPermission(String permissionId, String response) async {
    final client = _client;
    if (client == null) return;
    final sessionId = ref.read(selectedSessionIdProvider);
    final request = ref
        .read(pendingPermissionsProvider)
        .where((p) => p.id == permissionId)
        .firstOrNull;
    final targetSession = request?.sessionID.isNotEmpty == true
        ? request!.sessionID
        : sessionId;
    if (targetSession == null) return;
    await client.replyPermission(targetSession, permissionId, response);
  }

  Future<ModelRef?> _modelFromConfig(OpenCodeClient client) async {
    try {
      final config = await client.getConfig();
      final m = config['model'];
      if (m is Map<String, dynamic>) {
        final providerID = m['providerID'];
        final modelID = m['modelID'];
        if (providerID is String && modelID is String && providerID.isNotEmpty) {
          return ModelRef(providerID: providerID, modelID: modelID);
        }
      }
    } catch (_) {}
    return null;
  }
}

final connectionProvider =
    NotifierProvider<ConnectionController, ConnectionState>(ConnectionController.new);

// ------------------------------------------------------------- session list

SessionSummary _sessionFromRaw(Map<String, dynamic> raw) {
  final time = raw['time'];
  final timeMap = time is Map<String, dynamic> ? time : const <String, dynamic>{};
  final directory = raw['directory']?.toString();
  final title = raw['title']?.toString();
  return SessionSummary(
    id: raw['id']?.toString() ?? '',
    title: title != null && title.isNotEmpty
        ? title
        : _titleFallback(directory, raw['id']?.toString()),
    directory: directory,
    path: raw['path']?.toString(),
    timeCreated: (timeMap['created'] as num?)?.toInt() ?? 0,
    timeUpdated: (timeMap['updated'] as num?)?.toInt(),
  );
}

String _titleFallback(String? directory, String? id) {
  if (directory != null && directory.isNotEmpty) {
    final normalized = directory.replaceAll('\\', '/');
    final parts = normalized.split('/');
    if (parts.isNotEmpty && parts.last.isNotEmpty) return parts.last;
  }
  return id ?? '?';
}

class SessionListNotifier extends AsyncNotifier<List<SessionSummary>> {
  @override
  Future<List<SessionSummary>> build() async {
    final client = ref.watch(connectionProvider.select((s) => s.client));
    if (client == null) return const [];
    final raw = await client.listSessions();
    final sessions = raw.map(_sessionFromRaw).toList()
      ..sort((a, b) => b.timeCreated.compareTo(a.timeCreated));
    return sessions;
  }
}

final sessionListProvider =
    AsyncNotifierProvider<SessionListNotifier, List<SessionSummary>>(SessionListNotifier.new);

// ------------------------------------------------------- selected session

class SelectedSessionNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) {
    if (state == id) return;
    state = id;
  }
}

final selectedSessionIdProvider =
    NotifierProvider<SelectedSessionNotifier, String?>(SelectedSessionNotifier.new);

// ------------------------------------------------------------------- log

class LogEntriesNotifier extends Notifier<List<LogEntry>> {
  static const _maxEntries = 1000;

  @override
  List<LogEntry> build() {
    ref.listen(selectedSessionIdProvider, (prev, next) {
      if (prev != next) state = const [];
    });
    return const [];
  }

  /// Appends entries for the selected session; system-wide entries (no
  /// sessionID) always pass through. Empty system entries (lifecycle noise)
  /// are dropped.
  void append(LogEntry entry) {
    if (entry.kind == LogKind.system && entry.text.isEmpty) return;
    final selected = ref.read(selectedSessionIdProvider);
    if (entry.sessionID != null && entry.sessionID != selected) return;
    final next = [...state, entry];
    state = next.length > _maxEntries ? next.sublist(next.length - _maxEntries) : next;
  }

  void replaceAll(List<LogEntry> entries) {
    state = entries.length > _maxEntries
        ? entries.sublist(entries.length - _maxEntries)
        : entries;
  }

  void clear() => state = const [];
}

final logEntriesProvider =
    NotifierProvider<LogEntriesNotifier, List<LogEntry>>(LogEntriesNotifier.new);

// ------------------------------------------------------------ permissions

class PendingPermissionsNotifier extends Notifier<List<PermissionRequest>> {
  @override
  List<PermissionRequest> build() => const [];

  void add(PermissionRequest request) => state = [...state, request];

  void remove(String id) =>
      state = state.where((p) => p.id != id).toList(growable: false);

  void clear() => state = const [];
}

final pendingPermissionsProvider =
    NotifierProvider<PendingPermissionsNotifier, List<PermissionRequest>>(
        PendingPermissionsNotifier.new);

// ---------------------------------------------------------------- busy map

class SessionBusyNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  void setBusy(String sessionId, bool busy) {
    if (state[sessionId] == busy) return;
    state = {...state, sessionId: busy};
  }
}

final sessionBusyProvider =
    NotifierProvider<SessionBusyNotifier, Map<String, bool>>(SessionBusyNotifier.new);

final busyForSelectedProvider = Provider<bool>((ref) {
  final id = ref.watch(selectedSessionIdProvider);
  if (id == null) return false;
  return ref.watch(sessionBusyProvider)[id] ?? false;
});

// ------------------------------------------------------------------ diffs

class DiffsNotifier extends AsyncNotifier<List<FileDiff>> {
  @override
  Future<List<FileDiff>> build() => _fetch();

  Future<List<FileDiff>> _fetch() async {
    final client = ref.read(connectionProvider).client;
    final sessionId = ref.read(selectedSessionIdProvider);
    if (client == null || sessionId == null) return const [];
    final raw = await client.getDiff(sessionId);
    return raw
        .map((d) => FileDiff(
              file: d['file']?.toString() ?? '?',
              patch: d['patch']?.toString() ?? '',
              additions: (d['additions'] as num?)?.toInt() ?? 0,
              deletions: (d['deletions'] as num?)?.toInt() ?? 0,
              status: d['status']?.toString() ?? 'modified',
            ))
        .toList(growable: false);
  }

  /// Pull-to-refresh: refetch without waiting for an invalidation cycle.
  Future<void> refresh() async {
    try {
      final next = await _fetch();
      if (ref.mounted) state = AsyncData(next);
    } catch (e, st) {
      if (ref.mounted) state = AsyncError(e, st);
    }
  }
}

final diffsProvider =
    AsyncNotifierProvider<DiffsNotifier, List<FileDiff>>(DiffsNotifier.new);

// ------------------------------------------------------- composer model

class ComposerModelNotifier extends Notifier<ModelRef?> {
  @override
  ModelRef? build() => null;

  void set(ModelRef model) => state = model;

  void clear() => state = null;
}

/// Last model seen in the selected session's messages — the phone inherits
/// whatever the desktop is using, no model picker needed.
final composerModelProvider =
    NotifierProvider<ComposerModelNotifier, ModelRef?>(ComposerModelNotifier.new);

class ComposerAgentNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? agent) => state = agent;
}

/// Selected agent (build/plan/…); null = server default.
final composerAgentProvider =
    NotifierProvider<ComposerAgentNotifier, String?>(ComposerAgentNotifier.new);

class ComposerVariantNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? variant) => state = variant;
}

/// Selected reasoning effort (model variant); null = model default.
final composerVariantProvider =
    NotifierProvider<ComposerVariantNotifier, String?>(ComposerVariantNotifier.new);

// --------------------------------------------------------------- catalogs

class ModelCatalogNotifier extends AsyncNotifier<List<ModelEntry>> {
  @override
  Future<List<ModelEntry>> build() async {
    final client = ref.read(connectionProvider).client;
    if (client == null) return const [];
    final providers = await client.getProviders();
    final entries = <ModelEntry>[];
    for (final provider in providers) {
      final providerID = provider['id']?.toString() ?? '';
      final providerName = provider['name']?.toString() ?? providerID;
      final models = provider['models'];
      if (models is Map<String, dynamic>) {
        for (final model in models.values) {
          if (model is! Map<String, dynamic>) continue;
          final modelID = model['id']?.toString() ?? '';
          if (modelID.isEmpty) continue;
          final variantsRaw = model['variants'];
          entries.add(ModelEntry(
            providerID: providerID,
            providerName: providerName,
            modelID: modelID,
            name: model['name']?.toString(),
            status: model['status']?.toString(),
            variants: variantsRaw is Map<String, dynamic>
                ? variantsRaw.keys.toList(growable: false)
                : const [],
          ));
        }
      }
    }
    return entries;
  }
}

final modelCatalogProvider =
    AsyncNotifierProvider<ModelCatalogNotifier, List<ModelEntry>>(ModelCatalogNotifier.new);

class AgentCatalogNotifier extends AsyncNotifier<List<AgentInfo>> {
  @override
  Future<List<AgentInfo>> build() async {
    final client = ref.read(connectionProvider).client;
    if (client == null) return const [];
    final agents = await client.getAgents();
    return agents
        .map((a) => AgentInfo(
              name: a['name']?.toString() ?? '',
              mode: a['mode']?.toString(),
              description: a['description']?.toString(),
            ))
        .where((a) => a.name.isNotEmpty)
        .toList(growable: false);
  }
}

final agentCatalogProvider =
    AsyncNotifierProvider<AgentCatalogNotifier, List<AgentInfo>>(AgentCatalogNotifier.new);
