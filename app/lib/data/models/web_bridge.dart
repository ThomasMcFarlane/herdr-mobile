/// What a loopback listener on the phone serves to the phone's own browser.
///
/// [machineName] is only for the pages the listener shows when something goes
/// ("Couldn't reach MACHINE"): a page in a browser tab has no app
/// around it to say which machine it was about.
sealed class WebBridgeSpec {
  const WebBridgeSpec({required this.machineName});

  final String machineName;

  /// Same key, same listener: opening a spec twice gives one port and one
  /// token, so a reloaded tab keeps working.
  String get key;
}

/// A folder on the machine, served read-only over SFTP. Its root is the folder
/// of the file that was opened, so the page's own relative links work and
/// nothing above it is ever asked for.
final class StaticSite extends WebBridgeSpec {
  const StaticSite(this.root, {required super.machineName});

  /// Absolute path of the served folder, without a trailing slash (`/` stays).
  final String root;

  @override
  String get key => 's|$root';
}

/// A TCP port on (or reachable from) the machine, carried over the SSH
/// connection. The page keeps talking to `localhost:<port>` as it was written
/// to, so the local listener takes the same port number when it is free.
final class PortForward extends WebBridgeSpec {
  const PortForward(this.host, this.port, {required super.machineName});

  /// Where the machine dials: `localhost`, `127.0.0.1`, another interface.
  final String host;
  final int port;

  @override
  String get key => 'f|$host|$port';
}

/// Where a listener answers and the secret that opens it.
class WebBridgeInfo {
  const WebBridgeInfo({required this.port, required this.token});

  /// The loopback port on the phone.
  final int port;

  /// 32 hex characters, only ever sent to the phone's browser in the entry
  /// URL (`/__herdr/open?t=`), which answers with a cookie.
  final String token;

  @override
  bool operator ==(Object other) =>
      other is WebBridgeInfo && other.port == port && other.token == token;

  @override
  int get hashCode => Object.hash(port, token);
}

/// Whether [url] points at the machine the output came from rather than at
/// somewhere the phone can reach: `localhost`, a loopback or unspecified
/// address, or a `.local` name. Opening it on the phone would reach the phone
/// (or nothing).
bool isMachineLocalUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  if (host == null || host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.localhost')) return true;
  if (host == '::1' || host == '::' || host == '0.0.0.0') return true;
  if (host.endsWith('.local')) return true;
  return RegExp(r'^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$').hasMatch(host);
}

/// The names a loopback link may carry to be opened on the phone: the machine
/// itself, spelled one of the ways a dev server prints it. Not other `127.x`
/// addresses, `*.localhost` or `*.local` names: the machine would resolve
/// those, so the address shown and the host dialed could differ, and a `.local`
/// name reaches other devices on the machine's network.
bool isPreviewHost(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '0.0.0.0' || h == '::';
}

/// What listens on [port] by convention when it is not a web server (a
/// database, a remote shell, a container API), or null. A page the person is
/// shown for such a port is a surprise worth one deliberate gesture.
String? sensitiveServiceOf(int port) => switch (port) {
  22 => 'SSH',
  2375 || 2376 => 'Docker API',
  3306 => 'MySQL',
  5432 => 'PostgreSQL',
  6379 => 'Redis',
  9200 => 'Elasticsearch',
  11211 => 'Memcached',
  27017 => 'MongoDB',
  _ => null,
};

/// Whether [name] (a file name or path) is a page the phone's browser shows:
/// HTML, and SVG (which the file viewer cannot draw).
bool isWebPageName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return const {'html', 'htm', 'xhtml', 'svg'}.contains(name.substring(dot + 1).toLowerCase());
}
