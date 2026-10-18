// The design lint: every value a screen draws with comes from the kit.
//
//   dart run tool/design_lint.dart            (from the repo root, or ../tool from app/)
//   dart run tool/design_lint.dart --report   counts per rule and folder, exit 0
//
// A finding names the kit token or component to use instead. A line that must
// keep a raw value says why, on the same line or the one above:
//
//   // design-lint: allow(raw-type) markdown inline bold is the author's emphasis
//
// An allow without a reason is itself a finding. Rules and their reasons live
// in docs/DESIGN.md ("Enforcement"); the kit's own token files are exempt from
// the rules they define.
import 'dart:io';

final class Rule {
  const Rule(this.id, this.patterns, this.message, {this.include = const ['lib/ui/'], this.exempt = const []});

  final String id;
  final List<RegExp> patterns;
  final String message;

  /// Path prefixes (relative to app/) the rule applies to.
  final List<String> include;

  /// Path prefixes it skips: the files that define the tokens it enforces.
  final List<String> exempt;

  bool appliesTo(String path) =>
      include.any(path.startsWith) && !exempt.any(path.startsWith);
}

final _rules = <Rule>[
  Rule(
    'raw-color',
    [RegExp(r'\bColor\(0x'), RegExp(r'\bColors\.(?!transparent\b)')],
    'use a Ds role (context.ds.*) or add one to tokens.dart',
    exempt: ['lib/ui/core/tokens.dart', 'lib/ui/core/theme.dart', 'lib/ui/render/terminal/'],
  ),
  Rule(
    'raw-type',
    [RegExp(r'\bfontSize:'), RegExp(r'\bfontWeight:'), RegExp(r'\bTextStyle\(')],
    'use a Type.* or Mono.* token (Strong variants carry the weight)',
    exempt: ['lib/ui/core/tokens.dart', 'lib/ui/render/terminal/'],
  ),
  Rule(
    'raw-alpha',
    [RegExp(r'\.withValues\(\s*alpha:')],
    'use a Ds role or getter (wash, washPressed, accentWash, pressTint, faint...)',
    exempt: ['lib/ui/core/tokens.dart'],
  ),
  Rule(
    'raw-radius',
    [RegExp(r'\b(?:BorderRadius|Radius)\.circular\(\s*[\d.]')],
    'use Radii.xs/sm/md/lg/pill',
  ),
  Rule(
    'raw-duration',
    [RegExp(r'\bDuration\(\s*(?:milliseconds|seconds|microseconds|minutes):')],
    'use a Motion.* duration or a Dwell.* timer',
    exempt: ['lib/ui/core/motion.dart'],
  ),
  Rule(
    'raw-curve',
    [RegExp(r'\bCubic\('), RegExp(r'\bCurves\.')],
    'use Motion.easeOut / Motion.curved()',
    exempt: ['lib/ui/core/motion.dart'],
  ),
  Rule(
    'raw-spring',
    [RegExp(r'\bSpringDescription(?:\(|\.with)')],
    'use a Springs.* token',
    exempt: ['lib/ui/core/motion.dart'],
  ),
  Rule(
    'raw-size',
    [
      RegExp(r'\bsize:\s*[\d.]'),
      RegExp(r'\bSizedBox\([^)]*\b(?:height|width):\s*[\d.]'),
      RegExp(r'\bEdgeInsets\.\w+\([^)]*(?<![\w.])\d'),
    ],
    'use IconSize.*, Gap.* or a component size',
    include: ['lib/ui/features/', 'lib/ui/shell/'],
  ),
  Rule(
    'raw-haptic',
    [RegExp(r'\bHapticFeedback\.')],
    'use Haptics.tick/hold/sent/armed/failed',
    exempt: ['lib/ui/core/motion.dart'],
  ),
  Rule(
    'clipboard',
    [RegExp(r'\bClipboard\.setData\(')],
    'use copyText() from the kit: it says "copied" only where Android does not',
    include: ['lib/'],
    exempt: ['lib/ui/core/clipboard.dart'],
  ),
  Rule(
    'material',
    [
      RegExp(
        r'\b(?:Icons\.|InkWell\(|ListTile\(|AlertDialog\(|SnackBar\(|AppBar\(|Card\(|ElevatedButton\(|TextButton\(|'
        r'OutlinedButton\(|FilledButton\(|IconButton\(|PopupMenuButton\(|ExpansionTile\(|SegmentedButton\(|'
        r'FloatingActionButton\(|BackdropFilter\()',
      ),
    ],
    'herdr is not Material: use the kit (buttons.dart, sheets.dart, toast.dart, Lucide icons)',
  ),
  Rule(
    'modal-sheet',
    [RegExp(r'\bshowModalBottomSheet\b')],
    'use showAppSheet + SheetScaffold',
    exempt: ['lib/ui/core/sheets.dart'],
  ),
  Rule('loop', [RegExp(r'\.repeat\(')], 'nothing loops at rest (BusySpinner is the one exception)',
      exempt: ['lib/ui/core/spinner.dart']),
  Rule(
    'kit-import',
    [RegExp(r'''^import\s+['"](?:package:herdr_mobile/ui/core/(?!kit\.dart)|(?:\.\./)+core/(?!kit\.dart))''')],
    'import the kit through ui/core/kit.dart',
    include: ['lib/ui/features/', 'lib/ui/shell/', 'lib/ui/render/', 'lib/ui/support/'],
  ),
  Rule(
    'layer',
    [RegExp(r'''^import\s+['"].*(?:ui/features/|ui/render/|ui/support/|\.\./features/|\.\./render/|\.\./support/)''')],
    'the kit imports nothing above it',
    include: ['lib/ui/core/'],
  ),
  Rule(
    'layer',
    [RegExp(r'''^import\s+['"].*(?:ui/features/|\.\./features/)''')],
    'a renderer imports no feature',
    include: ['lib/ui/render/'],
  ),
  Rule(
    'layer',
    [RegExp(r'''^import\s+['"](?:package:flutter|package:herdr_mobile/ui/|(?:\.\./)+ui/)''')],
    'words are pure Dart: no Flutter, no UI',
    include: ['lib/data/words/'],
  ),
];

final _allow = RegExp(r'//\s*design-lint:\s*allow\(([\w-]+(?:\s*,\s*[\w-]+)*)\)\s*(.*)$');

final class Finding {
  Finding(this.path, this.line, this.rule, this.message);
  final String path;
  final int line;
  final String rule;
  final String message;
}

/// The rule ids a line is allowed to break, from an allow comment on it or on
/// the line above. An allow with no reason allows nothing and is reported.
Set<String> _allowed(List<String> lines, int i, void Function(String) bad) {
  final ids = <String>{};
  for (final j in [i, i - 1]) {
    if (j < 0) continue;
    final m = _allow.firstMatch(lines[j]);
    if (m == null) continue;
    if (j == i - 1 && !lines[j].trimLeft().startsWith('//')) continue;
    if (m[2]!.trim().isEmpty) {
      bad('design-lint allow(${m[1]}) needs a reason after it');
      continue;
    }
    ids.addAll(m[1]!.split(',').map((s) => s.trim()));
  }
  return ids;
}

List<Finding> lint(Directory app) {
  final findings = <Finding>[];
  final lib = Directory('${app.path}/lib');
  final files = lib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final path = file.path.substring(app.path.length + 1);
    final rules = _rules.where((r) => r.appliesTo(path)).toList();
    if (rules.isEmpty) continue;
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final code = raw.trimLeft();
      if (code.startsWith('//')) continue;
      // Drop a trailing comment so prose never trips a rule.
      final cut = code.indexOf(RegExp(r'\s//'));
      final text = cut < 0 ? code : code.substring(0, cut);
      final allowed = _allowed(lines, i, (m) => findings.add(Finding(path, i + 1, 'allow', m)));
      for (final rule in rules) {
        if (allowed.contains(rule.id)) continue;
        if (rule.patterns.any((p) => p.hasMatch(text))) {
          findings.add(Finding(path, i + 1, rule.id, rule.message));
        }
      }
    }
  }
  return findings;
}

void main(List<String> args) {
  final here = Directory.current.path;
  final app = Directory(File('$here/pubspec.yaml').existsSync() ? here : '$here/app');
  if (!File('${app.path}/pubspec.yaml').existsSync()) {
    stderr.writeln('design_lint: run from the repo root or from app/');
    exit(2);
  }
  final findings = lint(app);
  if (args.contains('--report')) {
    final byRule = <String, int>{};
    final byFolder = <String, int>{};
    for (final f in findings) {
      byRule[f.rule] = (byRule[f.rule] ?? 0) + 1;
      final parts = f.path.split('/');
      final folder = parts.length > 4 ? parts.take(4).join('/') : parts.take(parts.length - 1).join('/');
      byFolder[folder] = (byFolder[folder] ?? 0) + 1;
    }
    stdout.writeln('${findings.length} findings');
    for (final e in byRule.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
      stdout.writeln('  ${e.key.padRight(14)} ${e.value}');
    }
    stdout.writeln('by folder:');
    for (final e in byFolder.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
      stdout.writeln('  ${e.value.toString().padLeft(5)}  ${e.key}');
    }
    return;
  }
  for (final f in findings) {
    stdout.writeln('${f.path}:${f.line} ${f.rule} ${f.message}');
  }
  if (findings.isNotEmpty) {
    stderr.writeln('design_lint: ${findings.length} findings');
    exit(1);
  }
}
