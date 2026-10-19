// Records a scripted run of the real widgets as video frames plus the touches
// that drove it, for release clips (skill herdr-changelog, make_clip.sh
// --touches). Frames are 1080 px wide PNGs at 30 fps; the touches are
// seconds from the first frame and coordinates normalised to the frame.
//
// Use it from an env-gated test, inside shoot()'s `wrap` and `pump`:
//
//   final rec = ClipRecorder('/tmp/my_clip');
//   await shoot(tester, home, '/tmp/my_clip/last.png',
//       wrap: (app) => providers(rec.wrap(app)),
//       pump: (t) async { await rec.hold(t, ...); await rec.tap(t, finder, 'label'); ... });
//   rec.finish();
//
// Platform views (the page viewer's WebView) draw nothing in a test: record
// those screens on the phone instead (record_clip.sh).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

class ClipRecorder {
  ClipRecorder(String dir) : out = Directory(dir) {
    final frames = Directory('${out.path}/frames');
    if (frames.existsSync()) frames.deleteSync(recursive: true);
    frames.createSync(recursive: true);
  }

  static const frame = Duration(microseconds: 33333);
  static const width = 1080.0;

  final Directory out;
  final _key = GlobalKey();
  final _steps = <Map<String, Object>>[];
  var _frames = 0;

  double get _now => _frames / 30;

  /// Wraps the app (pass it as, or inside, shoot()'s `wrap`) so routes, sheets
  /// and toasts are all in the frame.
  Widget wrap(Widget app) => RepaintBoundary(key: _key, child: app);

  /// Pumps [d] of fake time one frame at a time, recording each frame.
  Future<void> hold(WidgetTester t, Duration d) async {
    for (var left = d; left > Duration.zero; left -= frame) {
      await t.pump(frame);
      await _capture(t);
    }
  }

  /// Taps the centre of [target], captioned [label].
  Future<void> tap(WidgetTester t, Finder target, String label) async {
    final at = t.getCenter(target);
    _steps.add({'t': _now, ..._norm(t, at), 'kind': 'tap', 'label': label});
    final g = await t.startGesture(at);
    await hold(t, const Duration(milliseconds: 120));
    await g.up();
  }

  /// Holds a finger on the centre of [target] for [hold], captioned [label].
  Future<void> longPress(WidgetTester t, Finder target, String label, {Duration hold = const Duration(milliseconds: 700)}) async {
    final at = t.getCenter(target);
    _steps.add({'t': _now, ..._norm(t, at), 'kind': 'tap', 'label': label});
    final g = await t.startGesture(at);
    await this.hold(t, hold);
    await g.up();
  }

  /// Drags from [from] by [by] over [over], at the pace a person would,
  /// then lifts after [rest]. Captioned [label].
  Future<void> drag(
    WidgetTester t,
    Offset from,
    Offset by,
    String label, {
    Duration over = const Duration(milliseconds: 1400),
    Duration rest = const Duration(milliseconds: 300),
  }) async {
    final moves = over.inMicroseconds ~/ frame.inMicroseconds;
    _steps.add({
      't': _now,
      ..._norm(t, from),
      'kind': 'drag',
      'to': _norm(t, from + by),
      'until': _now + moves / 30,
      'label': label,
    });
    final g = await t.startGesture(from);
    for (var i = 1; i <= moves; i++) {
      await g.moveBy(by / moves.toDouble(), timeStamp: frame * i);
      await t.pump(frame);
      await _capture(t);
    }
    await hold(t, rest);
    await g.up(timeStamp: frame * (moves + rest.inMicroseconds ~/ frame.inMicroseconds));
    _steps.add({'t': _now, ..._norm(t, from + by), 'kind': 'release', 'label': label});
  }

  /// Starts change [index] of [total] of a release walkthrough, captioned
  /// [label]: make_clip.sh shows it as a chapter with a progress mark. Put the
  /// card at the top ([top]) when the change itself appears low on screen (a
  /// toast, a sheet), so the caption never covers what it describes.
  void chapter(int index, int total, String label, {bool top = false}) => _steps.add({
        't': _now,
        'kind': 'chapter',
        'label': label,
        'index': index,
        'total': total,
        if (top) 'place': 'top',
      });

  /// Writes touches.json next to the frames.
  void finish() => File('${out.path}/touches.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({'fps': 30, 'frames': _frames, 'steps': _steps}),
      );

  Map<String, double> _norm(WidgetTester t, Offset o) {
    final size = t.view.physicalSize / t.view.devicePixelRatio;
    // A fling may end past the edge; the ring stops at it.
    return {'x': (o.dx / size.width).clamp(0.0, 1.0), 'y': (o.dy / size.height).clamp(0.0, 1.0)};
  }

  Future<void> _capture(WidgetTester t) async {
    final boundary = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await t.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: width / boundary.size.width);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      _frames++;
      await File('${out.path}/frames/${_frames.toString().padLeft(5, '0')}.png').writeAsBytes(data!.buffer.asUint8List());
    });
  }
}
