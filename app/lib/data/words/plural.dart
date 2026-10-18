/// `1 agent`, `3 agents`, `0 agents`: a count and its noun, never `1 agents`.
/// [many] defaults to [one] plus `s`; pass it for an irregular plural
/// (`countOf(n, 'match', 'matches')`).
String countOf(int n, String one, [String? many]) => '$n ${plural(n, one, many)}';

/// The noun alone, agreeing with [n].
String plural(int n, String one, [String? many]) => n == 1 ? one : (many ?? '${one}s');

/// `1 needs you`, `3 need you`: the one phrase for agents waiting on the person.
/// With [noun] the count names its subject (`10 agents need you`), for text
/// read away from the board, such as a notification title.
String needYou(int n, {String? noun}) =>
    '${noun == null ? '$n' : countOf(n, noun)} ${needYouVerb(n)}';

/// `needs you` or `need you`, agreeing with [n]: the phrase without its count,
/// for a label that sits beside the number.
String needYouVerb(int n) => n == 1 ? 'needs you' : 'need you';
