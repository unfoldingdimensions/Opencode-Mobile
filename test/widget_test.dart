import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/main.dart';

void main() {
  testWidgets('shows connect screen when disconnected', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenCodeMirrorApp()));
    expect(find.text('OpenCode Mirror'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
