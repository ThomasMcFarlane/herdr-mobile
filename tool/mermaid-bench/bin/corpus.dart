/// Coverage and speed of Mermaid layout over a corpus of real diagrams.
///
///   dart build cli -t bin/corpus.dart -o /tmp/mermaid_bench_build && /tmp/mermaid_bench_build/bundle/bin/corpus
///
/// Reads `*.mmd` from $MERMAID_CORPUS (default /tmp/mermaid_corpus; make one
/// with extract_corpus.py), lays out every block of the five kinds the app
/// draws exactly as the app does (`layoutMermaid`: normalise, phone profile,
/// both directions of a wide left-to-right flowchart, readability pass) and
/// prints, per kind: how many drew, and the time of one layout.
///
/// Exit code 1 when a kind's ok-rate is under its floor (`--floor kind=0.97`),
/// or its p95 is over `--p95` ms (default 5) or its worst over `--max` ms
/// (default 150). Blocks that are templates (`{{`) or elided (a line that is
/// only `…` or `...`) are not diagrams and count nowhere. Failures go to
/// fails.tsv in the working directory.
library;

import 'dart:io';

import 'package:herdr_mobile/ui/render/mermaid/mermaid_layout.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_source.dart';
import 'package:mermaid_core/mermaid_core.dart' as core;

const _floors = <String, double>{'flowchart': 0.975, 'sequence': 0.985, 'state': 1.0, 'er': 0.95, 'classDiagram': 0.94};

final _elided = RegExp(r'^\s*(…|\.{3,})\s*$', multiLine: true);

double _pct(List<double> sorted, double p) => sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round()];

void main(List<String> args) {
  final floors = {..._floors};
  var p95Limit = 5.0;
  var maxLimit = 150.0;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--floor':
        final kv = args[++i].split('=');
        floors[kv[0]] = double.parse(kv[1]);
      case '--p95':
        p95Limit = double.parse(args[++i]);
      case '--max':
        maxLimit = double.parse(args[++i]);
    }
  }

  final dir = Directory(Platform.environment['MERMAID_CORPUS'] ?? '/tmp/mermaid_corpus');
  if (!dir.existsSync()) {
    stderr.writeln('no corpus at ${dir.path}: python3 tool/mermaid-bench/extract_corpus.py ${dir.path} <roots>');
    exit(2);
  }
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.mmd')).toList()..sort((a, b) => a.path.compareTo(b.path));

  final theme = core.MermaidTheme.defaultTheme.copyWith(fontFamily: 'Inter', fontSize: 13);
  const dark = core.Color(0xFF37352F);
  const light = core.Color(0xFFECEDEF);
  MermaidJob job(String s) => MermaidJob(source: s, theme: theme, darkText: dark, lightText: light);

  final times = <String, List<double>>{};
  final widths = <String, List<double>>{};
  final total = <String, int>{};
  final turned = <String, int>{};
  final fails = <String>[];
  var skipped = 0;
  var other = 0;
  var tooLarge = 0;

  final sources = <(String, String)>[];
  for (final f in files) {
    final s = f.readAsStringSync();
    if (s.contains('{{') || _elided.hasMatch(s)) {
      skipped++;
      continue;
    }
    sources.add((f.uri.pathSegments.last, s));
  }
  // Warm the code paths first; the timed pass below is the second.
  for (final (_, s) in sources.take(200)) {
    layoutMermaid(job(s));
  }

  for (final (name, s) in sources) {
    final type = core.detectDiagramType(normalizeMermaid(s));
    final kind = switch (type) {
      core.DiagramType.flowchart => 'flowchart',
      core.DiagramType.sequence => 'sequence',
      core.DiagramType.stateDiagram => 'state',
      core.DiagramType.er => 'er',
      core.DiagramType.classDiagram => 'classDiagram',
      _ => null,
    };
    if (kind == null) {
      other++;
      continue;
    }
    if (s.length > mermaidMaxSource) tooLarge++;
    total[kind] = (total[kind] ?? 0) + 1;
    final sw = Stopwatch()..start();
    final r = layoutMermaid(job(s));
    sw.stop();
    switch (r) {
      case MermaidDrawn():
        (times[kind] ??= []).add(sw.elapsedMicroseconds / 1000);
        (widths[kind] ??= []).add(r.scene.size.width);
        if (r.turned) turned[kind] = (turned[kind] ?? 0) + 1;
      case MermaidFailed():
        fails.add('$kind\t$name\t${r.reason}');
    }
  }
  File('fails.tsv').writeAsStringSync(fails.join('\n'));

  stdout.writeln('${files.length} blocks: ${skipped} templates or elided, $other of kinds the app does not draw, $tooLarge over ${mermaidMaxSource} chars.');
  stdout.writeln();
  stdout.writeln('| kind | n | drew | ok | median ms | p95 ms | max ms | width p50 | width p90 | wider than 410 | turned |');
  stdout.writeln('| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |');
  var failed = false;
  for (final kind in floors.keys) {
    final n = total[kind] ?? 0;
    if (n == 0) continue;
    final t = (times[kind] ?? [])..sort();
    final w = (widths[kind] ?? [])..sort();
    final rate = t.length / n;
    final wide = w.where((x) => x > 410).length / (w.isEmpty ? 1 : w.length);
    final p95 = _pct(t, 0.95);
    final worst = t.isEmpty ? 0.0 : t.last;
    final bad = <String>[
      if (rate < floors[kind]!) 'ok-rate under ${floors[kind]}',
      if (p95 > p95Limit) 'p95 over $p95Limit ms',
      if (worst > maxLimit) 'max over $maxLimit ms',
    ];
    if (bad.isNotEmpty) failed = true;
    stdout.writeln(
      '| $kind | $n | ${t.length} | ${(rate * 100).toStringAsFixed(1)}% | ${_pct(t, 0.5).toStringAsFixed(2)} | ${p95.toStringAsFixed(2)} | ${worst.toStringAsFixed(1)} | ${_pct(w, 0.5).round()} | ${_pct(w, 0.9).round()} | ${(wide * 100).round()}% | ${turned[kind] ?? 0} |${bad.isEmpty ? '' : ' FAIL: ${bad.join(', ')}'}',
    );
  }
  stdout.writeln();
  final reasons = <String, int>{};
  for (final f in fails) {
    final reason = f.split('\t').last.replaceAll(RegExp(r'line \d+'), 'line N').replaceAll(RegExp(r'"[^"]*"'), '"…"');
    reasons[reason] = (reasons[reason] ?? 0) + 1;
  }
  final top = reasons.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('Failures (${fails.length}, details in fails.tsv):');
  for (final e in top.take(12)) {
    stdout.writeln('  ${e.value.toString().padLeft(4)}  ${e.key}');
  }
  if (failed) exit(1);
}
