import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Motion tokens. UI motion stays under ~300ms and uses one strong ease-out
/// curve (the same curve Telegram calls EASE_OUT_QUINT): built-in curves are
/// too weak, and ease-in delays the moment the person is watching. Exits run
/// the same curve forward ([curved], [easeOutExit]), so they start fast too;
/// Material 3 accelerates exits, herdr deliberately does not.
abstract final class Motion {
  /// Entering / responding to input. Starts fast, settles gently.
  static const easeOut = Cubic(0.23, 1, 0.32, 1);

  /// [easeOut] for a value running backwards (an exit, a collapse): fast
  /// first, like the entrance. A plain reverse of [easeOut] would be ease-in.
  static final easeOutExit = easeOut.flipped;

  /// [parent] through [easeOut], and through [easeOutExit] when it reverses.
  /// Every curved animation that can run both ways uses this.
  static CurvedAnimation curved(Animation<double> parent) =>
      CurvedAnimation(parent: parent, curve: easeOut, reverseCurve: easeOutExit);

  /// Press-down feedback: snap in.
  static const press = Duration(milliseconds: 100);

  /// Release: slightly slower than the press, so the response never feels abrupt.
  static const release = Duration(milliseconds: 180);

  /// An opacity-only change of what is on screen (a tab switch, and a page
  /// under reduced motion in place of the slide).
  static const fade = Duration(milliseconds: 120);

  /// Default for state changes (colour, size of small elements).
  static const standard = Duration(milliseconds: 200);

  /// Expanding/collapsing sections, a scroll the app makes.
  static const expand = Duration(milliseconds: 220);

  /// A one-shot draw-in: a status glyph settling, a badge arriving, a number
  /// rolling.
  static const settle = Duration(milliseconds: 240);

  /// Bottom sheet, toast and floating bars, in and out (out < in).
  static const sheetIn = Duration(milliseconds: 250);
  static const sheetOut = Duration(milliseconds: 190);

  /// Page push/pop (the Cupertino slide, shortened from the SDK's 500 ms).
  static const page = Duration(milliseconds: 260);

  /// The check that draws itself after a connection test passes.
  static const draw = Duration(milliseconds: 320);

  /// How long the wash on a card that just changed section takes to fade. A
  /// fade-out of a highlight, not a movement: it may outlast a transition.
  static const arrival = Duration(milliseconds: 420);

  /// The brand mark drawing itself on first run.
  static const brand = Duration(milliseconds: 420);

  /// A hold-to-confirm fills slowly and linearly, then snaps back fast.
  static const holdFill = Duration(milliseconds: 550);
  static const holdSnapBack = Duration(milliseconds: 200);

  /// How far a floating thing (a pill, a bar, a toast) travels as it enters.
  static const travel = 16.0;

  /// The scale an entering element starts from (never below 0.9).
  static const enterScale = 0.97;

  /// How far a changed number rolls, as a fraction of its font size.
  static const rollTravel = 0.3;

  /// Honour the platform's reduced-motion setting: drop movement, keep
  /// colour/opacity changes.
  static bool reduced(BuildContext context) => MediaQuery.disableAnimationsOf(context);

  /// [d], or nothing under reduced motion.
  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;

  /// Duration for a control's pressed/released colour and scale: snap in,
  /// ease out.
  static Duration pressing(bool down) => down ? press : release;
}

/// How far a control shrinks under the finger, by its size: the bigger the
/// surface, the less it moves.
abstract final class PressScale {
  /// Wide surfaces: answer chips, strips, toasts' actions.
  static const panel = 0.985;

  /// Buttons and floating pills.
  static const button = 0.97;

  /// Chips.
  static const chip = 0.96;

  /// Round and icon-only controls, tiles in a grid.
  static const icon = 0.92;
}

/// Springs for anything a finger hands over (a drag released, a fling).
/// Critically damped unless the gesture carried momentum; then a little
/// bounce (ratio >= 0.85), never more.
abstract final class Springs {
  /// A sheet or a photo let go: carries the finger's speed and lands softly.
  static final carry = SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 0.88);

  /// Back to rest with no overshoot (a drag cancelled, a double tap).
  static final settle = SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 1);

  /// A light, quick object (the tab bar's capsule after a scrub).
  static final snap = SpringDescription.withDampingRatio(mass: 1, stiffness: 1500, ratio: 0.85);

  /// A swiped row that did not go far enough, coming back.
  static final recoil = SpringDescription.withDurationAndBounce(duration: const Duration(milliseconds: 380), bounce: 0.1);

  /// A swiped row leaving.
  static final out = SpringDescription.withDurationAndBounce(duration: const Duration(milliseconds: 260));

  /// When a spring counts as arrived, by what it moves.
  static const pixel = Tolerance(distance: 0.05, velocity: 1);
  static const scale = Tolerance(distance: 0.0005, velocity: 0.002);
  static const swipe = Tolerance(distance: 0.2, velocity: 8);

  /// Seconds of a fling's speed that carry on after the finger lifts, to pick
  /// where a sheet or the tab capsule lands (Apple's projection).
  static const projectSheet = 0.25;
  static const projectTab = 0.1;
}

/// Timers, not animations: how long something waits or stays.
abstract final class Dwell {
  /// New content under a finger takes no tap for this long.
  static const tapGuard = Duration(milliseconds: 450);

  /// A press held this long is a hold (before it, a tap).
  static const holdIntent = Duration(milliseconds: 150);

  /// How long the "hold to …" hint stays after an early release.
  static const holdHint = Duration(milliseconds: 2400);

  /// A primed risky answer waits this long for its second tap.
  static const confirm = Duration(seconds: 4);

  /// A copy button shows its check this long.
  static const copied = Duration(milliseconds: 1600);

  /// A held key repeats after [keyRepeatDelay], then every [keyRepeatGap].
  static const keyRepeatDelay = Duration(milliseconds: 320);
  static const keyRepeatGap = Duration(milliseconds: 45);

  /// The keyboard counts as still once its inset has not moved for this long.
  static const keyboardQuiet = Duration(milliseconds: 120);

  /// A spinner shows only for work that takes longer than this.
  static const spinnerDelay = Duration(milliseconds: 120);

  /// A toast stays: short words, longer words, and one with an action.
  static const toastShort = Duration(milliseconds: 1500);
  static const toastLong = Duration(milliseconds: 2750);
  static const toastAction = Duration(milliseconds: 5000);
}

/// The app's haptic vocabulary, as `Motion` is its motion vocabulary. Five
/// meanings, each one feel; screens say what happened, never which motor
/// pattern. Android's `HapticFeedback` has few strengths, so they are kept for
/// distinct moments: a tick is common, everything else is rare enough to mean
/// something. [hold] and [armed] share a motor: both say "something firm
/// happened under your finger".
abstract final class Haptics {
  /// A tap, a selection, a step: the light click of choosing something.
  static void tick() => unawaited(HapticFeedback.selectionClick());

  /// A long press registered (pick, open actions): a firmer press.
  static void hold() => unawaited(HapticFeedback.mediumImpact());

  /// Something went out: an answer, a message, a key. Soft, once, and only
  /// when it was accepted, never on the tap that asked for it.
  static void sent() => unawaited(HapticFeedback.lightImpact());

  /// A risky answer is primed and waits for its confirmation; a new question
  /// arrived (rate-limited by `ArrivalCue`, never fired by a widget's build).
  static void armed() => unawaited(HapticFeedback.mediumImpact());

  /// Something failed, or a guarded action was refused: the heaviest one, so
  /// it cannot be mistaken for a tap.
  static void failed() => unawaited(HapticFeedback.heavyImpact());
}
