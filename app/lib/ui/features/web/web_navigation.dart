import '../../../data/models/web_bridge.dart';

/// What the in-app page view does with a navigation (`WebPreviewScreen`).
enum WebNavigation {
  /// Shown here: one of the preview's own loopback listeners, or a blank or
  /// `data:` page.
  load,

  /// Handed to the phone's browser (a Custom Tab): a link to the web.
  browser,

  /// Not opened anywhere: another port or name on the phone, another scheme
  /// (`intent:`, `file:`, `mailto:`), or a frame's way out.
  refuse,
}

/// Where [url] may be shown, for a page of a machine shown in the app.
///
/// The view loads only the listeners the bridge opened for that machine
/// ([ports]: `http` to `localhost` or `127.0.0.1`, the names a listener
/// answers to, on a port it holds), which carry the page over the SSH
/// connection and check its cookie. Anything else would be a page from the
/// internet running inside herdr's process, or, on another loopback port,
/// whatever app of the phone listens there; neither belongs in the view.
///
/// A link to the web ([mainFrame], `http` or `https` to a host that is not
/// the phone itself) goes to the phone's browser instead, where the person's
/// sign-ins live. A loopback address that is not a listener is not handed to
/// the browser: there it would reach the phone's own services, not the
/// machine's (see `openTappedLink`). A frame never opens the browser.
WebNavigation webNavigation(Uri url, {required Set<int> ports, bool mainFrame = true}) {
  final scheme = url.scheme.toLowerCase();
  if (scheme == 'about' && (url.path == 'blank' || url.path == 'srcdoc')) return WebNavigation.load;
  if (scheme == 'data') return WebNavigation.load;
  final host = url.host.toLowerCase();
  if (scheme == 'http' && (host == 'localhost' || host == '127.0.0.1') && ports.contains(url.port)) {
    return WebNavigation.load;
  }
  if (!mainFrame) return WebNavigation.refuse;
  if ((scheme == 'http' || scheme == 'https') && host.isNotEmpty && !isMachineLocalUrl(url.toString())) {
    return WebNavigation.browser;
  }
  return WebNavigation.refuse;
}
