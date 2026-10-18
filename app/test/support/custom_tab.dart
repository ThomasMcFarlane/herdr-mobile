import 'raw_http.dart';

/// What a page of the phone's browser ended on, and the requests on the way.
class TabVisit {
  TabVisit(this.page, this.steps);

  final RawReply page;

  /// `<port><path>` of every request, in order.
  final List<String> steps;
}

/// Opens [entry] the way a Chrome Custom Tab does, for the cookie rules that
/// decide whether a listener lets the browser in. Modelled on Chromium's own
/// code, because only a phone runs the real thing:
///
/// - A Custom Tab navigates from an opaque origin: "The sender of an intent
///   can't be trusted, so we navigate from an opaque Origin to avoid sending
///   same-site cookies" (`CustomTabActivityNavigationController.navigate`).
/// - A main-frame navigation's response may set any cookie, `SameSite=Strict`
///   included (`ComputeSameSiteContextForResponse`, `net/cookies/cookie_util.cc`).
/// - A request is strictly same-site only when its initiator is same-site with
///   it (`ComputeSameSiteContext`). A redirect keeps the navigation's
///   initiator, so the opaque one follows a 302: no `SameSite=Strict` cookie.
///   `Lax` and unset cookies still go with a top-level GET.
/// - A `Refresh` header (or `<meta http-equiv=refresh>`) is a navigation the
///   document starts itself, from its own origin
///   (`HttpRefreshScheduler::NavigateTask`): from `localhost:<a>` to
///   `localhost:<b>` it is same-site (a site has no port).
///
/// Cookies are host-only on `localhost` and ignore ports, as browsers keep
/// them. Follows at most [hops] answers.
Future<TabVisit> openInCustomTab(Uri entry, {int hops = 5}) async {
  final jar = <String, ({String value, bool strict})>{};
  final steps = <String>[];
  var url = entry;
  // The Custom Tab's own navigation: an opaque initiator.
  var sameSiteInitiator = false;
  for (var i = 0;; i++) {
    final cookies = [
      for (final c in jar.entries)
        if (!c.value.strict || sameSiteInitiator) '${c.key}=${c.value.value}',
    ];
    final target = url.hasQuery ? '${url.path}?${url.query}' : url.path;
    steps.add('${url.port}$target');
    final reply = await rawRequest(
      url.port,
      target: target.isEmpty ? '/' : target,
      host: '${url.host}:${url.port}',
      headers: {if (cookies.isNotEmpty) 'Cookie': cookies.join('; ')},
    );
    final set = reply.headers['set-cookie'];
    if (set != null) {
      final parts = set.split(';').map((p) => p.trim()).toList();
      final eq = parts.first.indexOf('=');
      jar[parts.first.substring(0, eq)] = (
        value: parts.first.substring(eq + 1),
        strict: parts.skip(1).any((p) => p.toLowerCase() == 'samesite=strict'),
      );
    }
    final location = reply.headers['location'];
    final refresh = sendsTo(reply);
    if (i == hops || (location == null && refresh == null)) return TabVisit(reply, steps);
    if (location != null && reply.status >= 300 && reply.status < 400) {
      // A redirect: the same navigation, the same (opaque) initiator.
      url = url.resolve(location);
    } else if (refresh != null) {
      final next = url.resolve(refresh);
      // The page's own navigation: same-site when scheme and host match.
      sameSiteInitiator = next.scheme == url.scheme && next.host == url.host;
      url = next;
    } else {
      return TabVisit(reply, steps);
    }
  }
}
