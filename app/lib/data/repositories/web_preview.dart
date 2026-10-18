import '../models/remote_file.dart';
import '../models/web_bridge.dart';
import '../services/herdr_transport.dart';

/// Why a page could not be opened on the phone, in words for the person:
/// `Couldn't open on this phone: <reason>.`
class WebPreviewException implements Exception {
  const WebPreviewException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Gives the phone's own browser a URL for something an agent made on a
/// machine: an HTML file from its folder (read over SFTP), or a dev server
/// link on the machine (carried over SSH). The URL is a loopback address the
/// app listens on; see `WebBridgeHost`.
class WebPreview {
  WebPreview(this._transport, {required this.machineName});

  final HerdrTransport _transport;

  /// Only for the pages the listener shows when something goes wrong.
  final String machineName;

  /// Whether a link can be opened on the phone through [forwardUrl]: plain
  /// `http` to the machine itself, spelled `localhost`, `127.0.0.1`, `[::1]`,
  /// `0.0.0.0` or `[::]`, with a port that exists. Not any other `127.x`
  /// address, `*.localhost` or `*.local`: a forward dials the host from the
  /// machine, so a `.local` name reaches other devices on its network and a
  /// row could read `localhost` while the machine dials `127.0.0.5`. An
  /// `https` address on the machine needs its certificate to name
  /// `localhost`, which a development one never does, so it stays copy-only.
  static bool canPreview(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && _isPreviewLink(uri) && _portExists(uri);
  }

  static bool _isPreviewLink(Uri uri) => uri.scheme == 'http' && isPreviewHost(uri.host);

  static bool _portExists(Uri uri) => !uri.hasPort || (uri.port >= 1 && uri.port <= 65535);

  /// The URL that shows [file] in the browser: the listener serves the file's
  /// own folder (so the page's relative links work and nothing above that
  /// folder is ever asked for) and the URL opens [file] in it. Keeps
  /// [fragment] (`#section`) for the browser.
  Future<Uri> staticUrl(RemoteStat file, {String? fragment}) async {
    if (!_transport.supportsFiles) {
      throw const WebPreviewException('Files are not available on this machine.');
    }
    if (!RemotePath.isAbsolute(file.path)) {
      throw const WebPreviewException("Couldn't open on this phone: the file's location is not known.");
    }
    final info = await _open(StaticSite(RemotePath.parent(file.path), machineName: machineName));
    return _entry(info, '/${Uri.encodeComponent(file.name)}', fragment);
  }

  /// The URL that shows [link] (an address on the machine) in the browser.
  /// The page keeps talking to `localhost:<port>` as it was written to, so the
  /// listener takes the same port number whenever it is free. When it could
  /// not (another listener or app holds that number), [onNote] gets one
  /// sentence saying so: a page that hardcodes `localhost:<port>` then calls
  /// whatever holds the number, which may be another machine's listener.
  Future<Uri> forwardUrl(Uri link, {void Function(String note)? onNote}) async {
    if (_isPreviewLink(link) && !_portExists(link)) {
      throw WebPreviewException(_sentence('That port number is not valid.'));
    }
    if (!_isPreviewLink(link)) {
      throw const WebPreviewException("Couldn't open on this phone: only http addresses on the machine can be opened.");
    }
    // Every spelling of the machine itself is one listener: the machine resolves
    // `localhost` to whichever of 127.0.0.1 and ::1 the server is on.
    const host = 'localhost';
    final target = link.hasPort ? link.port : 80;
    final info = await _open(PortForward(host, target, machineName: machineName));
    if (info.port != target) {
      onNote?.call('Opened on port ${info.port}: a page that expects localhost:$target may not work.');
    }
    final path = link.path.isEmpty ? '/' : link.path;
    return _entry(info, link.hasQuery ? '$path?${link.query}' : path, link.hasFragment ? _decoded(link.fragment) : null);
  }

  Future<WebBridgeInfo> _open(WebBridgeSpec spec) async {
    try {
      return await _transport.openWebBridge(spec);
    } on HerdrTransportException catch (e) {
      throw WebPreviewException(_sentence(e.message));
    } on RemoteFileException catch (e) {
      throw WebPreviewException(_sentence(e.message));
    }
  }

  /// A [Uri] holds its fragment encoded and encodes it again when it is built
  /// from a string.
  static String _decoded(String encoded) {
    try {
      return Uri.decodeComponent(encoded);
    } on FormatException {
      return encoded;
    }
  }

  /// `Couldn't open on this phone: <reason>.`, the reason without its own full
  /// stop and, when it starts with a word and not a name, in lower case.
  static String _sentence(String reason) {
    var r = reason.trim();
    if (r.endsWith('.')) r = r.substring(0, r.length - 1);
    if (r.length > 1 && r[0] == r[0].toUpperCase() && r[1] == r[1].toLowerCase() && r[1] != ' ') {
      r = r[0].toLowerCase() + r.substring(1);
    }
    return "Couldn't open on this phone: $r.";
  }

  /// `http://localhost:<port>/__herdr/open?t=<token>&to=<where>`: the one URL
  /// that carries the token. The listener answers it with a cookie and sends
  /// the browser on to [to].
  static Uri _entry(WebBridgeInfo info, String to, String? fragment) => Uri(
        scheme: 'http',
        host: 'localhost',
        port: info.port,
        path: '/__herdr/open',
        queryParameters: {'t': info.token, 'to': to},
        fragment: fragment == null || fragment.isEmpty ? null : fragment,
      );
}
