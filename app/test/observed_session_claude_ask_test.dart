// Claude Code 2.1.312 writes a question to its log only after it is answered,
// so while a question is open the screen is all there is: the chat shows the
// dialog's question as the usual card, answers it by keys, and takes the log's
// own lines, when they come, as the confirmation (no second card).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/observed/claude_ask_driver.dart' show claudeAskFromScreen;
import 'package:herdr_mobile/data/observed/claude_kind.dart';
import 'package:herdr_mobile/data/observed/claude_log_mapper.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink;
import 'package:herdr_mobile/data/repositories/observed_session.dart';

import 'support/fake_claude_ask.dart';
import 'support/fake_fs.dart';
import 'support/fake_log_source.dart';
import 'support/fake_transport.dart' as transport show eventually;

Future<void> eventually(bool Function() test, {String reason = 'condition'}) =>
    transport.eventually(test, reason: reason, timeout: const Duration(seconds: 60));

const _claudeLog = '/home/u/.claude/projects/-work-w1/aaaaaaaa-0000-4000-8000-000000000001.jsonl';

String _screen(String name) {
  final lines = File('test/fixtures/prompts/claude/$name.txt').readAsLinesSync();
  return lines.skipWhile((l) => l.startsWith('# ')).join('\n');
}

const _question = 'Capture 1 of 2 (single question). Answer anything after ~10 seconds. Which colour?';

/// What Claude Code 2.1.312 appends once the question is answered: the call and
/// its result, together.
List<String> _answeredLines(String answer, {String question = _question}) => [
  jsonEncode({
    'type': 'assistant',
    'uuid': 'a-ask',
    'timestamp': '2026-11-01T12:00:00.000Z',
    'message': {
      'role': 'assistant',
      'content': [
        {
          'type': 'tool_use',
          'id': 'toolu_ask',
          'name': 'AskUserQuestion',
          'input': {
            'questions': [
              {
                'question': question,
                'header': 'Colour',
                'multiSelect': false,
                'options': [
                  {'label': 'Red', 'description': 'A warm colour, first option'},
                  {'label': 'Green', 'description': 'A cool colour, second option'},
                  {'label': 'Blue', 'description': 'Another cool colour, third option'},
                ],
              },
            ],
          },
        },
      ],
    },
  }),
  jsonEncode({
    'type': 'user',
    'uuid': 'u-ask',
    'timestamp': '2026-11-01T12:00:05.000Z',
    'message': {
      'role': 'user',
      'content': [
        {
          'type': 'tool_result',
          'tool_use_id': 'toolu_ask',
          'content': 'Your questions have been answered: "$question"="$answer". You can now continue.',
        },
      ],
    },
  }),
];

Future<(ObservedRig, ObservedAgentSession)> _open({
  required String screen,
  List<String> lines = const [],
  String status = 'blocked',
  Duration blockedGrace = const Duration(seconds: 3),
  Duration confirmWithin = const Duration(seconds: 20),
}) async {
  final rig = await ObservedRig.create(status: status, agent: 'claude', log: _claudeLog);
  addTearDown(rig.dispose);
  rig.transport.fs = FakeFs()..addFile(_claudeLog, '{}\n');
  rig.transport.screen = screen;
  rig.source.write(lines);
  final session = ObservedAgentSession(
    machine: rig.machine,
    paneId: 'w1:p1',
    kind: claudeKind,
    source: rig.source,
    mapper: ClaudeLogMapper.new,
    previews: rig.previews,
    readyAfter: Duration(milliseconds: lines.isEmpty ? 10 : 2500),
    answerGrace: const Duration(seconds: 30),
    blockedGrace: blockedGrace,
    confirmWithin: confirmWithin,
  );
  addTearDown(session.dispose);
  session.acquire();
  await eventually(() => session.link == AgentLink.live, reason: 'log followed');
  return (rig, session);
}

void main() {
  test('a blocked pane whose log has no question shows the dialog as a question, not the terminal banner', () async {
    final (_, session) = await _open(screen: _screen('ask2312-single'), blockedGrace: const Duration(milliseconds: 50));
    await eventually(() => session.state.pending.isNotEmpty, reason: 'the question from the screen');

    final p = session.state.pending.single;
    expect(p, isA<PendingQuestion>());
    expect(p.id, contains('screen:'));
    expect(session.needsTerminal, isFalse);
    expect(session.sendBlocked, isNot(contains('Needs you in the terminal')));
    expect((p as PendingQuestion).request.message, contains('Which colour?'), reason: 'the dialog\'s own words');
  });

  test('a form shows the tab on screen as a card of its own, not the terminal banner', () async {
    final (_, session) = await _open(
      screen: _screen('ask2312-form-tab1'),
      blockedGrace: const Duration(milliseconds: 50),
    );
    await eventually(() => session.state.pending.isNotEmpty, reason: 'the tab\'s question');
    final p = session.state.pending.single as PendingQuestion;
    expect(p.request.message, contains('question one'));
    expect(session.needsTerminal, isFalse);
  });

  test('when the log has the question open (older Claude Code) the log\'s question is the card', () async {
    final open = _answeredLines('x').sublist(0, 1);
    final (_, session) = await _open(screen: _screen('ask2312-single'), lines: open);
    await eventually(() => session.state.pending.isNotEmpty, reason: 'the question');
    expect(session.state.pending.single.id, contains('toolu_ask'));
    expect(session.state.pending.single.id, isNot(contains('screen:')));
  });

  test('answering sends the keys; the log\'s call and result then confirm it, with no second card', () async {
    final (rig, session) = await _open(screen: _screen('ask2312-single'), blockedGrace: const Duration(seconds: 30));
    await eventually(() => session.state.pending.isNotEmpty, reason: 'the question from the screen');
    final card = session.state.pending.single as PendingQuestion;

    // From here the pane is a model of the dialog, taking the keys sent.
    final fake = FakeClaudeAsk([
      const AskQuestion(
        id: 'Colour',
        question: _question,
        options: [
          AskOption(label: 'Red', description: 'A warm colour, first option'),
          AskOption(label: 'Green', description: 'A cool colour, second option'),
          AskOption(label: 'Blue', description: 'Another cool colour, third option'),
        ],
      ),
    ]);
    rig.transport.liveScreen = fake.screen;
    var logged = false;
    rig.transport.onInput = (params) {
      final text = params['text'];
      if (text is String) fake.paste(text);
      for (final k in (params['keys'] as List?) ?? const []) {
        fake.press('$k');
      }
      if (fake.submitted && !logged) {
        logged = true;
        rig.source.push(_answeredLines('Green'));
      }
    };

    session.answerQuestion(card.id, const ElicitationAccept({'q0': '1'}));
    await eventually(() => fake.submitted, reason: 'the dialog took the answer');
    await eventually(
      () => session.state.toolCalls.any((c) => c.name == 'AskUserQuestion' && c.status.isFinished),
      reason: 'the log\'s call and result',
    );
    await eventually(() => session.state.pending.isEmpty, reason: 'the card is gone');

    expect(fake.answerOf(0), 'Green');
    expect(session.error, isNull);
    await rig.setStatus('working');
    expect(session.state.pending, isEmpty, reason: 'no second card from the log\'s own lines');
    expect(session.needsTerminal, isFalse);
  });

  test('a form is answered tab by tab, then submitted; the log\'s lines add no card', () async {
    final (rig, session) = await _open(screen: '', blockedGrace: const Duration(seconds: 30));
    const colour = AskQuestion(
      id: 'Colour',
      question: _question,
      options: [
        AskOption(label: 'Red'),
        AskOption(label: 'Green'),
      ],
    );
    const fruit = AskQuestion(
      id: 'Fruit',
      question: 'Which fruits?',
      multi: true,
      options: [
        AskOption(label: 'Apple'),
        AskOption(label: 'Mango'),
      ],
    );
    final fake = FakeClaudeAsk(const [colour, fruit]);
    rig.transport.liveScreen = fake.screen;
    var logged = false;
    rig.transport.onInput = (params) {
      final text = params['text'];
      if (text is String) fake.paste(text);
      for (final k in (params['keys'] as List?) ?? const []) {
        fake.press('$k');
      }
      if (fake.submitted && !logged) {
        logged = true;
        rig.source.push(_answeredLines('Green'));
      }
    };
    await rig.setStatus('working');
    await rig.setStatus('blocked');

    // Tab 1.
    await eventually(() => session.state.pending.isNotEmpty, reason: 'tab 1');
    var card = session.state.pending.single as PendingQuestion;
    expect(card.request.message, contains('Which colour?'));
    session.answerQuestion(card.id, const ElicitationAccept({'q0': '1'}));
    await eventually(() => fake.tab == 1, reason: 'the dialog went on to tab 2');

    // Tab 2 is a new card.
    await eventually(
      () => session.state.pending.isNotEmpty && session.state.pending.single.id != card.id,
      reason: 'tab 2',
    );
    final first = card;
    card = session.state.pending.single as PendingQuestion;
    expect(card.id, isNot(first.id));
    expect(card.request.message, contains('Which fruits?'));
    session.answerQuestion(
      card.id,
      const ElicitationAccept({
        'q0': ['0'],
      }),
    );
    await eventually(() => fake.tab == 2, reason: 'the review');

    // The review: Submit answers.
    await eventually(
      () => session.state.pending.isNotEmpty && session.state.pending.single.id != card.id,
      reason: 'the review card',
    );
    card = session.state.pending.single as PendingQuestion;
    expect(card.request.message, contains('Ready to submit your answers?'));
    session.answerQuestion(card.id, const ElicitationAccept({'q0': '0'}));
    await eventually(() => fake.submitted, reason: 'submitted');
    await eventually(() => session.state.pending.isEmpty, reason: 'the card is gone');
    await eventually(
      () => session.state.toolCalls.any((c) => c.name == 'AskUserQuestion' && c.status.isFinished),
      reason: 'the log\'s call and result',
    );
    await rig.setStatus('working');
    expect(session.state.pending, isEmpty, reason: 'no second card');
    expect(session.error, isNull);
  });

  test('a lone multi-select is submitted on its review and confirmed by the log', () async {
    final (rig, session) = await _open(screen: '', blockedGrace: const Duration(seconds: 30));
    const fruits = AskQuestion(
      id: 'Fruits',
      question: 'Which fruits do I like?',
      multi: true,
      options: [
        AskOption(label: 'Apple'),
        AskOption(label: 'Banana'),
        AskOption(label: 'Cherry'),
      ],
    );
    final fake = FakeClaudeAsk(const [fruits]);
    rig.transport.liveScreen = fake.screen;
    var logged = false;
    rig.transport.onInput = (params) {
      for (final k in (params['keys'] as List?) ?? const []) {
        fake.press('$k');
      }
      if (fake.submitted && !logged) {
        logged = true;
        rig.source.push(_answeredLines('Apple, Cherry', question: 'Which fruits do I like?'));
      }
    };
    await rig.setStatus('working');
    await rig.setStatus('blocked');
    await eventually(() => session.state.pending.isNotEmpty, reason: 'the card');
    final card = session.state.pending.single as PendingQuestion;
    session.answerQuestion(
      card.id,
      const ElicitationAccept({
        'q0': ['0', '2'],
      }),
    );
    await eventually(() => fake.submitted, reason: 'the review was submitted');
    await eventually(() => session.state.pending.isEmpty, reason: 'the card is gone');
    expect(session.error, isNull);
  });

  test('a card follows the screen while the pane stays blocked', () async {
    final (rig, session) = await _open(screen: _screen('ask2312-form-tab1'), blockedGrace: const Duration(seconds: 30));
    await eventually(() => session.state.pending.isNotEmpty, reason: 'tab 1');
    final first = session.state.pending.single;
    rig.transport.screen = _screen('askfull-two-q2');
    await eventually(
      () => session.state.pending.isNotEmpty && session.state.pending.single.id != first.id,
      reason: 'the card moved to the other tab',
    );
    expect((session.state.pending.single as PendingQuestion).request.message, contains('Which extras'));
  });

  test('a form tab still on screen after the answer is refused as the same question', () async {
    final (rig, session) = await _open(screen: _screen('ask2312-form-tab1'), blockedGrace: const Duration(seconds: 30));
    await eventually(() => session.state.pending.isNotEmpty, reason: 'tab 1');
    final card = session.state.pending.single as PendingQuestion;
    // The keys land (the driver's next read shows the other tab), but the read
    // after that, with colours, finds the same tab 1: the form did not move.
    final tab1 = _screen('ask2312-form-tab1');
    final tab2 = _screen('askfull-two-q2');
    var sent = false;
    var reads = 0;
    rig.transport.onInput = (_) {
      sent = true;
      reads = 0;
    };
    rig.transport.liveScreen = () => sent && reads++ == 0 ? tab2 : tab1;
    session.answerQuestion(card.id, const ElicitationAccept({'q0': '1'}));
    await eventually(() => session.error != null, reason: 'refused');
    expect(session.error, contains('The terminal didn’t take that answer ('));
  });

  test('older Claude: a card made from the screen is replaced by the log\'s, and no second one comes', () async {
    final (rig, session) = await _open(screen: _screen('ask2312-single'), blockedGrace: const Duration(seconds: 30));
    await eventually(() => session.state.pending.isNotEmpty, reason: 'the screen card');
    expect(session.state.pending.single.id, contains('screen:'));
    rig.source.push(_answeredLines('x').sublist(0, 1));
    await eventually(() => '${session.state.pending.single.id}'.contains('toolu_ask'), reason: 'the log\'s card');

    final fake = FakeClaudeAsk([
      const AskQuestion(
        id: 'Colour',
        question: _question,
        options: [
          AskOption(label: 'Red', description: 'A warm colour, first option'),
          AskOption(label: 'Green', description: 'A cool colour, second option'),
          AskOption(label: 'Blue', description: 'Another cool colour, third option'),
        ],
      ),
    ]);
    rig.transport.liveScreen = fake.screen;
    rig.transport.onInput = (params) {
      for (final k in (params['keys'] as List?) ?? const []) {
        fake.press('$k');
      }
      if (fake.submitted) {
        rig.source.push([_answeredLines('Green')[1]]);
      }
    };
    session.answerQuestion(session.state.pending.single.id, const ElicitationAccept({'q0': '1'}));
    await eventually(() => fake.submitted, reason: 'answered');
    await eventually(() => session.state.pending.isEmpty, reason: 'the card is gone');
    // The pane stays blocked: the card made from the screen earlier must not
    // come back once the log's own has been answered.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(session.state.pending.where((p) => '${p.id}'.contains('screen:')), isEmpty);
  });

  test('a dialog beside a side panel is a card, and answering option 2 sends down and enter', () async {
    final screen = _screen('ask2312-sidepanel');
    final (rig, session) = await _open(screen: screen, blockedGrace: const Duration(seconds: 30));
    await eventually(() => session.state.pending.isNotEmpty, reason: 'the question');
    final card = session.state.pending.single as PendingQuestion;
    expect(card.request.message, contains('Two checks on the Surface Book'));
    final asked = claudeAskFromScreen(screen)!.questions.single;

    rig.transport.onInput = (_) {
      rig.transport.liveScreen = () => 'Working...\n';
      rig.source.push(_answeredLines('Locks; no image', question: asked.question));
    };
    session.answerQuestion(card.id, const ElicitationAccept({'q0': '1'}));
    await eventually(() => rig.sent('pane.send_input').isNotEmpty, reason: 'keys sent');
    expect(rig.sent('pane.send_input').first['keys'], ['down', 'enter']);
    await eventually(() => session.state.pending.isEmpty, reason: 'the card is gone');
    expect(session.error, isNull);
  });

  test('an answer that never reaches the log, with the dialog still there, is refused saying why', () async {
    final (_, session) = await _open(
      screen: _screen('ask2312-single'),
      blockedGrace: const Duration(seconds: 30),
      confirmWithin: const Duration(milliseconds: 200),
    );
    await eventually(() => session.state.pending.isNotEmpty, reason: 'the question from the screen');
    final card = session.state.pending.single as PendingQuestion;
    // The screen never changes, as if no key landed.
    session.answerQuestion(card.id, const ElicitationAccept({'q0': '1'}));
    await eventually(() => session.error != null, reason: 'refused');
    expect(session.error, contains('The terminal didn’t take that answer ('));
  });
}
