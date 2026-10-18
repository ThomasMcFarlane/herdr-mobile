import '../../../data/words/elapsed.dart';

/// The link strip's note over a saved copy, in every state but live:
/// `Showing the copy saved today at 14:02. Nothing here can be answered.` A copy is
/// never live and answers nothing (requests come only with a live attach).
String savedCopyNotice(DateTime asOf, DateTime now) =>
    'Showing the copy saved ${formatWhen(asOf, now, sentence: true)}. Nothing here can be answered.';
