/// Tolerant event parser: the core reliability decision of the app.
///
/// One `switch` on the `type` string, null-safe map lookups, and **any**
/// unrecognised event or malformed field becomes a raw-JSON log line rather
/// than an exception. This survives both unverified field names and future
/// OpenCode version drift — it degrades to "I can still see the JSON".
///
/// Pure Dart (no Flutter imports) so it runs under `flutter test`.
library;

import 'models.dart';

/// Result of parsing one SSE event payload.
class ParsedEvent {
  const ParsedEvent({
    required this.type,
    this.sessionId,
    required this.entry,
    this.permission,
    this.model,
  });

  final String type;
  final String? sessionId;
  final LogEntry entry;
  final PermissionRequest? permission;
  final ModelRef? model;
}

LogEntry _raw(Map<String, dynamic> raw) => LogEntry(
      kind: LogKind.raw,
      time: DateTime.now(),
      text: 'raw event',
      rawJson: raw,
    );

ParsedEvent _rawEvent(String type, Map<String, dynamic> raw) =>
    ParsedEvent(type: type, entry: _raw(raw));

DateTime _timeOf(Map<String, dynamic> props, [DateTime? fallback]) {
  final t = props['time'];
  if (t is num) return DateTime.fromMillisecondsSinceEpoch(t.round());
  return fallback ?? DateTime.now();
}

List<String> _strList(Object? value) {
  if (value is List) {
    return value.whereType<String>().toList(growable: false);
  }
  return const [];
}

String _short(Object? value, [int limit = 200]) {
  final s = value.toString();
  return s.length <= limit ? s : '${s.substring(0, limit)}…';
}

/// Parses one raw SSE event payload.
///
/// Never throws: every malformed or unknown payload degrades to a raw-JSON
/// log entry.
ParsedEvent parseEvent(Map<String, dynamic> raw) {
  final type = raw['type'];
  if (type is! String) return _rawEvent(type?.toString() ?? '?', raw);

  final props = raw['properties'];
  if (props is! Map<String, dynamic>) {
    return ParsedEvent(
      type: type,
      entry: LogEntry(
        kind: LogKind.raw,
        time: DateTime.now(),
        text: 'malformed properties',
        rawJson: raw,
      ),
    );
  }

  final sessionId = props['sessionID'] as String?;

  try {
    switch (type) {
      case 'message.part.updated':
        return _parsePartUpdated(raw, props, sessionId, type);

      case 'message.part.removed':
        return ParsedEvent(
          type: type,
          sessionId: sessionId,
          entry: LogEntry(
            kind: LogKind.system,
            time: _timeOf(props),
            sessionID: sessionId,
            text: 'part retracted (${props['messageID'] ?? '?'}/${props['partID'] ?? '?'})',
            rawJson: props,
          ),
        );

      case 'message.updated':
        return _parseMessageUpdated(raw, props, sessionId, type);

      case 'permission.asked':
        return _parsePermissionAsked(raw, props, sessionId, type);

      case 'permission.replied':
        return ParsedEvent(
          type: type,
          sessionId: sessionId,
          entry: LogEntry(
            kind: LogKind.system,
            time: DateTime.now(),
            sessionID: sessionId,
            text: 'permission ${props['requestID'] ?? '?'} → ${props['reply'] ?? '?'}',
            rawJson: props,
          ),
        );

      case 'session.status':
        return ParsedEvent(
          type: type,
          sessionId: sessionId,
          entry: LogEntry(
            kind: LogKind.system,
            time: _timeOf(props),
            sessionID: sessionId,
            text: 'status: ${_short(props['status'], 120)}',
            rawJson: props,
          ),
        );

      case 'session.idle':
        return ParsedEvent(
          type: type,
          sessionId: sessionId,
          entry: LogEntry(
            kind: LogKind.system,
            time: DateTime.now(),
            sessionID: sessionId,
            text: 'idle',
            rawJson: props,
          ),
        );

      case 'session.error':
        return ParsedEvent(
          type: type,
          sessionId: sessionId,
          entry: LogEntry(
            kind: LogKind.error,
            time: DateTime.now(),
            sessionID: sessionId,
            text: 'session error: ${_short(props['error'] ?? 'unknown')}',
            rawJson: props,
          ),
        );

      case 'todo.updated':
        final todos = props['todos'];
        final count = todos is List ? todos.length : 0;
        return ParsedEvent(
          type: type,
          sessionId: sessionId,
          entry: LogEntry(
            kind: LogKind.system,
            time: DateTime.now(),
            sessionID: sessionId,
            text: 'todos updated ($count item${count == 1 ? '' : 's'})',
            rawJson: props,
          ),
        );

      case 'server.connected':
        return ParsedEvent(
          type: type,
          sessionId: sessionId,
          entry: LogEntry(
            kind: LogKind.system,
            time: DateTime.now(),
            text: 'connected to server',
            rawJson: props,
          ),
        );

      default:
        return _rawEvent(type, raw);
    }
  } catch (_) {
    return _rawEvent(type, raw);
  }
}

ParsedEvent _parsePartUpdated(
  Map<String, dynamic> raw,
  Map<String, dynamic> props,
  String? sessionId,
  String type,
) {
  final part = props['part'];
  if (part is! Map<String, dynamic>) {
    return _rawEvent(type, raw);
  }

  final partType = part['type'];
  final time = _timeOf(props);
  final common = LogEntry(
    kind: LogKind.raw,
    time: time,
    sessionID: sessionId,
    rawJson: part,
  );

  switch (partType) {
    case 'text':
      final text = part['text'];
      if (text is! String || text.isEmpty) {
        return ParsedEvent(type: type, sessionId: sessionId, entry: common);
      }
      return ParsedEvent(
        type: type,
        sessionId: sessionId,
        entry: LogEntry(
          kind: LogKind.text,
          time: time,
          sessionID: sessionId,
          text: text,
          rawJson: part,
        ),
      );

    case 'reasoning':
      final text = part['text'];
      return ParsedEvent(
        type: type,
        sessionId: sessionId,
        entry: LogEntry(
          kind: LogKind.reasoning,
          time: time,
          sessionID: sessionId,
          text: text is String ? text : _short(part['text'] ?? '', 200),
          rawJson: part,
        ),
      );

    case 'tool':
      final state = part['state'];
      final stateMap = state is Map<String, dynamic> ? state : const <String, dynamic>{};
      final status = stateMap['status']?.toString() ?? 'unknown';
      final title = stateMap['title']?.toString();
      final tool = part['tool']?.toString() ?? '?';
      final output = stateMap['output'];
      final text = title == null || title.isEmpty
          ? 'tool: $tool ($status)'
          : 'tool: $tool ($status) — $title';
      return ParsedEvent(
        type: type,
        sessionId: sessionId,
        entry: LogEntry(
          kind: LogKind.tool,
          time: time,
          sessionID: sessionId,
          text: text,
          tool: tool,
          toolState: status,
          toolOutput: output?.toString(),
          rawJson: part,
        ),
      );

    default:
      // Other known part kinds (snapshot, patch, file, stepstart, …) are not
      // rendered specially; keep a compact marker plus the raw payload.
      return ParsedEvent(
        type: type,
        sessionId: sessionId,
        entry: LogEntry(
          kind: LogKind.system,
          time: time,
          sessionID: sessionId,
          text: '[part: $partType]',
          rawJson: part,
        ),
      );
  }
}

ParsedEvent _parseMessageUpdated(
  Map<String, dynamic> raw,
  Map<String, dynamic> props,
  String? sessionId,
  String type,
) {
  final info = props['info'];
  if (info is! Map<String, dynamic>) return _rawEvent(type, raw);

  final role = info['role']?.toString() ?? 'message';

  // Model inheritance: assistant messages carry providerID/modelID at the
  // top level; user messages nest them under `model`.
  ModelRef? model;
  if (role == 'assistant') {
    final providerID = info['providerID'];
    final modelID = info['modelID'];
    if (providerID is String && modelID is String && providerID.isNotEmpty) {
      model = ModelRef(providerID: providerID, modelID: modelID);
    }
  } else {
    final m = info['model'];
    if (m is Map<String, dynamic>) {
      final providerID = m['providerID'];
      final modelID = m['modelID'];
      if (providerID is String && modelID is String) {
        model = ModelRef(providerID: providerID, modelID: modelID);
      }
    }
  }

  final err = info['error'];
  return ParsedEvent(
    type: type,
    sessionId: sessionId,
    model: model,
    entry: err == null
        ? LogEntry(
            kind: LogKind.system,
            time: _timeOf(props),
            sessionID: sessionId,
            text: '─ $role message ─',
            rawJson: info,
          )
        : LogEntry(
            kind: LogKind.error,
            time: _timeOf(props),
            sessionID: sessionId,
            text: 'assistant error: ${_short(err)}',
            rawJson: info,
          ),
  );
}

ParsedEvent _parsePermissionAsked(
  Map<String, dynamic> raw,
  Map<String, dynamic> props,
  String? sessionId,
  String type,
) {
  final id = props['id'];
  if (id is! String || id.isEmpty) return _rawEvent(type, raw);

  final permission = props['permission']?.toString() ?? '?';
  final patterns = _strList(props['patterns']);
  final request = PermissionRequest(
    id: id,
    sessionID: sessionId ?? '',
    permission: permission,
    patterns: patterns,
    always: _strList(props['always']),
    metadata: props['metadata'] is Map<String, dynamic>
        ? props['metadata'] as Map<String, dynamic>
        : null,
    tool: props['tool'] is Map<String, dynamic>
        ? props['tool'] as Map<String, dynamic>
        : null,
    time: DateTime.now(),
  );

  return ParsedEvent(
    type: type,
    sessionId: sessionId,
    permission: request,
    entry: LogEntry(
      kind: LogKind.permission,
      time: request.time,
      sessionID: sessionId,
      text: 'permission: $permission${patterns.isEmpty ? '' : ' ${patterns.join(', ')}'}',
      rawJson: props,
    ),
  );
}
