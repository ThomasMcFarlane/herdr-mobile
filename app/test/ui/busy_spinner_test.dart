import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

Future<void> _pump(WidgetTester tester, {bool reduced = false}) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: const Scaffold(body: Center(child: BusySpinner())),
    ),
  ),
);

void main() {
  testWidgets('draws nothing before the delay, then spins', (tester) async {
    await _pump(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.getSize(find.byType(BusySpinner)), const Size.square(14));

    await tester.pump(Dwell.spinnerDelay);
    final ring = tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
    expect(ring.value, isNull);
    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('fast work never shows it', (tester) async {
    await _pump(tester);
    await tester.pump(Dwell.spinnerDelay ~/ 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Dwell.spinnerDelay);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('reduced motion: a still three-quarter ring, nothing scheduled', (tester) async {
    await _pump(tester, reduced: true);
    await tester.pump(Dwell.spinnerDelay);
    final ring = tester.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
    expect(ring.value, BusySpinner.stillValue);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
