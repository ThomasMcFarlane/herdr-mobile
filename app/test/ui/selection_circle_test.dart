import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/attach/selection_circle.dart';

Widget _circle(int? number, {bool reduced = false}) => MaterialApp(
  theme: AppTheme.light(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(
      body: Center(child: SelectionCircle(number: number, onTap: () {}, label: 'Select photo 1')),
    ),
  ),
);

/// The smallest scale any Transform under the circle draws at right now.
double _smallestScale(WidgetTester tester) {
  var smallest = 1.0;
  for (final t in tester.widgetList<Transform>(find.descendant(of: find.byType(SelectionCircle), matching: find.byType(Transform)))) {
    final s = t.transform.entry(0, 0);
    if (s < smallest) smallest = s;
  }
  return smallest;
}

void main() {
  testWidgets('a new pick number pops in from smaller to full size', (tester) async {
    await tester.pumpWidget(_circle(null));
    await tester.pumpWidget(_circle(1));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_smallestScale(tester), lessThan(0.99));
    await tester.pumpAndSettle();
    expect(_smallestScale(tester), 1.0);
  });

  testWidgets('a circle scrolled in already picked does not pop', (tester) async {
    await tester.pumpWidget(_circle(2));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_smallestScale(tester), 1.0);
  });

  testWidgets('reduced motion: the number changes without a pop', (tester) async {
    await tester.pumpWidget(_circle(null, reduced: true));
    await tester.pumpWidget(_circle(1, reduced: true));
    await tester.pump(const Duration(milliseconds: 16));
    expect(_smallestScale(tester), 1.0);
  });
}
