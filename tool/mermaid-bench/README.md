# mermaid-bench

Coverage and speed of the Mermaid layout the chat uses (`app/lib/ui/render/mermaid/`), over a corpus of real diagrams. Not part of the app.

```
python3 extract_corpus.py /tmp/mermaid_corpus ~/workspace ~/.claude/projects ~/.omp ~/.pi
dart pub get                                  # needs the Flutter SDK on PATH (herdr_mobile path dependency)
dart build cli -t bin/corpus.dart -o /tmp/mermaid_bench_build && /tmp/mermaid_bench_build/bundle/bin/corpus
```

(`dart build cli`, not `dart compile exe`: the app package graph carries a build-hook package that `compile exe` refuses; same as `tool/md-bench`.)

The corpus is somebody's own notes and agent sessions: it is never committed. `MERMAID_CORPUS` points the bench at another directory.

The bench lays out each block of the five kinds the app draws (flowchart, sequence, state, ER, class) with `layoutMermaid`, the function the app runs in an isolate, so it measures what the app does: normalise the source, the phone profile, both directions of a wide left-to-right flowchart, the readability pass. It exits 1 when a kind's ok-rate is under its floor (`--floor kind=0.97`), its p95 is over `--p95` ms (5) or its worst over `--max` ms (150). Templates (`{{`) and elided blocks (a line that is only `…`) are not diagrams and count nowhere. Failures go to `fails.tsv`.

## Measured (desktop, AOT, 2,213 blocks from the owner's notes and sessions)

The engine as published (`mermaid_core` 0.3.2, its approximate Helvetica measurer, no normalising), JIT, for the baseline the floors came from: flowchart 1,253 of 1,312 drew (95.5%), sequence 559 of 565, ER 61 of 63, state 47 of 47, class 37 of 39. 14 of the flowchart failures were `A -.text.-> B`.

With this change:

| kind | n | ok | median ms | p95 ms | max ms | width p50 | wider than 410 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| flowchart | 1270 | 98.6% | 0.34 | 1.36 | 31.8 | 509 | 62% |
| sequence | 551 | 99.8% | 0.13 | 0.25 | 0.5 | 685 | 90% |
| state | 47 | 100.0% | 0.15 | 0.38 | 1.0 | 488 | 68% |
| er | 62 | 98.4% | 0.23 | 0.63 | 0.7 | 464 | 59% |
| classDiagram | 37 | 97.3% | 0.08 | 0.16 | 0.2 | 212 | 25% |

293 flowcharts were turned top-down. "Wider than 410" is what scrolls sideways in a 328 dp block at the 80% floor. The rest of the failures are broken or truncated diagrams (an unterminated label, a half-written statement).

For scale: the engine's own benchmark puts mermaid.js at 22.5 ms for one flowchart in Chromium, about 300 times slower than the engine, before any WebView cost.

Not measured here: a phone. Desktop numbers are not the phone's; `autoresearch-mermaid.sh` is.
