import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/models.dart';
import 'package:opencode_mobile/providers.dart';

void main() {
  group('messageTimeMs', () {
    test('parses time.created milliseconds', () {
      expect(ConnectionController.messageTimeMs({'time': {'created': 1700000000000}}),
          1700000000000);
      expect(ConnectionController.messageTimeMs({'time': {'created': 0}}), 0);
    });

    test('falls back to 0 for missing/malformed time', () {
      expect(ConnectionController.messageTimeMs({}), 0);
      expect(ConnectionController.messageTimeMs({'time': 'nope'}), 0);
      expect(ConnectionController.messageTimeMs({'time': {'created': 'nope'}}), 0);
      expect(ConnectionController.messageTimeMs({'time': {'updated': 5}}), 0);
    });
  });

  group('entriesFromMessage', () {
    test('stamps the message creation time, not DateTime.now()', () {
      final entries = ConnectionController.entriesFromMessage({
        'sessionID': 'ses_1',
        'id': 'msg_1',
        'role': 'assistant',
        'time': {'created': 1700000000000},
        'parts': [
          {
            'id': 'prt_1',
            'sessionID': 'ses_1',
            'messageID': 'msg_1',
            'type': 'text',
            'text': 'Hello',
          },
        ],
      });

      expect(entries.length, 2); // header + text part
      expect(entries[0].time, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(entries[1].time, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(entries[1].kind, LogKind.text);
      expect(entries[1].text, 'Hello');
    });

    test('history parts carry partID so live updates dedupe against them', () {
      final entries = ConnectionController.entriesFromMessage({
        'sessionID': 'ses_1',
        'id': 'msg_1',
        'role': 'assistant',
        'time': {'created': 1700000000000},
        'parts': [
          {
            'id': 'prt_a',
            'sessionID': 'ses_1',
            'messageID': 'msg_1',
            'type': 'text',
            'text': 'one',
          },
          {
            'id': 'prt_b',
            'sessionID': 'ses_1',
            'messageID': 'msg_1',
            'type': 'tool',
            'callID': 'call_1',
            'tool': 'bash',
            'state': {'status': 'completed', 'output': 'out'},
          },
        ],
      });

      expect(entries[1].partID, 'prt_a');
      expect(entries[2].partID, 'prt_b');
      expect(entries[2].kind, LogKind.tool);
      expect(entries[2].toolCallID, 'call_1');
    });

    test('error messages become a single error entry', () {
      final entries = ConnectionController.entriesFromMessage({
        'sessionID': 'ses_1',
        'id': 'msg_1',
        'role': 'assistant',
        'time': {'created': 1700000000000},
        'error': 'provider.auth: bad key',
      });

      expect(entries.length, 1);
      expect(entries.single.kind, LogKind.error);
      expect(entries.single.text, contains('bad key'));
    });

    test('missing time falls back to now (never throws)', () {
      final entries = ConnectionController.entriesFromMessage({
        'sessionID': 'ses_1',
        'id': 'msg_1',
        'role': 'user',
        'parts': [
          {'id': 'prt_1', 'messageID': 'msg_1', 'type': 'text', 'text': 'hi'},
        ],
      });

      final now = DateTime.now();
      expect(entries[1].time.difference(now).inSeconds.abs(), lessThan(5));
    });

    test('replay order: sort by creation time reproduces _replay ordering', () {
      final messages = [
        {
          'sessionID': 'ses_1',
          'id': 'msg_old',
          'role': 'user',
          'time': {'created': 1000},
          'parts': [
            {'id': 'prt_1', 'messageID': 'msg_old', 'type': 'text', 'text': 'first'},
          ],
        },
        {
          'sessionID': 'ses_1',
          'id': 'msg_new',
          'role': 'assistant',
          'time': {'created': 3000},
          'parts': [
            {'id': 'prt_2', 'messageID': 'msg_new', 'type': 'text', 'text': 'third'},
          ],
        },
        {
          'sessionID': 'ses_1',
          'id': 'msg_mid',
          'role': 'assistant',
          'time': {'created': 2000},
          'parts': [
            {'id': 'prt_3', 'messageID': 'msg_mid', 'type': 'text', 'text': 'second'},
          ],
        },
      ]..sort((a, b) =>
          ConnectionController.messageTimeMs(a).compareTo(ConnectionController.messageTimeMs(b)));

      final entries = [for (final m in messages) ...ConnectionController.entriesFromMessage(m)];
      expect(entries.where((e) => e.kind == LogKind.text).map((e) => e.text),
          ['first', 'second', 'third']);
    });
  });

  group('resolveSessionTarget', () {
    SessionSummary s(String id, int created) =>
        SessionSummary(id: id, title: id, timeCreated: created);

    // Newest-first, matching _selectNewest's sort.
    final sessions = [s('newest', 3000), s('middle', 2000), s('oldest', 1000)];

    test('keeps the current session when it still exists', () {
      expect(ConnectionController.resolveSessionTarget(sessions, 'middle'), 'middle');
      expect(ConnectionController.resolveSessionTarget(sessions, 'newest'), 'newest');
      expect(ConnectionController.resolveSessionTarget(sessions, 'oldest'), 'oldest');
    });

    test('falls back to the newest when the current id is gone (server restart)', () {
      expect(ConnectionController.resolveSessionTarget(sessions, 'dead-id'), 'newest');
    });

    test('picks the newest when nothing is selected yet', () {
      expect(ConnectionController.resolveSessionTarget(sessions, null), 'newest');
    });

    test('returns null for an empty list (do not deselect)', () {
      expect(ConnectionController.resolveSessionTarget(const [], 'middle'), isNull);
      expect(ConnectionController.resolveSessionTarget(const [], null), isNull);
    });
  });
}
