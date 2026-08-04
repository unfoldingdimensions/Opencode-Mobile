import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/models.dart';
import 'package:opencode_mobile/providers.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(selectedSessionIdProvider.notifier).select('ses_1');
  });

  LogEntry textPart(String text,
      {String partID = 'prt_1', String messageID = 'msg_1'}) {
    return LogEntry(
      kind: LogKind.text,
      time: DateTime.now(),
      sessionID: 'ses_1',
      messageID: messageID,
      partID: partID,
      text: text,
    );
  }

  group('LogEntriesNotifier', () {
    test('streaming updates upsert by (session, message, part), keeping position', () {
      final log = container.read(logEntriesProvider.notifier);
      log.append(LogEntry(
        kind: LogKind.system,
        time: DateTime.now(),
        sessionID: 'ses_1',
        messageID: 'msg_1',
        role: 'assistant',
        text: '─ assistant message ─',
      ));
      log.append(textPart('Hello'));
      log.append(textPart('Hello, world')); // same part, newer full text
      log.append(textPart('Hello, world. This is the agent.'));

      final entries = container.read(logEntriesProvider);
      expect(entries.length, 2, reason: 'one header + one upserted text part');
      expect(entries[1].kind, LogKind.text);
      expect(entries[1].text, 'Hello, world. This is the agent.');
    });

    test('distinct parts of the same message stay separate', () {
      final log = container.read(logEntriesProvider.notifier);
      log.append(textPart('First part', partID: 'prt_a'));
      log.append(textPart('Second part', partID: 'prt_b'));

      final entries = container.read(logEntriesProvider);
      expect(entries.length, 2);
      expect(entries[0].text, 'First part');
      expect(entries[1].text, 'Second part');
    });

    test('tool part updates replace in place, latest state wins', () {
      final log = container.read(logEntriesProvider.notifier);
      LogEntry tool(String state) => LogEntry(
            kind: LogKind.tool,
            time: DateTime.now(),
            sessionID: 'ses_1',
            messageID: 'msg_1',
            partID: 'prt_tool',
            toolCallID: 'call_1',
            text: 'tool: bash ($state)',
            tool: 'bash',
            toolState: state,
          );
      log.append(tool('pending'));
      log.append(tool('running'));
      log.append(tool('completed'));

      final entries = container.read(logEntriesProvider);
      expect(entries.length, 1);
      expect(entries.single.toolState, 'completed');
      expect(entries.single.partID, 'prt_tool');
    });

    test('entries for a different session are dropped', () {
      final log = container.read(logEntriesProvider.notifier);
      log.append(LogEntry(
        kind: LogKind.text,
        time: DateTime.now(),
        sessionID: 'ses_OTHER',
        messageID: 'msg_x',
        text: 'other session',
      ));

      expect(container.read(logEntriesProvider), isEmpty);
    });

    test('empty system entries are dropped', () {
      final log = container.read(logEntriesProvider.notifier);
      log.append(LogEntry(kind: LogKind.system, time: DateTime.now(), text: ''));
      expect(container.read(logEntriesProvider), isEmpty);
    });

    test('switching sessions clears the log', () {
      final log = container.read(logEntriesProvider.notifier);
      log.append(textPart('before'));
      container.read(selectedSessionIdProvider.notifier).select('ses_2');

      expect(container.read(logEntriesProvider), isEmpty);
    });
  });
}
