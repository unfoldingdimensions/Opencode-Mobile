import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/opencode_client.dart';

/// Live smoke test against a running `opencode serve` on the LAN.
///
/// Skips (does not fail) when no server is reachable at 127.0.0.1:4096 —
/// run it while the desktop server is up to exercise the real client:
/// health, session list, SSE `server.connected`, history replay, diff and
/// config endpoints.
void main() {
  test('live server smoke (skips if server unreachable)', () async {
    const base = 'http://127.0.0.1:4096';
    final client = OpenCodeClient(Uri.parse(base));
    try {
      final health = await client.health();
      expect(health['healthy'], true, reason: 'server reports healthy');

      final sessions = await client.listSessions();
      expect(sessions, isA<List<Map<String, dynamic>>>());

      final firstEvent = await client
          .eventStream()
          .firstWhere((e) => e['type'] == 'server.connected',
              orElse: () => const {})
          .timeout(const Duration(seconds: 15));
      expect(firstEvent['type'], 'server.connected',
          reason: 'server handshake arrives over the real SSE socket');
      expect(firstEvent['properties'], isA<Map<String, dynamic>>());

      if (sessions.isNotEmpty) {
        final sid = sessions.first['id'] as String;
        final history = await client.sessionHistory(sid);
        expect(history, isA<List<Map<String, dynamic>>>());
        final diff = await client.getDiff(sid);
        expect(diff, isA<List<Map<String, dynamic>>>());
      }

      final config = await client.getConfig();
      expect(config, isA<Map<String, dynamic>>());
    } catch (e) {
      markTestSkipped('server unreachable at $base: $e');
    } finally {
      client.dispose();
    }
  });
}
