import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/main.dart';
import 'package:opencode_mobile/providers.dart';

/// A controller pinned to a fixed phase, so HomeGate routing can be tested
/// without touching the network.
class _FixedConnectionController extends ConnectionController {
  _FixedConnectionController(this._state);

  final ConnectionState _state;

  @override
  ConnectionState build() => _state;
}

void main() {
  Widget app(ConnectionState state) => ProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => _FixedConnectionController(state)),
          baseUrlProvider.overrideWith(() => BaseUrlNotifier('')),
        ],
        child: const OpenCodeMirrorApp(),
      );

  testWidgets('transient reconnect keeps the dashboard mounted', (tester) async {
    await tester.pumpWidget(app(const ConnectionState(
      phase: ConnectionPhase.reconnecting,
      baseUrl: 'http://10.0.0.5:4096',
      error: 'socket closed',
    )));
    await tester.pumpAndSettle();

    expect(find.text('Log'), findsOneWidget, reason: 'dashboard tab bar is up');
    expect(find.text('Diffs'), findsOneWidget);
    expect(find.text('Prompt the agent…'), findsOneWidget, reason: 'composer is up');
    expect(
      find.text('Connection lost — reconnecting… (socket closed)'),
      findsOneWidget,
      reason: 'reconnect banner is visible instead of leaving the dashboard',
    );
    expect(find.text('Connect'), findsNothing, reason: 'not kicked to connect screen');
  });

  testWidgets('hard error still routes to the connect screen', (tester) async {
    await tester.pumpWidget(app(const ConnectionState(
      phase: ConnectionPhase.error,
      baseUrl: 'http://10.0.0.5:4096',
      error: 'Unreachable: Connection refused',
    )));
    await tester.pumpAndSettle();

    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Unreachable: Connection refused'), findsOneWidget);
    expect(find.text('Log'), findsNothing);
  });

  testWidgets('recovery from reconnecting returns to the dashboard', (tester) async {
    // Simulate the SSE socket re-establishing: phase flips reconnecting → connected.
    final controller = _FixedConnectionController(const ConnectionState(
      phase: ConnectionPhase.reconnecting,
      baseUrl: 'http://10.0.0.5:4096',
      error: 'socket closed',
    ));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        connectionProvider.overrideWith(() => controller),
        baseUrlProvider.overrideWith(() => BaseUrlNotifier('')),
      ],
      child: const OpenCodeMirrorApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Connection lost — reconnecting… (socket closed)'), findsOneWidget);

    controller.state = const ConnectionState(
      phase: ConnectionPhase.connected,
      baseUrl: 'http://10.0.0.5:4096',
    );
    await tester.pumpAndSettle();

    expect(find.text('Log'), findsOneWidget);
    expect(find.text('Connection lost — reconnecting… (socket closed)'), findsNothing);
  });
}
