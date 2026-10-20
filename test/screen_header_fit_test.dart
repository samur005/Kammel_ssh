import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_agent/widgets/swiss.dart';

void main() {
  testWidgets('long Russian header title fits a narrow phone without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScreenHeader('Рабочая область',
            eyebrow: 'ABSssh',
            eyebrowKeepCase: true,
            trailing: SizedBox(width: 120, height: 40)),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('РАБОЧАЯ ОБЛАСТЬ'), findsOneWidget);
    expect(find.text('ABSssh'), findsOneWidget);
    // Fully visible: the text is scaled into its slot, not ellipsized.
    final box = tester.getRect(find.byType(FittedBox));
    expect(box.right, lessThanOrEqualTo(360 - 16 - 12 - 120 + 0.5));
  });
}
