import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/event_parser.dart';
import 'package:opencode_mobile/models.dart';

/// Builds a real-shaped event envelope: `{id, type, properties}`.
Map<String, dynamic> envelope(String type, Map<String, dynamic> props) =>
    {'id': 'evt_1', 'type': type, 'properties': props};

void main() {
  group('parseEvent', () {
    test('message.part.updated text part → text entry', () {
      final ev = parseEvent(envelope('message.part.updated', {
        'sessionID': 'ses_abc',
        'time': 1700000000000,
        'part': {
          'id': 'prt_1',
          'sessionID': 'ses_abc',
          'messageID': 'msg_1',
          'type': 'text',
          'text': 'Hello from the agent',
        },
      }));

      expect(ev.entry.kind, LogKind.text);
      expect(ev.entry.text, 'Hello from the agent');
      expect(ev.entry.sessionID, 'ses_abc');
      expect(ev.sessionId, 'ses_abc');
    });

    test('permission.asked → PermissionRequest', () {
      final ev = parseEvent(envelope('permission.asked', {
        'id': 'per_1',
        'sessionID': 'ses_abc',
        'permission': 'bash',
        'patterns': ['bash'],
        'metadata': {'command': 'rm -rf ./dist'},
        'always': [],
        'tool': {'messageID': 'msg_1', 'callID': 'call_1'},
      }));

      expect(ev.permission, isNotNull);
      expect(ev.permission!.id, 'per_1');
      expect(ev.permission!.sessionID, 'ses_abc');
      expect(ev.permission!.permission, 'bash');
      expect(ev.permission!.patterns, ['bash']);
      expect(ev.entry.kind, LogKind.permission);
    });

    test('tool part completed → tool entry with status and output', () {
      final ev = parseEvent(envelope('message.part.updated', {
        'sessionID': 'ses_abc',
        'time': 1700000000000,
        'part': {
          'id': 'prt_2',
          'sessionID': 'ses_abc',
          'messageID': 'msg_2',
          'type': 'tool',
          'callID': 'call_1',
          'tool': 'bash',
          'state': {
            'status': 'completed',
            'input': {'command': 'ls'},
            'output': 'dist\nlib',
            'title': 'ls',
            'time': {'start': 1, 'end': 2},
            'metadata': {},
          },
        },
      }));

      expect(ev.entry.kind, LogKind.tool);
      expect(ev.entry.tool, 'bash');
      expect(ev.entry.toolState, 'completed');
      expect(ev.entry.toolOutput, 'dist\nlib');
    });

    test('assistant message.updated → model ref for composer inheritance', () {
      final ev = parseEvent(envelope('message.updated', {
        'sessionID': 'ses_abc',
        'info': {
          'id': 'msg_3',
          'role': 'assistant',
          'time': {'created': 1},
          'parentID': 'msg_1',
          'providerID': 'anthropic',
          'modelID': 'claude-sonnet-4-5',
          'mode': 'default',
          'agent': 'build',
          'path': {'cwd': '/x', 'root': '/x'},
          'cost': 0,
          'tokens': {},
        },
      }));

      expect(ev.model, isNotNull);
      expect(ev.model!.providerID, 'anthropic');
      expect(ev.model!.modelID, 'claude-sonnet-4-5');
    });

    test('malformed frame → raw entry, no throw', () {
      final ev = parseEvent({'type': 'message.part.updated', 'properties': 'not a map'});

      expect(ev.entry.kind, LogKind.raw);
      expect(ev.entry.rawJson, isNotNull);
    });

    test('unknown event type → raw entry, no throw', () {
      final ev = parseEvent(envelope('totally.new.event', {'sessionID': 'ses_abc'}));

      expect(ev.entry.kind, LogKind.raw);
      expect(ev.entry.rawJson, isNotNull);
    });

    test('garbage input → raw entry, no throw', () {
      final ev = parseEvent(const {});

      expect(ev.entry.kind, LogKind.raw);
      expect(ev.entry.rawJson, isNotNull);
    });

    test('session.idle → system entry with session id', () {
      final ev = parseEvent(envelope('session.idle', {'sessionID': 'ses_abc'}));

      expect(ev.entry.kind, LogKind.system);
      expect(ev.sessionId, 'ses_abc');
    });

    test('session.error → error entry, no throw on map payload', () {
      final ev = parseEvent(envelope('session.error', {
        'sessionID': 'ses_abc',
        'error': {'type': 'provider.auth', 'message': 'bad key'},
      }));

      expect(ev.entry.kind, LogKind.error);
      expect(ev.entry.text, contains('bad key'));
    });

    test('permission.replied → permissionId for pending-list cleanup', () {
      final ev = parseEvent(envelope('permission.replied', {
        'sessionID': 'ses_abc',
        'requestID': 'per_9',
        'reply': 'once',
      }));

      expect(ev.permissionId, 'per_9');
      expect(ev.entry.kind, LogKind.system);
      expect(ev.entry.text, contains('once'));
    });

    test('modelFromMessage: user message nests model under `model`', () {
      final model = modelFromMessage(const {
        'role': 'user',
        'model': {'providerID': 'openai', 'modelID': 'gpt-4o'},
      });

      expect(model, isNotNull);
      expect(model!.providerID, 'openai');
      expect(model.modelID, 'gpt-4o');
    });

    test('step-start part is lifecycle noise (empty system entry)', () {
      final ev = parseEvent(envelope('message.part.updated', {
        'sessionID': 'ses_abc',
        'time': 1700000000000,
        'part': {'id': 'prt_9', 'type': 'step-start'},
      }));

      expect(ev.entry.kind, LogKind.system);
      expect(ev.entry.text, isEmpty);
    });
  });
}
