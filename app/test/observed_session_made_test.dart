import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/session_made.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink, MadeReach;
import 'package:herdr_mobile/data/repositories/observed_session.dart';
import 'package:herdr_mobile/data/services/disk_cache.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart' show HerdrTransportException;

import 'support/fake_log_source.dart';
import 'support/fake_transport.dart' show eventually;

/// ~10 KB turns: 80 of them are ~810 KB, the first read (192 KB) holds the last ~19.
List<String> _filler(int turns, {int from = 0}) => [
  for (var i = from; i < from + turns; i++) ...[
    userLine('u$i', 'question $i'),
    assistantLine('a$i', 'answer $i ${'x' * 10000}'),
  ],
];

/// A long log: what was made at the start (a server the agent linked, a file a
/// command wrote), then filler, then the link the agent gave last.
List<String> _long() => [
  sessionLine(),
  userLine('first', 'build it'),
  assistantLine('early', 'The first dashboard is at http://localhost:8790/ and I wrote reports/old.html.'),
  ..._filler(80),
  assistantLine('last', 'Now http://localhost:8765/failures is up.'),
];

List<String> _keys(ObservedAgentSession s) => [
  for (final a in madeAssetsOf(s.state.items, cwd: s.cwd, history: s.madeHistory)) a.key,
];

late Directory _dir;
late DiskCache _saved;

Future<(ObservedRig, ObservedAgentSession)> _open(List<String> lines, {FakeLogSource? source}) async {
  final rig = await ObservedRig.create();
  addTearDown(rig.dispose);
  final src = source ?? rig.source;
  if (source == null) src.write(lines);
  final session = ObservedAgentSession(
    machine: rig.machine,
    paneId: 'w1:p1',
    kind: ompKind,
    source: src,
    mapper: OmpLogMapper.new,
    previews: rig.previews,
  );
  addTearDown(session.dispose);
  session.acquire();
  await eventually(() => session.link == AgentLink.live && session.state.items.isNotEmpty, reason: 'log followed');
  return (rig, session);
}

void main() {
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('made_history');
    _saved = DiskCache.shared;
    DiskCache.shared = DiskCache(() async => _dir);
  });
  tearDown(() {
    DiskCache.shared = _saved;
    _dir.deleteSync(recursive: true);
  });

  test('a log that fits the first read is whole: nothing to read, and asking reads nothing', () async {
    final (rig, session) = await _open([sessionLine(), userLine('u', 'go'), assistantLine('a', 'http://localhost:3000/')]);
    expect(session.madeReach, MadeReach.whole);
    session.readEarlierMade();
    await pumpEventQueue();
    expect(rig.source.calls.where((c) => c.until != null), isEmpty);
    expect(_keys(session), ['localhost:3000']);
  });

  test('a long log shows what its end made, says it is not all, and reads the rest as a digest up to where the end starts', () async {
    final (rig, session) = await _open(_long());
    expect(session.madeReach, MadeReach.partial);
    expect(_keys(session), ['localhost:8765/failures']);

    session.readEarlierMade();
    expect(session.madeReach, MadeReach.reading);
    await eventually(() => session.madeReach != MadeReach.reading, reason: 'earlier part read');
    expect(session.madeReach, MadeReach.whole);
    expect(_keys(session), ['localhost:8765/failures', '/work/w1/reports/old.html', 'localhost:8790']);

    final call = rig.source.calls.singleWhere((c) => c.until != null);
    expect(call.digest, isTrue, reason: 'the chat is not wanted, only what was made');
    expect(call.from, 0);
    expect(session.madeHistory!.upTo, call.until, reason: 'read through exactly where the shown part starts');
  });

  test('asking again while it reads, or once it is read, reads nothing more', () async {
    final (rig, session) = await _open(_long());
    session.readEarlierMade();
    session.readEarlierMade();
    await eventually(() => session.madeReach == MadeReach.whole, reason: 'read');
    session.readEarlierMade();
    await pumpEventQueue();
    expect(rig.source.calls.where((c) => c.until != null), hasLength(1));
  });

  test('a later visit has it from the disk at once, with no read of the host', () async {
    final first = await _open(_long());
    first.$2.readEarlierMade();
    await eventually(() => first.$2.madeReach == MadeReach.whole, reason: 'read');
    await pumpEventQueue(times: 50);
    first.$2.dispose();

    final again = await _open(const [], source: first.$1.source);
    await eventually(() => again.$2.madeReach == MadeReach.whole, reason: 'kept copy found');
    expect(_keys(again.$2), ['localhost:8765/failures', '/work/w1/reports/old.html', 'localhost:8790']);
    expect(first.$1.source.calls.where((c) => c.until != null), hasLength(1), reason: 'only the first visit read the host');
  });

  test('a log that grew since reads only the new stretch and keeps what was found', () async {
    final first = await _open(_long());
    first.$2.readEarlierMade();
    await eventually(() => first.$2.madeReach == MadeReach.whole, reason: 'read');
    final kept = first.$2.madeHistory!.upTo;
    await pumpEventQueue(times: 50);
    first.$2.dispose();

    first.$1.source.write([assistantLine('mid', 'Also http://localhost:9000/'), ..._filler(40, from: 100)]);
    final again = await _open(const [], source: first.$1.source);
    await eventually(() => again.$2.madeReach != MadeReach.whole || again.$2.madeHistory != null, reason: 'kept copy found');
    expect(again.$2.madeReach, MadeReach.partial, reason: 'the shown part now starts after what was read');
    again.$2.readEarlierMade();
    await eventually(() => again.$2.madeReach == MadeReach.whole, reason: 'new stretch read');
    final call = first.$1.source.calls.where((c) => c.until != null).last;
    expect(call.from, kept, reason: 'went on from where the last read stopped');
    expect(_keys(again.$2), containsAll(['localhost:9000', 'localhost:8790', '/work/w1/reports/old.html']));
  });

  test('a read the link breaks says so, keeps the rows, and can be tried again', () async {
    final (rig, session) = await _open(_long());
    rig.source.openError = const HerdrTransportException('The link dropped.');
    session.readEarlierMade();
    await eventually(() => session.madeReach == MadeReach.failed, reason: 'failed');
    expect(_keys(session), ['localhost:8765/failures']);

    session.readEarlierMade();
    await eventually(() => session.madeReach == MadeReach.whole, reason: 'read the second time');
    expect(_keys(session), contains('localhost:8790'));
  });
}
