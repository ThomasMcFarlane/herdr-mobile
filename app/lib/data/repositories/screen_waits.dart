import 'dart:async';

import '../models/herdr_models.dart';
import 'fleet_agent.dart';

/// Panes whose agent waits on the person while herdr says `done` or `idle`.
///
/// herdr learns "blocked" from the agent. omp tells it for a tool approval and
/// its question tool, but not for the plan review: omp aborts the turn to open
/// it, so herdr sees the turn end and reports `done` with the review on screen
/// (`status: idle` in the captured `plan-review` fixture). Nothing that reads
/// only the status (the board, a notification, the answer dock) would call
/// that pane waiting, and the phone would say the agent finished.
///
/// The screen is the only place the wait is written, so it is read: once when
/// an agent of a kind in [readers] is first seen finished, once more
/// [retryAfter] later (the review opens a moment after the status turns), and
/// when the pane shows activity or an answer was sent. A pane found waiting is
/// read again at most every [recheckEvery] on a refresh, since the review can
/// be dismissed in the terminal without any status change. Panes that are
/// working or blocked, or gone, are never read.
class ScreenWaits {
  ScreenWaits({
    required this.readers,
    required this._read,
    required this._onChange,
    this.retryAfter = const Duration(milliseconds: 1500),
    this.recheckEvery = const Duration(seconds: 15),
    this.settle = const Duration(milliseconds: 800),
    this._clock = DateTime.now,
  });

  /// Per agent label: whether a screen of that agent shows it waiting.
  final Map<String, bool Function(String screen)> readers;
  final Future<String> Function(String paneId) _read;
  final void Function() _onChange;
  final DateTime Function() _clock;
  final Duration retryAfter;
  final Duration recheckEvery;

  /// How long after an answer was sent the pane is read again.
  final Duration settle;

  final _waiting = <String>{};
  final _watches = <String, _Watch>{};
  bool _disposed = false;

  /// The panes found waiting.
  Set<String> get panes => _waiting;

  /// Whether herdr's [status] can hide a wait: only a pane that is not working
  /// and not blocked can be waiting unseen.
  static bool _canHide(AgentStatus status) => status == AgentStatus.done || status == AgentStatus.idle;

  /// Takes the panes of a fresh snapshot: starts reading new candidates and
  /// forgets the ones that moved on.
  void update(List<Pane> panes) {
    if (_disposed) return;
    final live = <String>{};
    for (final p in panes) {
      if (!_canHide(p.status) || !readers.containsKey(FleetAgent.kindOf(p))) continue;
      live.add(p.id);
      final key = '${p.status.name}:${p.completionSeq}';
      final watch = _watches[p.id];
      if (watch == null || watch.key != key) {
        watch?.timer?.cancel();
        final next = _watches[p.id] = _Watch(key, FleetAgent.kindOf(p)!);
        _probe(p.id, next);
      } else if (watch.failed || (_waiting.contains(p.id) && _clock().difference(watch.readAt ?? _clock()) >= recheckEvery)) {
        _probe(p.id, watch);
      }
    }
    var changed = false;
    for (final id in _watches.keys.toList()) {
      if (live.contains(id)) continue;
      _watches.remove(id)?.timer?.cancel();
      changed |= _waiting.remove(id);
    }
    if (changed) _onChange();
  }

  /// The pane showed activity: it is read again, at most once per [settle]. A
  /// review dismissed in the terminal, or one opened again (or late) with no
  /// status change, changes the screen and nothing else.
  void touch(String paneId) {
    final watch = _watches[paneId];
    if (_disposed || watch == null || watch.timer != null || watch.reading) return;
    final since = watch.readAt == null ? settle : _clock().difference(watch.readAt!);
    watch.timer = Timer(since >= settle ? Duration.zero : settle - since, () {
      watch.timer = null;
      _probe(paneId, watch);
    });
  }

  /// An answer was sent to the pane: it is read again once the agent had a
  /// moment to act on it.
  void answered(String paneId) {
    final watch = _watches[paneId];
    if (_disposed || watch == null) return;
    watch.timer?.cancel();
    watch.timer = Timer(settle, () {
      watch.timer = null;
      _probe(paneId, watch);
    });
  }

  Future<void> _probe(String paneId, _Watch watch) async {
    if (watch.reading) return;
    watch.reading = true;
    bool? waits;
    try {
      waits = readers[watch.agent]!(await _read(paneId));
    } on Object {
      // Not read: what was known stays, the next refresh tries again.
    } finally {
      watch.reading = false;
    }
    if (_disposed || !identical(_watches[paneId], watch)) return;
    watch.readAt = _clock();
    watch.failed = waits == null;
    if (waits != null && waits != _waiting.contains(paneId)) {
      waits ? _waiting.add(paneId) : _waiting.remove(paneId);
      _onChange();
    }
    // The review opens a moment after the status turns: one more look.
    if (waits == false && ++watch.misses < 2 && watch.timer == null) {
      watch.timer = Timer(retryAfter, () {
        watch.timer = null;
        _probe(paneId, watch);
      });
    }
  }

  void dispose() {
    _disposed = true;
    for (final w in _watches.values) {
      w.timer?.cancel();
    }
    _watches.clear();
    _waiting.clear();
  }
}

class _Watch {
  _Watch(this.key, this.agent);

  /// The finished state this watch is about: a new one starts over.
  final String key;
  final String agent;
  var reading = false;
  var misses = 0;

  /// The last read threw: the next refresh reads again.
  var failed = false;
  DateTime? readAt;
  Timer? timer;
}
