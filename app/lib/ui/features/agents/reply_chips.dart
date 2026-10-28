import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/pane_preview.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'quick_reply_controller.dart';

/// The one-tap answers to a blocked agent's prompt, full-width and 44 high,
/// each labelled with its own option text.
///
/// Feedback lives ON the chip you pressed, so the block never changes size:
/// a risky option (`needsConfirm`) is held, not tapped: the chip fills left to
/// right while the finger stays down ("Hold to send · pushes to a remote", its
/// `risk`; "Hold to send" when none is known) and sends when the fill ends; a
/// tap or an early release sends nothing and says how to send. Assistive
/// technology cannot hold: its activation is the two-step flow (the first
/// primes the chip, "Hold or tap again · pushes to a remote", the second
/// sends). While the request is in flight a chip shows a spinner (the pane is
/// read again first, then the keys go); afterwards it says "Sent: 1. Yes" in
/// green (the others dim, so a second answer cannot slip out); a failure says
/// so on that chip and a hold retries it. When the pane turned out to ask
/// something else, nothing was sent: the new question is shown and the chip
/// under the thumb says "The question changed" for a moment, taking no tap.
/// Options without a gate send on a tap.
///
/// On a card ([fixedHeight]) every chip is one line, which makes the block's
/// height a function of the option count ([heightFor]); the card reserves it.
/// In the sheet chips wrap and all options show.
class ReplyChips extends StatelessWidget {
  const ReplyChips({
    super.key,
    required this.prompt,
    required this.controller,
    required this.onChoose,
    required this.onMore,
    this.fixedHeight = true,
    this.limit = cardLimit,
    this.guarded = false,
  });

  final PromptInfo prompt;

  /// Owns the send state the chips draw; a tap goes to [onChoose], which the
  /// owner routes to `controller.choose` (it may add bookkeeping around it).
  final QuickReplyController controller;
  final Future<void> Function(QuickReply reply) onChoose;

  /// "N more…" opens the sheet, where every option shows. Cards only.
  final VoidCallback? onMore;
  final bool fixedHeight;

  /// Chips a fixed-height block shows before the rest collapse into a "more"
  /// chip (which takes the last place).
  final int limit;

  /// The answers just appeared or just moved: they take no taps and are drawn
  /// dimmed until the person has had time to see them (see `Dwell.tapGuard`).
  final bool guarded;

  /// Chips a card shows (a "more" chip takes the last place when there are
  /// more options than this).
  static const cardLimit = 5;

  static const _gap = Gap.sm;
  static const _chip = kMinTap;

  /// Chips drawn on a card for [prompt] (the "more" chip counts as one).
  static int count(PromptInfo prompt, {int limit = cardLimit}) =>
      prompt.replies.length <= limit ? prompt.replies.length : limit;

  /// Height of a card's chip block with [n] chips.
  static double heightFor(int n) => n == 0 ? 0 : n * _chip + (n - 1) * _gap;

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: controller, builder: (context, _) => _chips(context, controller));

  Widget _chips(BuildContext context, QuickReplyController c) {
    final phase = c.phase;
    final overflow = fixedHeight && prompt.replies.length > limit;
    final shown = overflow ? prompt.replies.sublist(0, limit - 1) : prompt.replies;
    final hidden = prompt.replies.length - shown.length;
    // While a request is out or answered, only its own chip is live.
    final locked = guarded || phase == ReplyPhase.sending || phase == ReplyPhase.sent;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, r) in shown.indexed) ...[
          if (i > 0) const SizedBox(height: _gap),
          AnswerChip(
            // A hold belongs to the answer under the finger: a new prompt
            // brings new chips, which drops it.
            key: ValueKey((i, r)),
            label: r.label,
            reason: r.risk,
            risk: r.needsConfirm ? AnswerRisk.gate : AnswerRisk.none,
            state: _stateOf(c, phase, r),
            hold: r.needsConfirm,
            error: c.error,
            enabled: !locked,
            maxLines: fixedHeight ? 1 : 2,
            onTap: () => onChoose(r),
            onHeld: () {
              controller.confirmByHold(r);
              unawaited(onChoose(r));
            },
          ),
        ],
        if (overflow) ...[
          const SizedBox(height: _gap),
          _MoreChip(label: '$hidden more…', onTap: onMore != null && !locked ? onMore : null),
        ],
      ],
    );
  }

  static AnswerChipState _stateOf(QuickReplyController c, ReplyPhase phase, QuickReply r) {
    if (c.confirming == r) return AnswerChipState.primed;
    if (c.subject != r) return AnswerChipState.rest;
    return switch (phase) {
      ReplyPhase.sending => AnswerChipState.sending,
      ReplyPhase.sent => AnswerChipState.sent,
      ReplyPhase.failed => AnswerChipState.failed,
      ReplyPhase.changed => AnswerChipState.changed,
      _ => AnswerChipState.rest,
    };
  }
}

/// `N more…`: opens the sheet, where every option shows.
class _MoreChip extends StatelessWidget {
  const _MoreChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      scale: PressScale.panel,
      button: true,
      minTapSize: kMinTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minHeight: kMinTap),
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        decoration: BoxDecoration(
          color: pressed && onTap != null ? ds.fillPressed : ds.fill,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.answer.copyWith(color: onTap != null ? ds.accentText : ds.textMuted),
              ),
            ),
            Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textTertiary),
          ],
        ),
      ),
    );
  }
}
