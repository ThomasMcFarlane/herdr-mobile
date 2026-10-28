import 'package:flutter/widgets.dart';

import '../../render/markdown/markdown.dart';
import '../../render/visible_text.dart';

final _blankLines = RegExp(r'\n{2,}');

/// A prompt written in Markdown, as a few lines of plain text: the markers go
/// (`##`, `-`, `**`, fences) and blank lines collapse. For a place that clamps
/// the prompt; where it is shown whole, use [AskedMarkdown].
///
/// The prompt is parsed again only when its text changes: the run it belongs
/// to is replaced on every tool call of a running subagent, the prompt is not.
class AskedPreview extends StatefulWidget {
  const AskedPreview({super.key, required this.markdown, required this.maxLines, required this.style});

  final String markdown;
  final int maxLines;
  final TextStyle style;

  @override
  State<AskedPreview> createState() => _AskedPreviewState();
}

class _AskedPreviewState extends State<AskedPreview> {
  String? _source;
  String _text = '';

  @override
  Widget build(BuildContext context) {
    if (widget.markdown != _source) {
      _source = widget.markdown;
      _text = visibleText(parseMd(widget.markdown).plainText)
          .replaceAll('\t', ' ')
          .replaceAll(_blankLines, '\n')
          .trim();
    }
    return Text(_text, maxLines: widget.maxLines, overflow: TextOverflow.ellipsis, style: widget.style);
  }
}

/// A prompt as Markdown, whole, in the quiet tone of a subagent's result. A
/// long code block or table keeps its `Show all` ([MdDocumentView]).
class AskedMarkdown extends StatefulWidget {
  const AskedMarkdown({super.key, required this.markdown});

  final String markdown;

  @override
  State<AskedMarkdown> createState() => _AskedMarkdownState();
}

class _AskedMarkdownState extends State<AskedMarkdown> {
  String? _source;
  late MdDocument _doc;

  @override
  Widget build(BuildContext context) {
    if (widget.markdown != _source) {
      _source = widget.markdown;
      _doc = parseMd(widget.markdown);
    }
    return MdToneScope(
      tone: MdTone.quiet,
      child: MdDocumentView(document: _doc),
    );
  }
}
