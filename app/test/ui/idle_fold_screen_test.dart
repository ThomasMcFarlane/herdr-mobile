// A project's idle rows through the real shell: a long list folds its older
// rows behind one line that says how many and what, and opens them in place.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/ui/features/agents/agent_more_row.dart';
import 'package:herdr_mobile/ui/features/agents/agents_grouping.dart';

import '../support/shot.dart' show loadAppFonts;
import 'ui_harness.dart';

Pane _pane(int i) => (id: 'w1:p${i.toString().padLeft(2, '0')}', ws: 'w1', agent: 'omp', status: 'idle');

void main() {
  setUpAll(loadAppFonts);

  Future<UiHarness> fleet(int idle) => UiHarness.create([
    (
      profile: MachineProfile(id: 'a', label: 'workstation', host: 'a.example', username: 'dev'),
      snapshot: snapshotWith([for (var i = 1; i <= idle; i++) _pane(i)], title: (id) => 'Task ${id.split('p').last}'),
    ),
  ]);

  testWidgets('27 idle agents show the five started last, then one line that names the first two it holds', (
    tester,
  ) async {
    final h = await fleet(27);
    await pumpUi(tester, h, height: 3000);

    expect(find.text('Task 23'), findsOneWidget);
    expect(find.text('Task 27'), findsOneWidget);
    expect(find.text('Task 22'), findsNothing, reason: 'folded away');
    final fold = find.byType(AgentMoreRow);
    expect(fold, findsOneWidget);
    expect(
      tester.getTopLeft(fold).dy,
      greaterThan(tester.getTopLeft(find.text('Task 27')).dy),
      reason: 'after the rows',
    );
    expect(find.text('${27 - idleShown} more idle'), findsOneWidget);
    expect(find.text('Task 01 \u00B7 Task 02'), findsOneWidget, reason: 'what is inside, not a guess');

    await tester.tap(fold);
    await settle(tester);
    expect(find.text('Task 01'), findsOneWidget, reason: 'every row shows');
    expect(
      tester.getTopLeft(find.text('Task 01')).dy,
      lessThan(tester.getTopLeft(find.text('Task 27')).dy),
      reason: 'in its own place',
    );
    expect(find.text('Show less'), findsOneWidget);
    expect(find.textContaining('more idle'), findsNothing);

    await tester.tap(find.text('Show less'));
    await settle(tester);
    expect(find.text('Task 01'), findsNothing);
    expect(find.text('${27 - idleShown} more idle'), findsOneWidget);
    await teardownUi(tester, h);
  });

  testWidgets('a short list has no fold at all', (tester) async {
    final h = await fleet(idleShown + 1);
    await pumpUi(tester, h, height: 3000);

    expect(find.byType(AgentMoreRow), findsNothing);
    expect(find.text('Task 06'), findsOneWidget);
    await teardownUi(tester, h);
  });
}
