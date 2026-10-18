import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in a browser tab over the app (a Chrome Custom Tab: the phone's
/// own browser, with its sign-ins, passkeys and password manager, drawn inside
/// the app's task), so Back or the close button returns to where the person
/// was. Returns false when nothing could show it.
///
/// Why not a WebView of our own: Google refuses sign-in inside embedded
/// WebViews (`disallowed_useragent`), and Tailscale's login offers Google, so
/// the sign-in link this exists for would fail in one. Why not the browser app
/// (what this used to do): it opened as a separate task, and getting back to
/// the app meant finding it in recents. Without a Custom Tabs browser the
/// plugin falls back to its own bare WebView.
///
/// Only `https` links are opened. The links this is used for come from the text
/// a remote machine sends (a login banner), so anything else is refused here
/// as well as where the link is extracted.
Future<bool> openInBrowser(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
  return _launch(uri);
}

/// Opens a link the user tapped in terminal output: `http` and `https`.
///
/// Plain `http` is allowed here and nowhere else because this is only called
/// from an explicit tap, on a screen that shows the whole address first.
Future<bool> openTappedLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return false;
  if (uri.scheme != 'https' && uri.scheme != 'http') return false;
  return _launch(uri);
}

/// Opens a page the app itself serves on the phone's loopback address (see
/// `WebBridgeHost`) in the same browser tab as any link: `Open in browser`
/// on a page shown in the app (`WebPreviewScreen`), for what an embedded view
/// cannot do, such as a Google sign-in. The page works only while herdr
/// keeps its connection, which that screen holds while it is open.
///
/// Only `http` to `localhost` or `127.0.0.1` is accepted, the one shape those
/// URLs have: [openInBrowser] and [openTappedLink] stay as they were (a
/// `localhost` link from a machine's output must not reach this phone's own
/// services by being tapped), and what is opened here was built by the app.
Future<bool> openPreviewUrl(Uri url) async {
  if (url.scheme != 'http' || (url.host != 'localhost' && url.host != '127.0.0.1')) return false;
  return _launch(url);
}

Future<bool> _launch(Uri uri) async {
  try {
    return await launchUrl(
      uri,
      mode: LaunchMode.inAppBrowserView,
      browserConfiguration: const BrowserConfiguration(showTitle: true),
    );
  } on Object {
    return false;
  }
}
