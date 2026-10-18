// The design lint (tool/design_lint.dart) catches raw values however the code
// is wrapped, and lets through only what it should.
import 'package:flutter_test/flutter_test.dart';

import '../../tool/design_lint.dart' show lintSource;

const _feature = 'lib/ui/features/demo/demo.dart';

/// `rule@line` for every finding in [source], as a feature file.
List<String> _lint(String source, {String path = _feature}) =>
    [for (final f in lintSource(path, source)) '${f.rule}@${f.line}'];

void main() {
  test('raw values split over lines are caught on the line that holds them', () {
    const source = '''
final a = SizedBox(
  width: 12,
);
final b = EdgeInsets.symmetric(
  horizontal: 12,
);
final c = Duration(
  milliseconds: 300,
);
''';
    expect(_lint(source), unorderedEquals(['raw-size@2', 'raw-size@5', 'raw-duration@8']));
  });

  test('the patterns the line rules missed are caught', () {
    const source = '''
final a = Color.fromARGB(255, 0, 0, 0);
final b = Color.fromRGBO(0, 0, 0, 1);
final c = Button(iconSize: 18);
final d = Type.body.copyWith(height: 1.2);
final e = Type.body.copyWith(letterSpacing: 0.3);
final f = CircularProgressIndicator();
final g = LinearProgressIndicator(value: v);
final h = Container(height: 40);
''';
    expect(
      _lint(source),
      unorderedEquals([
        'raw-color@1',
        'raw-color@2',
        'raw-size@3',
        'raw-type@4',
        'raw-type@5',
        'spinner@6',
        'spinner@7',
        'raw-size@8',
      ]),
    );
  });

  test('tokens, strokes, zero floors and comments pass', () {
    const source = '''
// SizedBox(width: 12) in prose
final a = SizedBox(
  width: Gap.md, // was 12
);
final b = Border(top: BorderSide(color: c, width: 1));
final c = BoxConstraints(minWidth: 0);
final d = Type.body.copyWith(height: m.lineHeight / size);
''';
    expect(_lint(source), isEmpty);
  });

  test('an allow with a reason covers a wrapped value; one without a reason is a finding', () {
    const allowed = '''
// design-lint: allow(raw-size) a measured photo frame
final a = EdgeInsets.symmetric(
  horizontal: 12,
);
final b = SizedBox(
  // design-lint: allow(raw-size) a measured photo frame
  width: 12,
);
''';
    expect(_lint(allowed), isEmpty);
    const bare = '''
// design-lint: allow(raw-size)
final a = SizedBox(width: 12);
''';
    expect(_lint(bare), unorderedEquals(['allow@1', 'raw-size@2']));
  });

  test('the kit is exempt from raw sizes but not from raw colours', () {
    const source = 'final a = SizedBox(width: 12, child: ColoredBox(color: Color(0xFF000000)));\n';
    expect(_lint(source, path: 'lib/ui/core/demo.dart'), ['raw-color@1']);
  });
}
