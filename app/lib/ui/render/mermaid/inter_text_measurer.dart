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

  /// Greedy wrap at spaces; a word wider than [maxWidth] breaks by character,
  /// as `TextPainter` does.
  static List<String> _wrap(String line, double maxWidth, double Function(String) width) {
    final out = <String>[];
    var current = '';
    for (final word in line.split(' ')) {
      final candidate = current.isEmpty ? word : '$current $word';
      if (width(candidate) <= maxWidth) {
        current = candidate;
        continue;
      }
      if (current.isNotEmpty) {
        out.add(current);
        current = '';
      }
      if (width(word) <= maxWidth) {
        current = word;
        continue;
      }
      // Break the long word where the next character no longer fits.
      var piece = '';
      for (final rune in word.runes) {
        final next = piece + String.fromCharCode(rune);
        if (piece.isNotEmpty && width(next) > maxWidth) {
          out.add(piece);
          piece = String.fromCharCode(rune);
        } else {
          piece = next;
        }
      }
      current = piece;
    }
    if (current.isNotEmpty || out.isEmpty) out.add(current);
    return out;
  }
}
