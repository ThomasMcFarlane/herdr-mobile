import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:mermaid_flutter/mermaid_flutter.dart' show ScenePainter;

import 'package:herdr_mobile/ui/core/kit.dart';
import 'mermaid_layout.dart';
import 'mermaid_theme.dart';

/// Lays a diagram out off the UI isolate, once per source and theme, and keeps
/// what it drew.
///
///  * **Layouts.** A result is kept by `(brightness, source)`: a row that
///    scrolls out and back, or the same diagram in the answer and in the file
///    viewer, costs nothing the second time. 24 results; a failure from an
///    unexpected throw is not kept.
///  * **Two isolates at most.** A screen of six diagrams must not start six
///    isolates (each holds the engine's code and a copy of the scene): the rest
///    wait their turn.
///  * **Pictures.** Recording a scene lays out every label with `TextPainter`
///    on the UI thread. A recorded `ui.Picture` is kept (16, reference-counted)
///    so that a row scrolling back in costs one `drawPicture`.
class MermaidCache {
  MermaidCache([this._layout = layoutMermaidOffThread]);

  /// The one the app uses. A test replaces it.
  static MermaidCache shared = MermaidCache();

  static const _resultsKept = 24;
  static const _picturesKept = 16;
  static const _isolates = 2;

  final Future<MermaidResult> Function(MermaidJob job) _layout;
  final _results = <String, Future<MermaidResult>>{};
  final _waiting = Queue<void Function()>();
  int _running = 0;

  /// The result for [source] under [ds]; the same future for the same key.
  Future<MermaidResult> layout(String source, Ds ds) {
    final key = '${ds.brightness.index}\u0000$source';
    final hit = _results.remove(key);
    if (hit != null) {
      _results[key] = hit;
      return hit;
    }
    final job = MermaidJob(source: source, theme: mermaidThemeOf(ds), darkText: mermaidDarkText, lightText: mermaidLightText);
    final done = Completer<MermaidResult>();
    final future = done.future;
    _results[key] = future;
    while (_results.length > _resultsKept) {
      _results.remove(_results.keys.first);
    }
    _start(() async {
      try {
        done.complete(await _layout(job));
      } catch (e) {
        _results.remove(key);
        done.complete(MermaidFailed("Couldn't draw this diagram · $e"));
      }
    });
    return future;
  }

  void _start(Future<void> Function() job) {
    void run() {
      _running++;
      job().whenComplete(() {
        _running--;
        if (_waiting.isNotEmpty) _waiting.removeFirst()();
      });
    }

    if (_running < _isolates) {
      run();
    } else {
      _waiting.add(run);
    }
  }

  final _pictures = LinkedHashMap<MermaidDrawn, _Recorded>.identity();

  /// The recorded picture of [drawn]. Hand it back with [MermaidPictureLease.release].
  MermaidPictureLease acquirePicture(MermaidDrawn drawn) {
    var entry = _pictures.remove(drawn);
    entry ??= _Recorded(_record(drawn));
    _pictures[drawn] = entry;
    entry.leases++;
    _trim();
    return MermaidPictureLease._(this, drawn, entry);
  }

  void _trim() {
    for (final key in _pictures.keys.toList()) {
      if (_pictures.length <= _picturesKept) return;
      final e = _pictures[key]!;
      if (e.leases > 0) continue;
      _pictures.remove(key);
      e.picture.dispose();
    }
  }

  void _release(MermaidDrawn drawn, _Recorded entry) {
    entry.leases--;
    if (entry.leases == 0 && !identical(_pictures[drawn], entry)) entry.picture.dispose();
    _trim();
  }

  /// Pictures held now (the phone bench logs it).
  // (public: the phone bench reads it)
  int get picturesHeld => _pictures.length;

  /// A scene recorded at its own size, in dp.
  static ui.Picture _record(MermaidDrawn drawn) {
    final recorder = ui.PictureRecorder();
    final size = ui.Size(drawn.scene.size.width, drawn.scene.size.height);
    ScenePainter(drawn.scene).paint(ui.Canvas(recorder), size);
    return recorder.endRecording();
  }

  /// A scene recorded at its own size, for a caller that draws it elsewhere
  /// (the viewer's picture): the caller disposes it.
  static ui.Picture recordUncached(MermaidDrawn drawn) => _record(drawn);
}

final class _Recorded {
  _Recorded(this.picture);

  final ui.Picture picture;
  int leases = 0;
}

/// A hold on a recorded picture: it is not disposed while held.
final class MermaidPictureLease {
  MermaidPictureLease._(this._cache, this._drawn, this._entry);

  final MermaidCache _cache;
  final MermaidDrawn _drawn;
  final _Recorded _entry;
  bool _released = false;

  ui.Picture get picture => _entry.picture;

  void release() {
    if (_released) return;
    _released = true;
    _cache._release(_drawn, _entry);
  }
}
