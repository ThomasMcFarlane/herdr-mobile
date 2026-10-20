/// Label measurement for Mermaid layout without `TextPainter`.
///
/// A diagram is laid out in an isolate (`layoutMermaidOffThread`), where
/// `dart:ui` text layout is not available, so widths come from Inter's advance
/// table (`inter_metrics.dart`, generated from the font the diagram is painted
/// in). Pure Dart: the corpus bench imports it.
library;

import 'dart:math' as math;

import 'package:mermaid_core/mermaid_core.dart' as core;

import 'inter_metrics.dart';

/// Kerning is not in the table, so every line is widened by this much: the
/// painter lays the text out with its own widths and must never wrap a line
/// that the layout measured as fitting.
const _safety = 1.03;

/// Inter's ascent plus descent, as a multiple of the font size.
const _lineHeight = 1.21;

/// Marks, joiners and variation selectors take no room of their own.
bool _zeroWidth(int c) => (c >= 0x0300 && c <= 0x036F) || (c >= 0x200B && c <= 0x200F) || (c >= 0xFE00 && c <= 0xFE0F);

/// East Asian scripts: one em each.
bool _wide(int c) => (c >= 0x1100 && c <= 0x11FF) || (c >= 0x2E80 && c <= 0xD7AF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF00 && c <= 0xFFEF);

/// Pictographs fall back to a colour emoji font, a little wider than an em.
bool _emoji(int c) => c >= 0x1F000 || (c >= 0x2600 && c <= 0x27BF);

final class InterTextMeasurer implements core.TextMeasurer {
  const InterTextMeasurer();

  /// The width of [text] in em, before the safety margin.
  static double _em(String text, Map<int, int> table) {
    var units = 0.0;
    for (final c in text.runes) {
      final advance = table[c];
      if (advance != null) {
        units += advance / interUnitsPerEm;
      } else if (_zeroWidth(c)) {
        continue;
      } else if (_wide(c)) {
        units += 1.0;
      } else if (_emoji(c)) {
        units += 1.2;
      } else {
        units += 0.6;
      }
    }
    return units;
  }

  @override
  core.Size measure(String text, core.TextStyleSpec style, {double? maxWidth}) {
    final table = style.fontWeight >= 600 ? interBoldAdvance : interRegularAdvance;
    final size = style.fontSize;
    double width(String s) => _em(s, table) * size * _safety;

    final lines = <String>[];
    for (final hard in text.split('\n')) {
      if (maxWidth == null || width(hard) <= maxWidth) {
        lines.add(hard);
      } else {
        lines.addAll(_wrap(hard, maxWidth, width));
      }
    }
    var widest = 0.0;
    for (final line in lines) {
      widest = math.max(widest, width(line));
    }
    return core.Size(widest.ceilToDouble(), lines.length * (size * _lineHeight).ceilToDouble());
  }

  /// Greedy wrap where [TextPainter]'s line breaker would: after a space, and
  /// after a hyphen or a slash that is followed by a letter (a path, a URL or a
  /// hyphenated name wraps there, not only at spaces). A piece wider than
  /// [maxWidth] breaks by character.
  static List<String> _wrap(String line, double maxWidth, double Function(String) width) {
    final out = <String>[];
    var current = '';
    for (final piece in _pieces(line)) {
      final candidate = current + piece;
      if (width(candidate.trimRight()) <= maxWidth) {
        current = candidate;
        continue;
      }
      if (current.isNotEmpty) {
        out.add(current.trimRight());
        current = '';
      }
      if (width(piece.trimRight()) <= maxWidth) {
        current = piece;
        continue;
      }
      // Break the long piece where the next character no longer fits.
      var part = '';
      for (final rune in piece.runes) {
        final next = part + String.fromCharCode(rune);
        if (part.isNotEmpty && width(next.trimRight()) > maxWidth) {
          out.add(part);
          part = String.fromCharCode(rune);
        } else {
          part = next;
        }
      }
      current = part;
    }
    if (current.isNotEmpty || out.isEmpty) out.add(current.trimRight());
    return out;
  }

  /// [line] cut after every place it may break, the break character kept on
  /// the piece before it.
  static Iterable<String> _pieces(String line) sync* {
    var start = 0;
    for (var i = 0; i < line.length; i++) {
      final c = line.codeUnitAt(i);
      final breaks = c == 0x20 || ((c == 0x2D || c == 0x2F) && i + 1 < line.length && _letter(line.codeUnitAt(i + 1)));
      if (breaks) {
        yield line.substring(start, i + 1);
        start = i + 1;
      }
    }
    if (start < line.length) yield line.substring(start);
  }

  static bool _letter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c > 0x7F;
}
