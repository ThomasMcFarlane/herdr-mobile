/// Cleaning of a Mermaid source before it is laid out. Pure Dart.
library;

// An agent writes `\n` in a label and means a line break (141 of 2,213 diagrams
// in a corpus of real answers). The engine would print the two characters.
final _escapedNewline = RegExp(r'\\n');

// `A -.text.-> B`: dotted link with text and no spaces. Valid Mermaid, but the
// engine throws `malformed link "-."` (14 of 1,312 flowcharts). `-.->` has no
// text and must stay as it is, so the text must start and end on a character
// that is not a dot, dash, `>` or space.
final _dottedText = RegExp(r'-\.(?=[^\s>.\-])([^\n]*?[^\s.\-])\.->');

/// [source] ready for the engine: a leading BOM and trailing spaces dropped,
/// `\n` in a label a real line break, dotted-link text spaced out.
///
/// What the person copies is always the original, never this.
String normalizeMermaid(String source) {
  var text = source.startsWith('\uFEFF') ? source.substring(1) : source;
  text = text.split('\n').map((l) => l.trimRight()).join('\n');
  text = text.replaceAll(_escapedNewline, '<br/>');
  return text.replaceAllMapped(_dottedText, (m) => '-. ${m[1]} .->');
}
