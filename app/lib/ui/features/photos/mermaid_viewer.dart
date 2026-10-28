import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../render/mermaid/mermaid_cache.dart';
import '../../render/mermaid/mermaid_layout.dart';
import 'photo_item.dart';
import 'photo_viewer.dart';

/// Space around the diagram in the picture, dp.
const _margin = 16.0;

/// The most pixels on a side: the viewer decodes up to this
/// (`photoSharpSide`), so a larger picture would be shrunk again.
const _maxSide = 4096.0;

/// A diagram full screen, in the one photo viewer: pinch, double tap, pan,
/// and `Save or share` (the picture is a PNG of what was on the screen, on the
/// theme's surface colour).
///
/// The route goes up on the frame of the tap. The picture is made inside the
/// viewer's own load, so the wait is the viewer's (progress, no blank).
Future<void> openDiagramViewer(BuildContext context, MermaidDrawn drawn) {
  final surface = context.ds.surface;
  return openPhotoViewer(
    context,
    items: [
      PhotoItem(
        id: 'mermaid:${identityHashCode(drawn)}',
        name: '${drawn.kind.label}.png',
        mime: 'image/png',
        origin: 'Diagram',
        source: MemoryPhotoSource(() => _png(drawn, surface)),
      ),
    ],
  );
}

Future<Uint8List> _png(MermaidDrawn drawn, Color surface) async {
  final w = drawn.scene.size.width + 2 * _margin;
  final h = drawn.scene.size.height + 2 * _margin;
  final ratio = math.max(1.0, math.min(3.0, _maxSide / math.max(w, h)));

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..scale(ratio)
    ..drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = surface)
    ..translate(_margin, _margin);
  final scene = MermaidCache.recordUncached(drawn);
  canvas.drawPicture(scene);
  final picture = recorder.endRecording();
  final image = await picture.toImage((w * ratio).ceil(), (h * ratio).ceil());
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
    scene.dispose();
  }
}
