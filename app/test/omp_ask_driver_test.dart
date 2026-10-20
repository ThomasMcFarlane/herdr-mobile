import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/omp_ask_driver.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart' show ompMenuPrompt;

import 'support/omp_ask_fixtures.dart';

List<String> _trim(List<String> l) => [for (final s in l) s.trimRight()];

void main() {
  group('the fake dialog draws what the real omp drew', () {
    for (final c in askCaptures) {
      test(c.fixture, () {
        expect(_trim(c.build().dialogLines()), fixtureDialog(c.fixture));
      });
    }
  });

  group('parseAskScreen on captured screens', () {
    AskScreenState parse(String name) => parseAskScreen(fixtureScreen(name));

    test('a single choice: rows, cursor, descriptions, the recommended mark', () {
      final s = parse('ask-single');
      expect(s.kind, AskScreenKind.question);
      expect(s.hasTabs, isFalse);
      expect(s.title, 'Which database should the project use?');
      expect([for (final r in s.rows) r.label], [
        'SQLite (Recommended)',
        'Postgres',
        'DuckDB',
        'Other (type your own)',
      ]);
      expect(s.cursorRow, 0);
      expect(s.rows.every((r) => !r.checked && !r.multi), isTrue);
      expect(s.rows[1].description, 'Full server, best for concurrent writes and large data sets');
      expect(s.rows.last.isOther, isTrue);
      expect(parse('ask-single-down').cursorRow, 1);
      expect(parse('ask-single-other').cursorRow, 3);
    });

    test('checkboxes and which are ticked', () {
      final s = parse('ask-multi-two');
      expect(s.hasTabs, isTrue);
      expect(s.tabs, ['tools', 'Submit']);
      expect(s.multi, isTrue);
      expect([for (final r in s.rows) r.checked], [true, false, true, false, false]);
      expect(s.cursorRow, 2);
      expect(s.rows[2].description, startsWith('Needs a database container'));
    });

    test('the review tab', () {
      final s = parse('ask-multi-review');
      expect(s.kind, AskScreenKind.review);
      expect([for (final l in s.review) '${l.index}:${l.answer}'], ['0:Lint, Integration tests']);
      final f = parse('ask-form-review');
      expect([for (final l in f.review) l.answer], ['DuckDB', 'Docker image, Changelog', '“Hà Nội — dự án”']);
      final u = parse('ask-long-review-unanswered');
      expect(u.unanswered, 2);
      expect(u.tabs, ['pick', 'Release flags a…', 'Submit']);
      expect([for (final l in u.review) l.answer], ['unanswered', 'unanswered']);
    });

    test('zero options leave only the Other row; a custom answer shows under it, ticked', () {
      final plain = parse('ask-form-q3');
      expect(plain.rows, hasLength(1));
      expect(plain.rows.single.isOther, isTrue);
      final set = parse('ask-form-q3-custom');
      expect(set.rows.single.checked, isTrue);
      expect(set.rows.single.description, 'Hà Nội — dự án');
    });

    test('the editor, empty, typed and prefilled', () {
      expect(parse('ask-other-editor').kind, AskScreenKind.editor);
      expect(parse('ask-other-editor').editorText, '');
      expect(parse('ask-other-editor').title, 'Which database should the project use?');
      expect(parse('ask-other-typed').editorText, 'Postgres, nhưng dùng PgBouncer');
      expect(parse('ask-form-editor-prefilled').editorText, 'Hà Nội — dự án');
    });

    test('a wrapped label is one row; the scrollbar is not text; a cut tab label keeps its mark', () {
      final s = parse('ask-long-scroll');
      expect(s.rows.any((r) => r.label.startsWith('Release 04 with a considerably longer label that wraps')), isTrue);
      expect(s.rows.every((r) => !r.label.contains('█') && !r.label.contains('│')), isTrue);
      expect(s.rows[s.cursorRow!].label, 'Release 15 (Recommended)');
      expect(parse('ask-long-scroll-bottom').rows.last.isOther, isTrue);
      expect(parse('ask-long-scroll-bottom').rows.any((r) => r.label.startsWith('Tiếng Việt')), isTrue);
    });

    test('screens that are not an ask dialog are none', () {
      for (final name in ['approval-bash', 'plan-review', 'resume-picker', 'slash-autocomplete']) {
        expect(looksLikeAsk(fixtureScreen(name)), isFalse, reason: name);
      }
      expect(looksLikeAsk(''), isFalse);
      for (final c in askCaptures) {
        expect(looksLikeAsk(fixtureScreen(c.fixture)), isTrue, reason: c.fixture);
      }
    });

    test('ANSI colours do not matter', () {
      expect(fixtureScreen('ask-multi'), contains('\x1B['));
      expect(parse('ask-multi').rows, hasLength(5));
    });
  });

  group('menus', () {
    test('tool approval: the tool, what it runs, the options and the keys', () {
      final a = parseOmpApproval(fixtureScreen('approval-bash'))!;
      expect(a.tool, 'bash');
      expect(a.detail, ['Command: echo hello from omq && date -u +%Y']);
      expect([for (final o in a.options) o.label], ['Approve', 'Deny']);
      expect(a.cursorIndex, 0);
      expect(a.approve, ['enter']);
      expect(a.deny, ['down', 'enter']);
      final d = parseOmpApproval(fixtureScreen('approval-bash-deny'))!;
      expect(d.cursorIndex, 1);
      expect(d.approve, ['up', 'enter']);
      expect(d.deny, ['enter']);
      final w = parseOmpApproval(fixtureScreen('approval-write'))!;
      expect(w.tool, 'write');
      expect(w.detail, ['Path: hello.txt', 'Content:', 'hello omq']);
    });

    test('plan review', () {
      final p = parseOmpPlanReview(fixtureScreen('plan-review'))!;
      expect([for (final o in p.options) o.label], [
        'Approve and execute',
        'Approve and compact context',
        'Approve and keep context (~6.8k / 200k)',
        'Refine plan',
        'Save and quit',
      ]);
      expect(p.cursorIndex, 0);
      expect(p.approve, ['enter']);
      expect(p.keysForLabel('Refine'), ['down', 'down', 'down', 'enter']);
      final r = parseOmpPlanReview(fixtureScreen('plan-review-refine'))!;
      expect(r.cursorIndex, 3);
      expect(r.approve, ['up', 'up', 'up', 'enter']);
    });

    test('plan review with the model slider: its rows are not options', () {
      final p = parseOmpPlanReview(fixtureScreen('plan-review-slider'))!;
      expect([for (final o in p.options) o.label], [
        'Approve and execute',
        'Approve and compact context',
        'Approve and keep context (~23k / 1m)',
        'Refine plan',
        'Save and quit',
      ]);
      expect(p.cursorIndex, 0);
      expect(p.keysForLabel('Refine'), ['down', 'down', 'down', 'enter']);
    });

    test('keep context over 95% is skipped by the cursor: the keys do not count it', () {
      String full(String usage) =>
          fixtureScreen('plan-review').replaceAll('(~6.8k / 200k)', usage);
      // 199k of 200k: disabled for sure, so Refine is two downs, not three
      // (three would land on "Save and quit", which quits omp).
      final over = parseOmpPlanReview(full('(~199k / 200k)'))!;
      expect(over.keysForLabel('Refine'), ['down', 'down', 'enter']);
      expect(over.keysForLabel('Save'), ['down', 'down', 'down', 'enter']);
      expect(over.keysForLabel('Approve and keep'), isNull);
      final under = parseOmpPlanReview(full('(~150k / 200k)'))!;
      expect(under.keysForLabel('Refine'), ['down', 'down', 'down', 'enter']);
      expect(under.keysForLabel('Approve and keep'), ['down', 'down', 'enter']);
      // 1m is 0.95m to 1.05m once rounded, so 950k used cannot be told.
      final edge = parseOmpPlanReview(full('(~950k / 1m)'))!;
      expect(edge.keysForLabel('Refine'), isNull);
      expect(edge.keysForLabel('Approve and compact'), ['down', 'enter']);
      // A narrow pane cuts the label: the usage cannot be read, so it may be over.
      final cut = parseOmpPlanReview(full('(~199k / 2…)').replaceAll('2…)', '2…'))!;
      expect(cut.keysForLabel('Refine'), isNull);
      expect(cut.keysForLabel('Approve and compact'), ['down', 'enter']);
      // Going up crosses the row too.
      final from = parseOmpPlanReview(
        fixtureScreen('plan-review-refine').replaceAll('(~6.8k / 200k)', '(~199k / 200k)'),
      )!;
      expect(from.keysForLabel('Approve and execute'), ['up', 'up', 'enter']);
    });

    test('with the focus off the options no key chooses one', () {
      final onText = fixtureScreen('plan-review').replaceAll('↑/↓ select · ⏎ confirm', '↑/↓ scroll · ⇧ faster');
      final p = parseOmpPlanReview(onText)!;
      expect(p.focusOnOptions, isFalse);
      expect(p.keysFor(0), isNull);
      expect(ompMenuPrompt(onText), isNull);
      expect(ompMenuPrompt(fixtureScreen('plan-review'))!.replies, hasLength(5));
    });

    test('other screens are not menus', () {
      expect(parseOmpApproval(fixtureScreen('ask-single')), isNull);
      expect(parseOmpPlanReview(fixtureScreen('ask-single')), isNull);
      expect(parseOmpApproval(''), isNull);
    });
  });

  group('shape of the types', () {
    test('AskSend prints what it is for', () {
      const s = AskSend(keys: ['down'], why: 'x');
      expect(s.toString(), contains('down'));
    });
  });
}
