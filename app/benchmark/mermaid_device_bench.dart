// ignore_for_file: avoid_print
//
// The Mermaid benchmark, on a phone: what diagrams cost while a chat scrolls
// over them. `autoresearch-mermaid.sh` builds and runs it:
//
//   flutter build apk --profile -t benchmark/mermaid_device_bench.dart
//
// The real Markdown renderer (`MdBlockView`) over `mermaid_fixtures.dart`: 12
// diagrams (one of each kind the app draws, a left-to-right chain that turns, a
// wide sequence diagram, tall and large flowcharts, author fills, one that stays
// code) between paragraphs of prose, 3 times over. Three things are measured:
//
//   1. Per fixture, cold, on the real engine and a real isolate:
//      `layout_wall_ms` (asking `MermaidCache` until the result is back: isolate
//      spawn, layout, copy) and `record_ms` (recording the picture, on the UI
//      thread). Medians over the fixtures it draws, and the worst.
//   2. Frames while the list is scrolled with real touch (`adb shell input
//      swipe`, from the script) with a cold cache: build and raster time of
//      every frame (`FrameTiming`), late frames (over 16.7 ms).
//   3. The same again with the cache warm (every layout and picture is there):
//      what a row that scrolls back in costs.
//
// Lines go to logcat: MERMAIDBENCH_ENV, _READY (the script starts swiping),
// _METRIC <name>=<value>, _DONE or _ERROR.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode, kProfileMode;
import 'package:flutter/material.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/photos/mermaid_viewer.dart' show openDiagramViewer;
import 'package:herdr_mobile/ui/render/markdown/markdown.dart';
import 'package:herdr_mobile/ui/render/mermaid/md_diagram_opener.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_cache.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_layout.dart';

import 'support/mermaid_fixtures.dart';

/// How long each scrolled phase lasts; the script swipes all the while.
const _phase = Duration(seconds: 25);

void main() {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  _Bench(binding).run();
}

double _pct(List<double> sorted, double p) => sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round()];

class _Bench {
  _Bench(this.binding);

  final WidgetsBinding binding;
  final _timings = <ui.FrameTiming>[];

  void _metric(String name, num value) =>
      print('MERMAIDBENCH_METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

  Future<void> run() async {
    final watchdog = Timer(
      const Duration(minutes: 10),
      () => print('MERMAIDBENCH_ERROR watchdog: the run did not finish'),
    );
    try {
      await _run();
      print('MERMAIDBENCH_DONE');
    } catch (e, s) {
      print('MERMAIDBENCH_ERROR $e');
      print('MERMAIDBENCH_ERROR ${s.toString().split('\n').take(6).join(' | ')}');
    } finally {
      watchdog.cancel();
    }
  }

  Future<void> _run() async {
    binding.addTimingsCallback((t) => _timings.addAll(t));
    print(
      'MERMAIDBENCH_ENV mode=${kProfileMode
          ? 'profile'
          : kDebugMode
          ? 'DEBUG'
          : 'release'}',
    );
    if (kDebugMode) print('MERMAIDBENCH_WARN a debug build: the numbers mean nothing, build with --profile');

    // The list: prose, then each fixture, three times.
    final blocks = <MdBlock>[];
    for (var round = 0; round < 3; round++) {
      for (final f in mermaidFixtures) {
        blocks.addAll(parseMd('$mermaidProse\n\n$f').blocks);
      }
    }

    runApp(_BenchApp(blocks: blocks));
    await binding.endOfFrame;

    await _coldCosts();

    // Scrolled, cold: every diagram is laid out as it comes into view.
    MermaidCache.shared = MermaidCache();
    await _scrolled('cold', blocks);

    // Scrolled, warm: the cache from the pass before.
    await _scrolled('warm', blocks);
  }

  /// Layout wall time and picture recording, per fixture, cold.
  Future<void> _coldCosts() async {
    final cache = MermaidCache();
    final ds = Ds.paper;
    final layout = <double>[];
    final record = <double>[];
    for (final f in mermaidFixtures) {
      final code = parseMd(f).blocks.whereType<MdCode>().single;
      final sw = Stopwatch()..start();
      final result = await cache.layout(code.text, ds);
      sw.stop();
      if (result is! MermaidDrawn) continue;
      layout.add(sw.elapsedMicroseconds / 1000);
      final rec = Stopwatch()..start();
      final lease = cache.acquirePicture(result);
      rec.stop();
      record.add(rec.elapsedMicroseconds / 1000);
      lease.release();
    }
    layout.sort();
    record.sort();
    _metric('layout_wall_p50_ms', _pct(layout, 0.5));
    _metric('layout_wall_p95_ms', _pct(layout, 0.95));
    _metric('layout_wall_max_ms', layout.isEmpty ? 0 : layout.last);
    _metric('record_p50_ms', _pct(record, 0.5));
    _metric('record_p95_ms', _pct(record, 0.95));
    _metric('record_max_ms', record.isEmpty ? 0 : record.last);
    _metric('diagrams_drawn', layout.length);
  }

  Future<void> _scrolled(String name, List<MdBlock> blocks) async {
    // Fresh list so the scroll starts at the top and every row is built anew.
    runApp(const SizedBox.shrink());
    await binding.endOfFrame;
    runApp(_BenchApp(blocks: blocks));
    await binding.endOfFrame;
    // FrameTiming reaches the framework in batches, up to a second late.
    await Future<void>.delayed(const Duration(seconds: 1));
    _timings.clear();
    print('MERMAIDBENCH_READY $name');
    await Future<void>.delayed(_phase);
    await Future<void>.delayed(const Duration(seconds: 2));

    if (_timings.isEmpty) throw StateError('no FrameTiming arrived in phase $name');
    final build = [for (final t in _timings) t.buildDuration.inMicroseconds / 1000]..sort();
    final raster = [for (final t in _timings) t.rasterDuration.inMicroseconds / 1000]..sort();
    final late = _timings.where((t) => t.totalSpan.inMicroseconds / 1000 > 16.7).length;
    _metric('${name}_frames', _timings.length);
    _metric('${name}_build_p50_ms', _pct(build, 0.5));
    _metric('${name}_build_p95_ms', _pct(build, 0.95));
    _metric('${name}_build_max_ms', build.last);
    _metric('${name}_raster_p50_ms', _pct(raster, 0.5));
    _metric('${name}_raster_p95_ms', _pct(raster, 0.95));
    _metric('${name}_raster_max_ms', raster.last);
    _metric('${name}_late_frames', late);
    _metric('${name}_pictures_held', MermaidCache.shared.picturesHeld);
  }
}

class _BenchApp extends StatelessWidget {
  const _BenchApp({required this.blocks});

  final List<MdBlock> blocks;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    home: Builder(
      builder: (context) => Material(
        color: context.ds.bg,
        child: MdDiagramOpener(
          open: openDiagramViewer,
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(Gap.lg, MediaQuery.paddingOf(context).top + Gap.md, Gap.lg, Gap.xl),
            itemCount: blocks.length,
            itemBuilder: (context, i) => Padding(
              padding: EdgeInsets.only(top: mdBlockGap(i == 0 ? null : blocks[i - 1], blocks[i])),
              child: MdBlockView(block: blocks[i]),
            ),
          ),
        ),
      ),
    ),
  );
}
