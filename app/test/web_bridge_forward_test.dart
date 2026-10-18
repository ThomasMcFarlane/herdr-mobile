import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSocket;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/web_bridge.dart';

import 'support/fake_fs.dart';
import 'support/raw_http.dart';

/// A server on the "machine" that sends back every byte it gets and keeps them.
class _Echo {
  late ServerSocket server;
  final received = BytesBuilder(copy: false);

  Future<void> start() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) => s.listen((d) {
          received.add(d);
          s.add(d);
        }, onError: (Object _) {}));
    addTearDown(server.close);
  }

  int get port => server.port;
}

class _Rig {
  _Rig(this.host, this.dials);

  final WebBridgeHost host;

  /// `host:port` of every dial, in order.
  final List<String> dials;
}

_Rig _rig({
  required int Function() targetPort,
  Duration idle = const Duration(minutes: 10),
  Object? Function(int call)? failDial,

  /// Dials after the first (the probe made when the listener opens) wait for this.
  Future<void>? dialWait,
}) {
  final dials = <String>[];
  final fs = FakeFs();
  final host = WebBridgeHost(
    stat: fs.stat,
    read: fs.read,
    idle: idle,
    dial: (h, p) async {
      dials.add('$h:$p');
      final fail = failDial?.call(dials.length);
      if (fail != null) throw fail;
      if (dials.length > 1) await dialWait;
      return SSHSocket.connect('127.0.0.1', targetPort());
    },
  );
  addTearDown(host.close);
  return _Rig(host, dials);
}

Future<String> _signIn(WebBridgeInfo info) async => cookieFrom(
      await rawRequest(info.port, target: '/__herdr/open?t=${info.token}&to=%2F'),
    );

/// A browser connection to the listener that keeps what comes back.
class _Conn {
  _Conn(this.socket) {
    socket.listen(
      (d) {
        got.add(d);
        _check();
      },
      onDone: () {
        closed = true;
        _check();
      },
      onError: (Object _) => closed = true,
    );
  }

  final Socket socket;
  final got = BytesBuilder(copy: false);
  var closed = false;
  final _waiters = <(int, Completer<void>)>[];

  static Future<_Conn> open(int port) async =>
      _Conn(await Socket.connect(InternetAddress.loopbackIPv4, port));

  void _check() {
    for (final w in _waiters.toList()) {
      if (got.length >= w.$1 || closed) {
        _waiters.remove(w);
        w.$2.complete();
      }
    }
  }

  /// Waits until [n] bytes arrived in all (or the connection closed).
  Future<Uint8List> waitFor(int n) async {
    if (got.length < n && !closed) {
      final c = Completer<void>();
      _waiters.add((n, c));
      await c.future.timeout(const Duration(seconds: 5));
    }
    return got.toBytes();
  }
}

String _head(int port, String cookie, {String path = '/x', Map<String, String> extra = const {}}) =>
    'GET $path HTTP/1.1\r\nHost: localhost:$port\r\nCookie: $cookie\r\n'
    '${[for (final e in extra.entries) '${e.key}: ${e.value}\r\n'].join()}\r\n';

/// What the machine receives of [head]: the listener's own cookie stays here.
String _arrives(String head, String cookie) => head.replaceFirst('Cookie: $cookie\r\n', '');

void main() {
  const spec = PortForward('localhost', 3000, machineName: 'build-box');

  group('the gate: nothing reaches the machine without the token', () {
    test('no cookie, the entry URL and a foreign Host are answered here and never dial', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('127.0.0.1', echo.port, machineName: 'build-box'));
      rig.dials.clear();

      final bare = await rawRequest(info.port, target: '/api');
      expect(bare.status, 403);

      final entry = await rawRequest(info.port, target: '/__herdr/open?t=${info.token}&to=%2Fapp%3Fa%3D1');
      expect(entry.status, 302);
      expect(entry.headers['location'], '/app?a=1');
      expect(entry.headers['set-cookie'], contains('herdr_${info.port}=${info.token}'));
      expect((await rawRequest(info.port, target: '/__herdr/open?t=bad&to=%2F')).status, 403);
      expect((await rawRequest(info.port, target: '/__herdr/open?t=${info.token}&to=%2F%2Fevil.example')).headers['location'], '/');

      final cookie = cookieFrom(entry);
      final rebound = await rawRequest(
        info.port,
        target: '/api',
        host: 'evil.example:${info.port}',
        headers: {'Cookie': cookie},
      );
      expect(rebound.status, 403);
      expect(rig.dials, isEmpty);
      expect(echo.received.length, 0);
    });

    test('a page of another open listener may call without a cookie, a page from anywhere else may not', () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      http.listen((r) {
        r.response.write('ok');
        r.response.close();
      });
      final rig = _rig(targetPort: () => http.port);
      final api = await rig.host.open(PortForward('127.0.0.1', http.port, machineName: 'build-box'));
      final front = await rig.host.open(const StaticSite('/site', machineName: 'build-box'));
      rig.dials.clear();

      Future<RawReply> call(Map<String, String> headers) =>
          rawRequest(api.port, target: '/api', headers: headers, timeout: const Duration(seconds: 1));

      final sibling = await call({'Sec-Fetch-Site': 'same-site', 'Origin': 'http://localhost:${front.port}'});
      expect(sibling.status, 200);
      expect(sibling.text, contains('ok'));
      expect(rig.dials, hasLength(1));
      rig.dials.clear();

      expect((await call({'Sec-Fetch-Site': 'cross-site', 'Origin': 'http://localhost:${front.port}'})).status, 403);
      expect((await call({'Sec-Fetch-Site': 'same-site', 'Origin': 'http://localhost:1'})).status, 403);
      expect((await call({'Sec-Fetch-Site': 'same-site', 'Origin': 'http://127.0.0.1:${front.port}'})).status, 403);
      expect((await call({'Origin': 'http://localhost:${front.port}'})).status, 403);
      expect(rig.dials, isEmpty);
    });

    test('a page of the listener itself is no sibling: a same-origin request carries the cookie anyway', () async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => http.close(force: true));
      var served = 0;
      http.listen((r) {
        served++;
        r.response.write('ok');
        r.response.close();
      });
      final rig = _rig(targetPort: () => http.port);
      final api = await rig.host.open(PortForward('127.0.0.1', http.port, machineName: 'build-box'));
      final front = await rig.host.open(const StaticSite('/site', machineName: 'build-box'));
      rig.dials.clear();
      Future<RawReply> call(int origin) => rawRequest(
            api.port,
            target: '/api',
            headers: {'Sec-Fetch-Site': 'same-site', 'Origin': 'http://localhost:$origin'},
            timeout: const Duration(seconds: 1),
          );
      expect((await call(api.port)).status, 403);
      expect(rig.dials, isEmpty);
      expect(served, 0);
      // Another listener's page still gets through.
      expect((await call(front.port)).status, 200);
      expect(rig.dials, hasLength(1));
    });

    test('an invalid escape in the token, the destination or the path never takes the listener down', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('127.0.0.1', echo.port, machineName: 'build-box'));
      final cookie = await _signIn(info);
      rig.dials.clear();

      for (final t in ['%ff', '%', '%zz', '%c0%af']) {
        final r = await rawRequest(info.port, target: '/__herdr/open?t=$t&to=%2F');
        expect(r.status, 403, reason: t);
        expect(r.timedOut, isFalse, reason: t);
      }
      for (final to in ['%ff', '%', '%zz']) {
        final r = await rawRequest(info.port, target: '/__herdr/open?t=${info.token}&to=$to');
        expect(r.status, 302, reason: to);
        expect(r.headers['location'], '/', reason: to);
      }
      expect((await rawRequest(info.port, target: '/%ff/x')).status, 403, reason: 'no cookie');
      expect(rig.dials, isEmpty, reason: 'none of these is let through');

      // With the cookie the path is the machine's business, byte for byte.
      final conn = await _Conn.open(info.port);
      final head = _head(info.port, cookie, path: '/%ff/x');
      conn.socket.add(latin1.encode(head));
      final arrived = _arrives(head, cookie);
      expect(latin1.decode(await conn.waitFor(arrived.length)), arrived);
      await conn.socket.close();

      // And the listener answers a good request afterwards.
      expect((await rawRequest(info.port, target: '/__herdr/open?t=${info.token}&to=%2Fok')).headers['location'], '/ok');
    });
  });

  group('after the gate it is the machine\'s bytes, unchanged', () {
    test('a request, a second one on the same connection and upgrade bytes reach the machine exactly', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('localhost', echo.port, machineName: 'build-box'));
      final cookie = await _signIn(info);
      final conn = await _Conn.open(info.port);

      final first = _arrives(_head(info.port, cookie, extra: {'X-A': 'one'}), cookie);
      conn.socket.add(latin1.encode(_head(info.port, cookie, extra: {'X-A': 'one'})));
      expect(latin1.decode(await conn.waitFor(first.length)), first);

      // Keep-alive: the same connection, no new dial.
      final dials = rig.dials.length;
      // Later requests on the connection are the machine's bytes as they are:
      // only the first head is looked at.
      final second = _head(info.port, cookie, path: '/second');
      conn.socket.add(latin1.encode(second));
      // A WebSocket frame after an upgrade is not text at all.
      final frame = Uint8List.fromList(List.generate(300, (i) => i % 256));
      conn.socket.add(frame);
      final all = await conn.waitFor(first.length + second.length + frame.length);
      expect(all.sublist(first.length), [...latin1.encode(second), ...frame]);
      expect(rig.dials.length, dials);
      expect(echo.received.length, all.length);

      await conn.socket.close();
    });

    test('the listener cookies stay here, every other cookie and byte goes through as it was', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('127.0.0.1', echo.port, machineName: 'build-box'));
      final p = info.port;
      final token = info.token;
      // The browser holds the token of every listener it was sent to, this one
      // and another machine's on a colliding port number.
      String sent(String cookies) =>
          'POST /x HTTP/1.1\r\nHost: localhost:$p\r\nX-Before: 1\r\n$cookies'
          'X-After: 2\r\nContent-Length: 5\r\n\r\nhello';
      final request = sent(
        'cookie: herdr_9=zzz\r\n'
        'Cookie: theme=dark; herdr_$p=$token; sid=a=b;c; herdr_41234=other\r\n',
      );
      final expected = sent('Cookie: theme=dark; sid=a=b;c\r\n');
      final conn = await _Conn.open(p);
      conn.socket.add(latin1.encode(request));
      expect(latin1.decode(await conn.waitFor(expected.length)), expected);
      await conn.socket.close();
      expect(latin1.decode(echo.received.toBytes()), expected);
    });

    test('a Cookie header with only listener cookies is dropped, and a request without one is untouched', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port);
      final info = await rig.host.open(PortForward('127.0.0.1', echo.port, machineName: 'build-box'));
      final front = await rig.host.open(const StaticSite('/site', machineName: 'build-box'));
      final cookie = await _signIn(info);

      final only = _head(info.port, cookie, extra: {'X-A': 'one'});
      var conn = await _Conn.open(info.port);
      conn.socket.add(latin1.encode(only));
      final withoutCookie = 'GET /x HTTP/1.1\r\nHost: localhost:${info.port}\r\nX-A: one\r\n\r\n';
      expect(latin1.decode(await conn.waitFor(withoutCookie.length)), withoutCookie);
      await conn.socket.close();

      // No Cookie at all (a page of the other listener, let through by origin).
      final bare = 'GET /y HTTP/1.1\r\nHost: localhost:${info.port}\r\n'
          'Sec-Fetch-Site: same-site\r\nOrigin: http://localhost:${front.port}\r\n\r\n';
      conn = await _Conn.open(info.port);
      conn.socket.add(latin1.encode(bare));
      expect(latin1.decode(await conn.waitFor(bare.length)), bare);
      await conn.socket.close();
    });

    test('a server that closes ends the browser connection, and the browser closing ends it for the server', () async {
      final target = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(target.close);
      // The probe made when the listener opens is the first connection; the browser's is the second.
      final connections = <Completer<void>>[];
      target.listen((s) {
        final closed = Completer<void>();
        connections.add(closed);
        s.listen((_) => s.add(utf8.encode('bye')), onDone: closed.complete);
      });
      final rig = _rig(targetPort: () => target.port);
      final info = await rig.host.open(PortForward('127.0.0.1', target.port, machineName: 'build-box'));
      final cookie = await _signIn(info);
      final conn = await _Conn.open(info.port);
      conn.socket.add(latin1.encode(_head(info.port, cookie)));
      expect(utf8.decode(await conn.waitFor(3)), 'bye');
      await conn.socket.close();
      expect(connections, hasLength(2));
      await connections.last.future.timeout(const Duration(seconds: 5));
    });
  });

  group('when the machine cannot be reached', () {
    test('the browser gets a page that names the port and the machine', () async {
      final rig = _rig(
        targetPort: () => 1,
        // The probe made when the listener opens is let through; the page's request is the one that fails.
        failDial: (call) => call == 1 ? null : const HerdrTransportException('connect failed'),
      );
      final info = await rig.host.open(const PortForward('localhost', 3000, machineName: 'build-box'));
      final cookie = await _signIn(info);
      final r = await rawRequest(info.port, target: '/', headers: {'Cookie': cookie});
      expect(r.status, 502);
      expect(r.text, allOf(contains('localhost:3000'), contains('build-box'), contains('Reload')));
    });

    test('a host that forbids forwarding is said so when the link is opened, not in a page', () async {
      final rig = _rig(
        targetPort: () => 1,
        failDial: (_) => const HerdrTransportException('the machine does not allow port forwarding', fatal: true),
      );
      await expectLater(
        rig.host.open(spec),
        throwsA(isA<HerdrTransportException>().having((e) => e.message, 'message', contains('does not allow port forwarding'))),
      );
      expect(rig.host.livePorts, isEmpty);
    });

    test('a target that is not up yet still opens: the page explains, and a later start works', () async {
      final rig = _rig(targetPort: () => 1, failDial: (call) => call == 1 ? const HerdrTransportException('refused') : null);
      final info = await rig.host.open(spec);
      expect(info.port, greaterThan(0));
    });
  });

  group('the local port', () {
    test('a page written for localhost:N gets the same port number when it is free', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final free = probe.port;
      await probe.close();
      final rig = _rig(targetPort: () => 1);
      final info = await rig.host.open(PortForward('localhost', free, machineName: 'm'));
      expect(info.port, free);
    });

    test('a taken port number falls back to another one instead of failing', () async {
      final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(taken.close);
      final rig = _rig(targetPort: () => 1);
      final info = await rig.host.open(PortForward('localhost', taken.port, machineName: 'm'));
      expect(info.port, isNot(taken.port));
      expect(info.port, greaterThan(0));
    });

    test('the same spec is one port and one token; another port is another listener', () async {
      final rig = _rig(targetPort: () => 1);
      final a = await rig.host.open(spec);
      expect(await rig.host.open(spec), a);
      final b = await rig.host.open(const PortForward('localhost', 3001, machineName: 'build-box'));
      expect(b.port, isNot(a.port));
      expect(b.token, isNot(a.token));
      expect(a.token, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('an idle listener closes, and a relaunch gets the same port and token', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port, idle: const Duration(milliseconds: 150));
      final info = await rig.host.open(const PortForward('localhost', 4999, machineName: 'm'));
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, info.port), throwsA(isA<SocketException>()));
      expect(rig.host.livePorts, isEmpty);
      final back = await rig.host.open(const PortForward('localhost', 4999, machineName: 'm'));
      expect(back, info);
    });

    test('a browser that leaves while the machine is still being dialed does not hold the listener up', () async {
      final echo = _Echo();
      await echo.start();
      final never = Completer<void>(); // a dial on a bad link: it takes its 15 s
      final rig = _rig(targetPort: () => echo.port, idle: const Duration(milliseconds: 150), dialWait: never.future);
      final info = await rig.host.open(PortForward('localhost', echo.port, machineName: 'm'));
      final cookie = await _signIn(info);
      final conn = await _Conn.open(info.port);
      conn.socket.add(latin1.encode(_head(info.port, cookie)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rig.dials, hasLength(2), reason: 'the probe, and the one the browser asked for');
      await conn.socket.close();
      conn.socket.destroy();

      await Future<void>.delayed(const Duration(milliseconds: 700));
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, info.port), throwsA(isA<SocketException>()));
      never.complete();
    });

    test('an open connection keeps the listener up past the idle time', () async {
      final echo = _Echo();
      await echo.start();
      final rig = _rig(targetPort: () => echo.port, idle: const Duration(milliseconds: 150));
      final info = await rig.host.open(PortForward('localhost', echo.port, machineName: 'm'));
      final cookie = await _signIn(info);
      final conn = await _Conn.open(info.port);
      final head = _head(info.port, cookie);
      conn.socket.add(latin1.encode(head));
      final arrived = _arrives(head, cookie).length;
      await conn.waitFor(arrived);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      conn.socket.add(latin1.encode('later'));
      expect(latin1.decode((await conn.waitFor(arrived + 5)).sublist(arrived)), 'later');
      await conn.socket.close();
    });
  });
}
