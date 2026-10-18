/// What a loopback listener on the phone serves to a browser on the phone
/// (herdr's own page view, or the phone's browser).
///
/// [machineName] is only for the pages the listener shows when something goes
/// ("Couldn't reach MACHINE"): a page in the phone's browser has no app
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
  /// [entryPort] defaults to [port]: a static site answers its own entry URL.
  const WebBridgeInfo({required this.port, required this.token, int? entryPort})
      : entryPort = entryPort ?? port;

  /// The loopback port on the phone.
  final int port;

  /// 32 hex characters, only ever sent to the phone's browser in the entry
  /// URL (`/__herdr/open?t=`), which answers with a cookie.
  final String token;

  /// The loopback port that answers the entry URL. For a forwarded dev server
  /// it is a different port from [port]: the browser keeps connections to
  /// [port] open and reuses them, and what goes down such a connection is
  /// the dev server's, so the entry URL (which holds the token) must never be
  /// sent there.
  final int entryPort;

  @override
  bool operator ==(Object other) =>
      other is WebBridgeInfo &&
      other.port == port &&
      other.token == token &&
      other.entryPort == entryPort;

  @override
  int get hashCode => Object.hash(port, token, entryPort);
}

/// Whether [url] points at the machine the output came from rather than at
/// somewhere the phone can reach: `localhost`, a loopback or unspecified
/// address in any spelling a browser accepts ([isLoopbackAddress]), or a
/// `.local` name. Opening it on the phone would reach the phone (or nothing).
bool isMachineLocalUrl(String url) {
  final raw = Uri.tryParse(url)?.host;
  if (raw == null) return false;
  final host = normalHost(raw);
  if (host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.localhost')) return true;
  if (host.endsWith('.local')) return true;
  return isLoopbackAddress(host);
}

/// [host] as a browser compares names: lower case, without the trailing dot
/// a DNS name may end in (`localhost.` is `localhost` to the resolver).
String normalHost(String host) {
  var h = host.toLowerCase();
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  return h;
}

/// Whether [host] is an address of the phone itself, in any spelling a
/// browser accepts: loopback (`127/8`, `::1`, `::ffff:127.x.x.x`) or
/// unspecified (`0.0.0.0`, `::`). IPv4 is read the way a browser reads it
/// (WHATWG URL): one to four parts, each decimal, `0x` hex or `0`-led
/// octal, the last part filling the bytes left, so `2130706433`, `0x7f.1`
/// and `0177.0.0.1` are all 127.0.0.1. Why: a page shown in herdr that sends
/// the view to `http://0x7f.1:5432` must not be treated as the web and
/// offered to the phone's browser, where it would reach the phone's own
/// services.
bool isLoopbackAddress(String host) {
  var h = normalHost(host);
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h.contains(':')) {
    final List<int> b;
    try {
      b = Uri.parseIPv6Address(h);
    } on FormatException {
      return false;
    }
    for (var i = 0; i < 10; i++) {
      if (b[i] != 0) return false;
    }
    if (b[10] == 0 && b[11] == 0) {
      // `::` or `::1`.
      return b[12] == 0 && b[13] == 0 && b[14] == 0 && b[15] <= 1;
    }
    if (b[10] == 0xff && b[11] == 0xff) return b[12] == 127 || b[12] == 0; // IPv4-mapped
    return false;
  }
  final v4 = _ipv4(h);
  return v4 != null && (v4 >> 24 == 127 || v4 >> 24 == 0);
}

int? _ipv4(String host) {
  final parts = host.split('.');
  if (parts.length > 4) return null;
  final numbers = <int>[];
  for (final p in parts) {
    final n = _ipv4Part(p);
    if (n == null) return null;
    numbers.add(n);
  }
  final last = numbers.removeLast();
  if (numbers.any((n) => n > 255) || last >= 1 << (8 * (4 - numbers.length))) return null;
  var value = last;
  for (var i = 0; i < numbers.length; i++) {
    value += numbers[i] << (8 * (3 - i));
  }
  return value;
}

int? _ipv4Part(String part) {
  var digits = part;
  var radix = 10;
  if (digits.length > 1 && (digits.startsWith('0x') || digits.startsWith('0X'))) {
    radix = 16;
    digits = digits.substring(2);
    if (digits.isEmpty) return 0;
  } else if (digits.length > 1 && digits.startsWith('0')) {
    radix = 8;
    digits = digits.substring(1);
  }
  final valid = switch (radix) {
    16 => RegExp(r'^[0-9a-fA-F]{1,8}$'),
    8 => RegExp(r'^[0-7]{1,11}$'),
    _ => RegExp(r'^[0-9]{1,10}$'),
  };
  return valid.hasMatch(digits) ? int.parse(digits, radix: radix) : null;
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
