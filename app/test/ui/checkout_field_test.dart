// The `Checkout` row of the new-agent-session form: it appears for a folder in
// a git repo, opens a sheet of the repo's checkouts, and a new worktree asks
// for its branch.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/create/new_agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/create/session_prefill.dart';
import 'package:provider/provider.dart';

import '../support/create_harness.dart';
import 'ui_harness.dart' show snapshotWith;

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<CreateHarness> _open(WidgetTester tester, {required bool repo}) async {
  final h = await CreateHarness.create([
    (profile: profileOf('a', 'studio-mac'), snapshot: snapshotWith(const [])),
  ], waitOnline: false);
  h.stubs['a']!.on['worktree.list'] = (_) {
    if (!repo) throw const HerdrApiException('not_a_repo', 'not a git repository');
    return {
      'type': 'worktree_list',
      'worktrees': [
        {'path': '/r/app', 'label': 'app', 'is_linked_worktree': false, 'branch': 'main', 'open_workspace_id': 'w1'},
        {'path': '/r/app-wt', 'label': 'app-wt', 'is_linked_worktree': true, 'branch': 'feat/x'},
      ],
    };
  };
  tester.view
    ..physicalSize = const Size(360, 800) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: h.machines),
        ChangeNotifierProvider.value(value: h.fleet),
        ListenableProvider<AgentSessions>.value(value: h.agents),
        ChangeNotifierProvider.value(value: h.agentSettings),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const NewAgentSessionScreen(
          machineId: 'a',
          prefill: SessionPrefill(machineId: 'a', folder: '/r/app'),
        ),
      ),
    ),
  );
  await _flush(tester);
  return h;
}

Future<void> _teardown(WidgetTester tester, CreateHarness h) async {
  await tester.pumpWidget(const SizedBox());
  h.dispose();
}

Finder _checkout() => find.bySemanticsLabel(RegExp('^Checkout, '));

void main() {
  testWidgets('a folder in a repo gets a Checkout row; a new worktree asks for a branch', (tester) async {
    final semantics = tester.ensureSemantics();
    final h = await _open(tester, repo: true);

    expect(_checkout(), findsOneWidget);
    expect(find.bySemanticsLabel('Checkout, This folder'), findsOneWidget);
    expect(find.text('main'), findsOneWidget, reason: 'the branch of the folder under the row');
    expect(find.widgetWithText(LabeledField, 'Branch'), findsNothing);

    await tester.tap(_checkout());
    await _flush(tester);
    expect(find.text('app-wt'), findsOneWidget);
    expect(find.text('feat/x · not open in herdr'), findsOneWidget);
    expect(find.text('Main checkout'), findsNothing, reason: 'the main checkout is the typed folder: row 1');

    await tester.tap(find.text('New worktree…'));
    await _flush(tester);

    expect(find.bySemanticsLabel('Checkout, New worktree'), findsOneWidget);
    expect(find.widgetWithText(LabeledField, 'Branch'), findsOneWidget);
    semantics.dispose();
    await _teardown(tester, h);
  });

  testWidgets('a new worktree starts with a suggested branch; typed text is kept, a taken branch is replaced', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final h = await _open(tester, repo: true);

    String branch() => tester
        .widget<EditableText>(
          find.descendant(of: find.widgetWithText(LabeledField, 'Branch'), matching: find.byType(EditableText)),
        )
        .controller
        .text;
    Future<void> pick(String row) async {
      await tester.tap(_checkout());
      await _flush(tester);
      await tester.tap(find.text(row));
      await _flush(tester);
    }

    await pick('New worktree…');
    expect(branch(), matches(RegExp(r'^worktree/[a-z]+-[a-z]+-[0-9a-f]{4}$')));

    await tester.enterText(
      find.descendant(of: find.widgetWithText(LabeledField, 'Branch'), matching: find.byType(EditableText)),
      'fix/mine',
    );
    await pick('app-wt');
    await pick('New worktree…');
    expect(branch(), 'fix/mine', reason: 'what the person typed is theirs');

    // `feat/x` is the branch of a checkout that exists: a second worktree on it would fail.
    await tester.enterText(
      find.descendant(of: find.widgetWithText(LabeledField, 'Branch'), matching: find.byType(EditableText)),
      'feat/x',
    );
    await pick('app-wt');
    await pick('New worktree…');
    expect(branch(), startsWith('worktree/'));

    semantics.dispose();
    await _teardown(tester, h);
  });

  testWidgets('a folder that is not in a repo has no Checkout row', (tester) async {
    final h = await _open(tester, repo: false);

    expect(_checkout(), findsNothing);
    expect(find.widgetWithText(LabeledField, 'Folder'), findsOneWidget);
    await _teardown(tester, h);
  });
}
