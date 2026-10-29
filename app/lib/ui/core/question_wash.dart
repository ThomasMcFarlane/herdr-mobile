import 'package:flutter/material.dart';

import 'press.dart';
import 'text_action.dart';
import 'theme.dart';
import 'tokens.dart';

/// How much of a question a [QuestionWash] shows.
enum QuestionWashSize {
  /// Two lines of question and three of subject, and `Read all` when either
  /// is cut: the board card and the pane's answer dock.
  compact,

  /// Everything: the reply sheet and the permission dock.
  full,
}

/// The question a blocked agent asks, on the faint "needs you" wash, and under
/// it what the question is about (the command, the path) in mono: the thing
/// the answer approves is always in front of the thumb that approves it.
///
/// With a subject, the subject is the largest thing on the wash (`Mono.input`)
/// and the question steps back to a secondary line: the person approves the
/// command, and "Do you want to proceed?" says nothing the chips do not. Why:
/// in `Mono.base` under a `Type.prompt` question, the command was smaller
/// than both the question and the answers. Without a subject the question is
/// the thing, and keeps `Type.prompt`.
///
/// [leading] sits before the question (a tool icon), [trailing] after it
/// (room for a button that floats over the wash), and [details] below the
/// subject (evidence or a form the caller lays out itself). With a [footer]
/// (a form's buttons) the question and details scroll above it, which needs
/// a wash with a bounded height.
class QuestionWash extends StatelessWidget {
  const QuestionWash({
    super.key,
    required this.question,
    this.subject,
    this.size = QuestionWashSize.compact,
    this.leading,
    this.trailing,
    this.details,
    this.questionIsHeader = false,
    this.footer,
    this.onReadAll,
  });

  final String question;

  /// What the question is about; null or empty when none.
  final String? subject;
  final QuestionWashSize size;
  final Widget? leading;
  final Widget? trailing;
  final Widget? details;
  final Widget? footer;

  /// The question names the screen region (a screen reader's header).
  final bool questionIsHeader;

  /// Opens the whole question where it fits (compact only); `Read all` shows
  /// only when it is set and the text is cut.
  final VoidCallback? onReadAll;

  static const _lines = 2;

  /// A compact subject shows one line more than the question: it is what is
  /// approved, and a command often wraps.
  static const _subjectLines = 3;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final compact = size == QuestionWashSize.compact;
    final subject = this.subject ?? '';
    final questionStyle = subject.isEmpty
        ? Type.prompt.copyWith(color: ds.text)
        : Type.secondaryStrong.copyWith(color: ds.textSecondary);
    final subjectStyle = Mono.input.copyWith(color: ds.text);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    Widget text(BoxConstraints? box) {
      final cut =
          box != null &&
          (_cut(question, questionStyle, box.maxWidth, scaler, direction, _lines) ||
              (subject.isNotEmpty && _cut(subject, subjectStyle, box.maxWidth, scaler, direction, _subjectLines)));
      Widget q = Text(
        question,
        maxLines: compact ? _lines : null,
        overflow: compact ? TextOverflow.ellipsis : null,
        style: questionStyle,
      );
      if (questionIsHeader) q = Semantics(header: true, child: q);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          q,
          if (subject.isNotEmpty) ...[
            const SizedBox(height: Gap.xs),
            Text(
              subject,
              maxLines: compact ? _subjectLines : null,
              overflow: compact ? TextOverflow.ellipsis : null,
              style: subjectStyle,
            ),
          ],
          if (cut) TextAction(label: 'Read all', onTap: onReadAll!),
        ],
      );
    }

    final measure = compact && onReadAll != null;
    final details = this.details;
    final footer = this.footer;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leading != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: Gap.hair),
                child: leading,
              ),
              const SizedBox(width: Gap.sm),
            ],
            Expanded(child: measure ? LayoutBuilder(builder: (context, box) => text(box)) : text(null)),
            ?trailing,
          ],
        ),
        ?details,
      ],
    );
    return Container(
      constraints: const BoxConstraints(minHeight: kMinTap),
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(color: ds.blockedWash, borderRadius: BorderRadius.circular(Radii.sm)),
      child: footer == null
          ? body
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(child: SingleChildScrollView(child: body)),
                footer,
              ],
            ),
    );
  }

  static bool _cut(String text, TextStyle style, double width, TextScaler scaler, TextDirection direction, int lines) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: lines,
      textScaler: scaler,
      textDirection: direction,
    )..layout(maxWidth: width);
    final cut = painter.didExceedMaxLines;
    painter.dispose();
    return cut;
  }
}
