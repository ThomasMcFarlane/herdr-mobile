import 'package:flutter/widgets.dart';

import 'mermaid_layout.dart';

/// Opens a drawn diagram full screen. The renderer does not know the viewer
/// (`ui/features/photos`), so the app installs it once: the same seam
/// `MdActions` is for links. A surface without one draws the diagram without
/// the Open button and the tap.
typedef OpenDiagram = Future<void> Function(BuildContext context, MermaidDrawn drawn);

class MdDiagramOpener extends InheritedWidget {
  const MdDiagramOpener({super.key, required this.open, required super.child});

  final OpenDiagram open;

  static MdDiagramOpener? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MdDiagramOpener>();

  @override
  bool updateShouldNotify(MdDiagramOpener oldWidget) => open != oldWidget.open;
}
