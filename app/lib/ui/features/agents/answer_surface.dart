import 'package:flutter/widgets.dart';

import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/pane_previews.dart';
import '../../support/tap_guard.dart';
import 'quick_reply_controller.dart';

/// The wiring every surface that answers a blocked agent's question shares
/// (the board card, the pane's answer dock, the reply sheet): a watch on the
/// pane's preview, the question it shows, the tap guard that question arms,
/// and the [QuickReplyController] that sends the answers.
///
/// - A different question (arrived, changed, back with the link) arms the
///   guard again ([TapGuardState.rearmGuard]): its answers are new under the
///   thumb, so they are deaf and dimmed for `Dwell.tapGuard`.
/// - A new question while "Sent" is showing means the answer did something
///   and the agent asked again: the controller is reset so the new chips show
///   now instead of after the hold ([resetsOnNewQuestion]).
/// - The controller is made on the first use and disposed with the state,
///   and the watch is released on dispose.
mixin AnswerSurfaceMixin<T extends StatefulWidget> on State<T>, TapGuardState<T> {
  PreviewHandle? _handle;
  QuickReplyController? _reply;
  PromptInfo? _sentFor;
  PromptInfo? _shown;

  /// The machine and pane the answers go to, and the previews they are read
  /// from.
  MachineConnection get answerMachine;
  String get answerPaneId;
  PanePreviews get answerPreviews;

  /// Whether a new question while "Sent" shows resets the controller.
  bool get resetsOnNewQuestion => true;

  /// The question this surface shows from [preview]; the preview's own by
  /// default.
  PromptInfo? answerPromptIn(PanePreview? preview) => preview?.prompt;

  /// The shown question changed to [prompt] (null: none). Runs before the
  /// guard is armed again.
  void onShownChanged(PromptInfo? prompt) {}

  /// The current watch, null while none is held.
  PreviewHandle? get answerHandle => _handle;

  /// The question the answers are drawn for, null while none shows.
  PromptInfo? get shownPrompt => _shown;

  /// Sets the shown question without arming the guard (the surface just
  /// appeared, so the guard already is).
  set shownPrompt(PromptInfo? prompt) => _shown = prompt;

  QuickReplyController get answerController =>
      _reply ??= QuickReplyController(machine: answerMachine, paneId: answerPaneId, previews: answerPreviews);

  /// Takes the watch when none is held. [notify] runs the preview listener
  /// once right away.
  void watchAnswers({bool notify = false}) {
    if (_handle != null) return;
    _handle = answerPreviews.watch(answerMachine.profile.id, answerPaneId)..preview.addListener(_onAnswerPreview);
    if (notify) _onAnswerPreview();
  }

  /// Releases the watch; the surface shows no question after it.
  void releaseAnswers() {
    final handle = _handle;
    if (handle == null) return;
    handle.preview.removeListener(_onAnswerPreview);
    handle.release();
    _handle = null;
    _shown = null;
    onShownChanged(null);
  }

  /// Makes [shownPrompt] match the preview, arming the guard when it changed
  /// to a question. Never rebuilds: callers do.
  void syncShown() {
    final prompt = answerPromptIn(_handle?.preview.value);
    if (prompt == _shown) return;
    _shown = prompt;
    onShownChanged(prompt);
    if (prompt != null) rearmGuard();
  }

  void _onAnswerPreview() {
    syncShown();
    if (!resetsOnNewQuestion) return;
    final reply = _reply;
    if (reply == null || reply.phase != ReplyPhase.sent) return;
    if (_handle?.preview.value?.prompt != _sentFor) reply.reset();
  }

  /// Sends [reply] to [asked], the question the chips were drawn for (what is
  /// sent is checked against exactly it). The caller checks the guard first.
  Future<bool> chooseAnswer(PromptInfo asked, QuickReply reply) {
    _sentFor = asked;
    return answerController.choose(reply, asked: asked);
  }

  @override
  void dispose() {
    releaseAnswers();
    _reply?.dispose();
    super.dispose();
  }
}
