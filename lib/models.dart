/// Thin immutable types shared across the app.
///
/// Kept free of Flutter imports so they can be used from pure-Dart tests.
library;

enum LogKind {
  /// Informational lines (connection, session status, permission replies).
  system,

  /// Assistant/user text content.
  text,

  /// Dimmed reasoning content.
  reasoning,

  /// Tool invocation with a status chip (pending/running/completed/error).
  tool,

  /// Session-level errors.
  error,

  /// Lines derived from `permission.asked`.
  permission,

  /// Anything the parser could not interpret — raw JSON preserved so the
  /// user can still read it instead of the app crashing or dropping it.
  raw,
}

class LogEntry {
  const LogEntry({
    required this.kind,
    required this.time,
    this.sessionID,
    this.text = '',
    this.tool,
    this.toolState,
    this.toolTitle,
    this.toolOutput,
    this.rawJson,
  });

  final LogKind kind;
  final DateTime time;
  final String? sessionID;
  final String text;
  final String? tool;
  final String? toolState;
  final String? toolTitle;
  final String? toolOutput;

  /// The original payload for raw entries (and tool parts, for expansion).
  final Map<String, dynamic>? rawJson;
}

class ModelRef {
  const ModelRef({required this.providerID, required this.modelID});

  final String providerID;
  final String modelID;
}

class PermissionRequest {
  const PermissionRequest({
    required this.id,
    required this.sessionID,
    required this.permission,
    this.patterns = const [],
    this.always = const [],
    this.metadata,
    this.tool,
    required this.time,
  });

  final String id;
  final String sessionID;
  final String permission;
  final List<String> patterns;
  final List<String> always;
  final Map<String, dynamic>? metadata;

  /// `{messageID, callID}` identifying the tool call that asked.
  final Map<String, dynamic>? tool;
  final DateTime time;
}

class FileDiff {
  const FileDiff({
    required this.file,
    required this.patch,
    required this.additions,
    required this.deletions,
    required this.status,
  });

  final String file;
  final String patch;
  final int additions;
  final int deletions;

  /// `added` | `deleted` | `modified`.
  final String status;
}

class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    this.directory,
    this.path,
    this.timeCreated = 0,
    this.timeUpdated,
  });

  final String id;
  final String title;
  final String? directory;
  final String? path;
  final int timeCreated;
  final int? timeUpdated;
}
