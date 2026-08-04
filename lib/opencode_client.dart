/// REST + SSE client for the OpenCode server (`opencode serve`).
///
/// Networking is fully isolated from the UI: the client is plain Dart, takes
/// a base URI, and exposes typed REST calls plus a single SSE stream with
/// capped reconnect backoff (1s → 30s).
///
/// SSE frames are delivered as raw JSON maps; the UI layer parses them via
/// [parseEvent]. Between reconnects the stream emits synthetic
/// `stream.connected` / `stream.reconnecting` events so the connection state
/// stays visible.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'models.dart';

class OpenCodeException implements Exception {
  OpenCodeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OpenCodeClient {
  OpenCodeClient(this.baseUri, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final Uri baseUri;
  final http.Client _http;
  bool _stop = false;

  static const _connectTimeout = Duration(seconds: 10);
  static const _idleTimeout = Duration(seconds: 45);
  static const _maxBackoff = Duration(seconds: 30);

  Uri _uri(String path) => baseUri.resolve(path);

  Map<String, String> get _jsonHeaders => const {'Accept': 'application/json'};

  // ---------------------------------------------------------------- helpers

  Future<dynamic> _get(String path) async {
    final res =
        await _http.get(_uri(path), headers: _jsonHeaders).timeout(_connectTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw OpenCodeException('GET $path → ${res.statusCode}');
    }
    return _decode(res.body);
  }

  Future<dynamic> _post(String path, [Map<String, dynamic>? body]) async {
    final res = await _http
        .post(
          _uri(path),
          headers: {'Accept': 'application/json', 'Content-Type': 'application/json'},
          body: body == null ? '' : jsonEncode(body),
        )
        .timeout(_connectTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw OpenCodeException('POST $path → ${res.statusCode}');
    }
    return _decode(res.body);
  }

  static dynamic _decode(String body) {
    if (body.isEmpty) return const <String, dynamic>{};
    try {
      return jsonDecode(body);
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  static List<Map<String, dynamic>> _asListOfMaps(dynamic value) {
    if (value is List) {
      return value.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    return const [];
  }

  // ------------------------------------------------------------------- REST

  /// `GET /global/health` — used by "Test Connection".
  Future<Map<String, dynamic>> health() async {
    final value = await _get('/global/health');
    return value is Map<String, dynamic> ? value : const <String, dynamic>{};
  }

  /// `GET /session` — all known sessions (newest first is not guaranteed;
  /// callers sort by `time.created`).
  Future<List<Map<String, dynamic>>> listSessions() async {
    return _asListOfMaps(await _get('/session'));
  }

  /// `GET /session/:id/message` — history replay for a session.
  Future<List<Map<String, dynamic>>> sessionHistory(String sessionId) async {
    return _asListOfMaps(await _get('/session/$sessionId/message'));
  }

  /// `POST /session/:id/prompt_async` — send a prompt. Async: the response
  /// arrives over the SSE stream, not here.
  ///
  /// `model` is optional; when omitted the server falls back to its default.
  Future<Map<String, dynamic>> sendPrompt(
    String sessionId, {
    ModelRef? model,
    required String text,
  }) async {
    final value = await _post('/session/$sessionId/prompt_async', {
      if (model != null)
        'model': {'providerID': model.providerID, 'modelID': model.modelID},
      'parts': [
        {'type': 'text', 'text': text},
      ],
    });
    return value is Map<String, dynamic> ? value : const <String, dynamic>{};
  }

  /// `POST /session/:id/abort` — stop the running agent.
  Future<void> abort(String sessionId) async {
    await _post('/session/$sessionId/abort');
  }

  /// `POST /session/:id/permissions/:permissionID` with
  /// `{"response": "once" | "always" | "reject"}`.
  Future<void> replyPermission(
    String sessionId,
    String permissionId,
    String response,
  ) async {
    await _post('/session/$sessionId/permissions/$permissionId', {
      'response': response,
    });
  }

  /// `GET /session/:id/diff` — snapshot diff for the diff tab.
  Future<List<Map<String, dynamic>>> getDiff(String sessionId) async {
    return _asListOfMaps(await _get('/session/$sessionId/diff'));
  }

  /// `GET /config` — fallback model info when no assistant message exists yet.
  Future<Map<String, dynamic>> getConfig() async {
    final value = await _get('/config');
    return value is Map<String, dynamic> ? value : const <String, dynamic>{};
  }

  // ------------------------------------------------------------------- SSE

  /// Single-subscription SSE stream (`GET /event`).
  ///
  /// Reconnects with capped backoff (1s → 30s) on drops. Between attempts it
  /// emits synthetic `stream.connected` / `stream.reconnecting` maps.
  Stream<Map<String, dynamic>> eventStream() {
    late final StreamController<Map<String, dynamic>> controller;
    controller = StreamController<Map<String, dynamic>>(
      onListen: () => _run(controller),
      onCancel: () => _stop = true,
    );
    return controller.stream;
  }

  Future<void> _run(StreamController<Map<String, dynamic>> controller) async {
    var backoff = const Duration(seconds: 1);
    while (!_stop && !controller.isClosed) {
      try {
        final request = http.Request('GET', _uri('/event'))
          ..headers['Accept'] = 'text/event-stream'
          ..headers['Cache-Control'] = 'no-cache';
        final response = await _http.send(request).timeout(_connectTimeout);
        if (response.statusCode != 200) {
          throw OpenCodeException('SSE → ${response.statusCode}');
        }
        backoff = const Duration(seconds: 1);
        _emit(controller, {'type': 'stream.connected'});
        await _drain(controller, response);
        if (_stop) break;
      } catch (e) {
        if (_stop || controller.isClosed) break;
        _emit(controller, {'type': 'stream.reconnecting', 'error': e.toString()});
        await Future<void>.delayed(backoff);
        backoff = Duration(
          seconds: math.min(backoff.inSeconds * 2, _maxBackoff.inSeconds),
        );
      }
    }
    if (!controller.isClosed) await controller.close();
  }

  Future<void> _drain(
    StreamController<Map<String, dynamic>> controller,
    http.StreamedResponse response,
  ) async {
    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(_idleTimeout);
    var dataLines = <String>[];
    await for (final line in lines) {
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          _emitFrame(controller, dataLines.join('\n'));
          dataLines = [];
        }
      } else if (line.startsWith('data:')) {
        final value = line.length > 5 && line[5] == ' ' ? line.substring(6) : line.substring(5);
        dataLines.add(value);
      } else if (line.startsWith(':')) {
        // Comment/heartbeat line — ignore.
      }
      // `event:`, `id:`, `retry:` fields are ignored; we only need `data`.
    }
  }

  void _emitFrame(StreamController<Map<String, dynamic>> controller, String data) {
    final trimmed = data.trim();
    if (trimmed.isEmpty) return;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) _emit(controller, decoded);
    } catch (_) {
      _emit(controller, {
        'type': 'parse.error',
        'data': trimmed.length > 300 ? trimmed.substring(0, 300) : trimmed,
      });
    }
  }

  static void _emit(StreamController<Map<String, dynamic>> controller, Map<String, dynamic> event) {
    if (!controller.isClosed) controller.add(event);
  }

  void dispose() {
    _stop = true;
    _http.close();
  }
}
