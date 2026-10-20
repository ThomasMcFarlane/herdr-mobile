// Renders the Markdown corpus to PNGs for review (light and dark, 412x892 and
// 320x640, text scale 1 and 1.6): the worst cases, the corpus messages and the
// answers real agents wrote. Off by default; it writes files:
//
//   MD_SHOTS=1 flutter test test/markdown/render_shots_test.dart
//
// Output: $MD_SHOTS_DIR (default /tmp/md_shots)/<case>-<light|dark>-<w>x<h>-s<scale>[-<n>].png
// MD_SHOTS_ONLY=name1,name2 limits the cases.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/render/markdown/markdown.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

import '../support/shot.dart' show loadAppFonts;
import 'support/render_corpus.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_cache.dart';
import 'package:herdr_mobile/ui/render/mermaid/md_diagram_opener.dart';
import 'package:herdr_mobile/ui/render/mermaid/mermaid_layout.dart';

class _Page extends StatefulWidget {
  const _Page({required this.markdown, this.controller, this.tone = MdTone.reading});

  final String markdown;
  final ScrollController? controller;
  final MdTone tone;

  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  late final MdDocument _doc = parseMd(widget.markdown);
  final _open = <int>{};

  @override
  Widget build(BuildContext context) {
    final blocks = _doc.blocks;
    final ds = context.ds;
    return Material(
      color: ds.bg,
      child: MdDiagramOpener(
        open: (context, drawn) async {},
        child: MdActions(
        onLink: (context, url) {},
        onPath: (context, path, line) {},
        child: MdToneScope(
          tone: widget.tone,
          child: SelectionArea(
          child: ListView.builder(
            controller: widget.controller,
            padding: EdgeInsets.fromLTRB(Gap.lg, MediaQuery.paddingOf(context).top + Gap.md, Gap.lg, Gap.xl),
            itemCount: blocks.length,
            itemBuilder: (context, i) => Padding(
              padding: EdgeInsets.only(top: mdBlockGap(i == 0 ? null : blocks[i - 1], blocks[i])),
              child: MdBlockView(
                block: blocks[i],
                expanded: _open.contains(i),
                onToggleExpanded: () => setState(() => _open.contains(i) ? _open.remove(i) : _open.add(i)),
              ),
            ),
          ),
          ),
        ),
      ),
      ),
    );
  }
}

/// The quiet tone (a subagent's answer, a work-log note) with what drifts in
/// it: a heading, inline code and a table, each a notch under reading text.
const _quiet = '''
## Findings

The flush runs in `FrameFlush.schedule` before build, once per frame.

| File | Lines | Status |
| --- | ---: | --- |
| `md_styles.dart` | 120 | changed |
| `md_table_view.dart` | 300 | unchanged |
''';

/// Diagrams: every kind the app draws, a left-to-right flowchart that turns,
/// author fills (a pastel on dark), Vietnamese and `\n` labels, a wide sequence
/// diagram that scrolls sideways, a tall one that is cropped, and two that stay
/// code (a kind the app does not draw, a syntax error).
const _mermaid = r'''
How a shell command is wired:

```mermaid
flowchart LR
    User["keyboard"] --> Shell["shell"]
    Shell -->|"pipe"| Cmd1["cmd1\n(child process)"]
    Cmd1 -->|"stdout fd"| Cmd2["cmd2\n(child process)"]
    Shell -->|"redirect"| File["file\n(vfs_server)"]
    Shell --> Env["environment\nvariables"]
    Shell -->|"fork+exec"| Utils["ls / cat / cp\necho / rm / mkdir"]
```

The skills that were mirrored, with the author's colours:

```mermaid
flowchart TD
    subgraph Claude Code Skills
        CC1[x-story-epic-full/SKILL.md]
        CC2[x-story-epic/SKILL.md]
    end
    subgraph Copilot Counterparts
        GH1[x-story-epic-full.md]
        GH2[x-story-epic.md]
    end
    CC1 -->|Espelhar Phase A.5| GH1
    CC2 -->|Espelhar Step 5.5| GH2
    style CC1 fill:#e1f5fe
    style CC2 fill:#e1f5fe
    style GH1 fill:#fff3e0
    style GH2 fill:#fff3e0
```

Where worker accounts come from:

```mermaid
flowchart TD
    E[Import Excel hàng loạt] --> ACC
    S2[Tạo đơn lẻ trên dashboard] --> ACC
    NCB[Tích hợp đối tác NCB] --> ACC
    ACC[(Tài khoản công nhân<br/>CCCD + ảnh khuôn mặt + nhà thầu + vị trí)]
    ACC --> READY[Sẵn sàng cho công nhân<br/>tự đăng nhập trên app]
```

The face sign-in call:

```mermaid
sequenceDiagram
    participant App as MobileApp
    participant BE as suneye_apps
    participant DB as face_registrations
    App->>BE: POST /api/v1/auth/face
    BE-->>App: JWT + requires_data_consent
    alt requires_data_consent
        App->>App: /data-consent
        App->>BE: POST /api/v1/worker/data-consent/accept
        BE->>DB: set data_consent_accepted_at, data_consent_version
        BE-->>App: requires_data_consent=false
    else already consented
        App->>App: /home
    end
    Note over App,BE: the token lasts 4 minutes
```

The loop states:

```mermaid
stateDiagram-v2
    idle --> running: Start
    running --> verifying: Completion detected
    verifying --> running: Verification failed
    verifying --> complete: Verification passed
    running --> max_iterations: Limit reached
    running --> failed: Aborted
```

The tables involved:

```mermaid
erDiagram
    USER ||--o{ ORDER : places
    ORDER ||--|{ LINE_ITEM : contains
    USER {
        int id PK
        string email UK
        datetime created_at
    }
    ORDER {
        int id PK
        int user_id FK
        decimal total
    }
```

The types:

```mermaid
classDiagram
    class Animal {
        +String name
        +eat() void
    }
    class Dog {
        +bark() void
    }
    Animal <|-- Dog
```

A long pipeline:

```mermaid
flowchart TB
    S1[Step one: fetch] --> S2[Step two: parse]
    S2 --> S3[Step three: validate]
    S3 --> S4[Step four: transform]
    S4 --> S5[Step five: enrich]
    S5 --> S6[Step six: dedupe]
    S6 --> S7[Step seven: score]
    S7 --> S8[Step eight: rank]
    S8 --> S9[Step nine: filter]
    S9 --> S10[Step ten: group]
    S10 --> S11[Step eleven: render]
    S11 --> S12[Step twelve: publish]
    S12 --> S13[Step thirteen: notify]
    S13 --> S14[Step fourteen: archive]
```

A schedule, which stays code:

```mermaid
gantt
    title Release
    section Build
    Compile :a1, 2024-01-01, 3d
```

A broken one:

```mermaid
flowchart TD
    A --> B
    B -->
```

Done.
''';

void main() {
  if (Platform.environment['MD_SHOTS'] == null) {
    test('markdown shots are off (set MD_SHOTS=1)', () {}, skip: 'set MD_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['MD_SHOTS_DIR'] ?? '/tmp/md_shots';
  final only = (Platform.environment['MD_SHOTS_ONLY'] ?? '').split(',').where((s) => s.isNotEmpty).toSet();

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  final cases = <String, String>{
    for (final e in worstCases().entries) e.key: e.value,
    for (final m in corpusMessages()) m.name: m.text,
    for (final m in realAnswers()) m.name.replaceAll('/', '_').replaceAll('.jsonl', ''): m.text,
    'big200k': bigMessage(200 * 1024),
    'quiet': _quiet,
    'mermaid': _mermaid,
  };

  Future<void> shoot(WidgetTester tester, String name, String markdown, Size size, double scale, Brightness brightness, {double offset = 0, String suffix = ''}) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
    // The layout futures must be born in this test's zone, and the shots read
    // them in the same isolate: no real time to wait for.
    MermaidCache.shared = MermaidCache((job) async => layoutMermaid(job));
    final key = GlobalKey();
    final controller = ScrollController(initialScrollOffset: offset);
    addTearDown(controller.dispose);
    // A second shot in one test starts from nothing: a mounted list keeps its position.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: key, child: child!),
        ),
        home: _Page(markdown: markdown, controller: controller, tone: name == 'quiet' ? MdTone.quiet : MdTone.reading),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}';
      await File('$out/$name-${brightness.name}-$tag-s$scale$suffix.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size x$scale');
  }

  for (final entry in cases.entries) {
    if (only.isNotEmpty && !only.contains(entry.key)) continue;
    for (final brightness in Brightness.values) {
      for (final (size, scale) in const [
        (Size(412, 892), 1.0),
        (Size(320, 640), 1.0),
        (Size(412, 892), 1.6),
        (Size(320, 640), 1.6),
      ]) {
        testWidgets('${entry.key} ${brightness.name} ${size.width.toInt()} x$scale', (tester) async {
          await shoot(tester, entry.key, entry.value, size, scale, brightness);
          // The worst cases are long: also look further down.
          if (entry.key == 'big200k' || entry.key == 'list300' || entry.key == 'code1000') {
            await shoot(tester, entry.key, entry.value, size, scale, brightness, offset: 900, suffix: '-2');
          }
          if (entry.key == 'mermaid') {
            for (var i = 1; i <= 7; i++) {
              await shoot(tester, entry.key, entry.value, size, scale, brightness, offset: 800.0 * i, suffix: '-${i + 1}');
            }
          }
        });
      }
    }
  }
}
