import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/main.dart';

void main() {
  testWidgets('placeholder screen renders', (tester) async {
    await tester.pumpWidget(const OpenCodeMirrorApp());
    expect(find.text('OpenCode Mirror'), findsOneWidget);
  });
}
