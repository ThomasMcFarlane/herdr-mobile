import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// Fades the edge of a sideways scroller that has more behind it: the table's,
/// and a diagram's.
class MdEdgeFade extends StatelessWidget {
  const MdEdgeFade({super.key, required this.controller, required this.child});

  final ScrollController controller;
  final Widget child;

  static const _fade = 28.0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    child: child,
    builder: (context, child) {
      var left = false;
      var right = true;
      if (controller.hasClients && controller.position.hasContentDimensions) {
        final p = controller.position;
        left = p.pixels > 1;
        right = p.pixels < p.maxScrollExtent - 1;
      }
      if (!left && !right) return child!;
      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) {
          final f = math.min(_fade / rect.width, 0.45);
          // The mask reads alpha only: any opaque colour keeps, transparent fades.
          final solid = context.ds.text;
          final clear = solid.withAlpha(0);
          return LinearGradient(
            colors: [left ? clear : solid, solid, solid, right ? clear : solid],
            stops: [0, f, 1 - f, 1],
          ).createShader(rect);
        },
        child: child,
      );
    },
  );
}
