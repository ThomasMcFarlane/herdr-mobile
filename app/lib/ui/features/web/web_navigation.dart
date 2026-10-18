import '../../../data/models/web_bridge.dart';

/// What the in-app page view does with a navigation it is asked about
/// (`WebPreviewScreen`).
enum WebNavigation {
  /// Shown here: one of the preview's own loopback listeners, or a blank page.
  load,

  /// A page of the web. Not loaded here and not opened by itself: the person
  /// is told and may open it in the phone's browser with a tap. A page's
  /// script can navigate (`location=`, `window.open`, a refresh) without
  /// anyone's tap, and opening the browser for it would let a page push herdr
  /// behind Chrome, the very failure the in-app view exists to avoid.
  web,

  /// Not opened anywhere: another port or name of the phone itself (in the
  /// browser it would reach the phone's own services, not the machine's),
  /// another scheme (`intent:`, `file:`, `mailto:`, `data:`), or a frame's
  /// way out.
  refuse,
}

/// Where [url] may be shown, for a page of a machine shown in the app.
///
/// The view loads only the listeners the bridge opened for that machine
/// ([ports]: `http` to `localhost`, the name the listener's cookie is set
/// for, on a port it holds), which carry the page over the SSH connection.
/// `127.0.0.1` reaches the same listener but carries no cookie there, so it
/// would only show "Not allowed".
///
/// What this cannot cover, because the Android plugin never asks: a form
/// POST, and anything a frame (`<iframe>`) loads. The frame rule below runs
/// on iOS only (WKWebView asks about every frame). See `docs/ARCHITECTURE.md`
/// "Network traffic".
WebNavigation webNavigation(Uri url, {required Set<int> ports, bool mainFrame = true}) {
  final scheme = url.scheme.toLowerCase();
  if (scheme == 'about' && (url.path == 'blank' || url.path == 'srcdoc')) return WebNavigation.load;
  // A `data:` page in the top frame has no address of its own to show; in a
  // frame (iOS only) it is part of the page.
  if (scheme == 'data') return mainFrame ? WebNavigation.refuse : WebNavigation.load;
  if (scheme == 'http' && url.host.toLowerCase() == 'localhost' && ports.contains(url.port)) {
    return WebNavigation.load;
  }
  if (!mainFrame) return WebNavigation.refuse;
  if ((scheme == 'http' || scheme == 'https') && url.host.isNotEmpty && !isMachineLocalUrl(url.toString())) {
    return WebNavigation.web;
  }
  return WebNavigation.refuse;
}
