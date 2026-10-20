import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/render/mermaid/inter_text_measurer.dart';
import 'package:mermaid_core/mermaid_core.dart' as core;
import 'package:mermaid_flutter/mermaid_flutter.dart' show FlutterTextMeasurer;

import '../support/shot.dart' show loadAppFonts;

/// Labels as agents write them: words, Vietnamese with stacked marks, paths,
/// symbols, one unbroken token longer than a node.
const _labels = [
  'Start',
  'Is it working?',
  'User',
  'POST /api/v1/auth/face',
  'JWT + requires_data_consent',
  'Tài khoản công nhân',
  'Tích hợp đối tác NCB',
  'Sẵn sàng cho công nhân tự đăng nhập trên app',
  'Import Excel hàng loạt',
  'Chuẩn bị mặt bằng',
  'Móng, đài, móng bè',
  'x-story-epic-full/SKILL.md',
  'areaLayersLegendsAndSources.ts:70-88',
  'get().get(\'layerA\')',
  'modifies 10-15 layers',
  'Map<string, AsyncState<LayerSource>>',
  'ls / cat / cp / echo / rm / mkdir',
  'vfs_server',
  'Redis Streams Consumer Groups',
  'Containerized File Processors',
  'Metrics & Observability',
  'Prometheus/Grafana, Jaeger',
  'requires_data_consent=false',
  'set data_consent_accepted_at, data_consent_version',
  'Player on partner page',
  'Partner backend (/suneye-token)',
  'idle',
  'running',
  'Limit reached',
  'Completion detected',
  'Verification passed',
  'USER',
  'LINE_ITEM',
  'datetime created_at',
  'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  'Một hai ba bốn năm sáu bảy tám chín mười',
  'The quick brown fox jumps over the lazy dog',
  '0123456789 0123456789',
  'a',
  'iiiiiiiiiiiiiiiiiiii',
  'WWWWWWWWWWWWWWWW',
  'e.g. 1.2.3 — done · ok → next',
  'Hà Nội, Đà Nẵng, Cần Thơ',
  'Ghi nhận khuôn mặt (công trường)',
  'Quản lý lịch sử ra vào của xe',
  'Import → Validate → Save',
  'OK ✓ done',
  'Needs "quotes" and (parens) [brackets]',
  'mixed CASE and lower case words together',
  'x',
];

void main() {
  setUpAll(loadAppFonts);

  for (final weight in [400, 700]) {
    test('Inter table against TextPainter at weight $weight: width within the margin, height equal', () {
      final style = core.TextStyleSpec(fontFamily: 'Inter', fontSize: 13, fontWeight: weight);
      const ours = InterTextMeasurer();
      const painter = FlutterTextMeasurer();
      final rows = <String>[];
      var within = 0;
      for (final label in _labels) {
        final a = ours.measure(label, style);
        final b = painter.measure(label, style);
        final ratio = a.width / b.width;
        rows.add('${ratio.toStringAsFixed(3)}  ${a.height}/${b.height}  $label');
        if (ratio >= 0.99 && ratio <= 1.06) within++;
        expect(ratio, inInclusiveRange(0.97, 1.10), reason: label);
        expect(a.height, b.height, reason: label);
      }
      printOnFailure(rows.join('\n'));
      expect(within / _labels.length, greaterThanOrEqualTo(0.95), reason: 'width ratio within [0.99, 1.06]');
    });
  }

  test('wrapped at 130 we never have fewer lines than the painter, and mostly the same', () {
    // The 3% margin makes a line near the limit wrap one word early: a taller
    // box with a little room, never text that overflows its box.
    const style = core.TextStyleSpec(fontFamily: 'Inter', fontSize: 13);
    const ours = InterTextMeasurer();
    const painter = FlutterTextMeasurer();
    var same = 0;
    final rows = <String>[];
    for (final label in _labels) {
      final a = ours.measure(label, style, maxWidth: 130);
      final b = painter.measure(label, style, maxWidth: 130);
      rows.add('${a.height}/${b.height}  $label');
      expect(a.height, greaterThanOrEqualTo(b.height), reason: label);
      if (a.height == b.height) same++;
    }
    printOnFailure(rows.join('\n'));
    expect(same / _labels.length, greaterThanOrEqualTo(0.8));
  });
}
