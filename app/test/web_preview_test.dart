import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/repositories/web_preview.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

RemoteStat _file(String path) => RemoteStat(path: path, kind: RemoteEntryKind.file, size: 10);

void main() {
  late FakeTransport transport;
  late WebPreview web;

  setUp(() {
    transport = FakeTransport()..fs = FakeFs();
    web = WebPreview(transport, machineName: 'build-box');
  });

  group('which links can be opened on the phone', () {
    test('plain http to the machine itself, nothing else', () {
      for (final url in [
        'http://localhost:3000',
        'http://127.0.0.1:8080/a?b=1',
        'http://0.0.0.0:5000',
        'http://[::1]:5173/',
        'http://localhost',
        'http://localhost:65535',
      ]) {
        expect(WebPreview.canPreview(url), isTrue, reason: url);
      }
      for (final url in [
        'https://localhost',
        'https://127.0.0.1:8443/',
        'http://example.com',
        'http://192.168.1.20:3000',
        'ftp://localhost/x',
        'http://localhost:0',
        'http://localhost:65536',
        'http://localhost:70000',
        'localhost:3000',
        '',
      ]) {
        expect(WebPreview.canPreview(url), isFalse, reason: url);
      }
    });

    test('a name the machine would resolve elsewhere is not the machine: the row would say one thing and dial another', () async {
      // `*.local` reaches other devices on the machine's network; another 127.x
      // or `*.localhost` is not what `localhost:...` on the row reads as.
      for (final url in [
        'http://devbox.local:4000/ui',
        'http://svc.default.svc.cluster.local:8080',
        'http://127.0.0.5:3000',
        'http://127.1.2.3:3000',
        'http://evil.localhost:3000',
      ]) {
        expect(WebPreview.canPreview(url), isFalse, reason: url);
        await expectLater(web.forwardUrl(Uri.parse(url)), throwsA(isA<WebPreviewException>()), reason: url);
      }
      expect(transport.webBridges, isEmpty);
    });

    test('a link that cannot be opened says so instead of asking the machine', () async {
      await expectLater(web.forwardUrl(Uri.parse('https://localhost:3000')), throwsA(isA<WebPreviewException>()));
      expect(transport.webBridges, isEmpty);
    });

    test('a port that does not exist says so, not that the address is wrong', () async {
      for (final url in ['http://localhost:0', 'http://localhost:65536']) {
        await expectLater(
          web.forwardUrl(Uri.parse(url)),
          throwsA(isA<WebPreviewException>().having((e) => e.message, 'message', contains('port number is not valid'))),
          reason: url,
        );
      }
      await expectLater(
        web.forwardUrl(Uri.parse('http://example.com:3000')),
        throwsA(isA<WebPreviewException>().having((e) => e.message, 'message', isNot(contains('port number')))),
      );
      expect(transport.webBridges, isEmpty);
    });
  });

  group('a link on the machine', () {
    test('the entry URL is on localhost, carries the token, and keeps path, query and fragment', () async {
      final url = await web.forwardUrl(Uri.parse('http://localhost:3000/app/x%20y?tab=a%26b&n=1#top'));
      expect(url.scheme, 'http');
      expect(url.host, 'localhost');
      expect(url.port, transport.webInfo.entryPort);
      expect(url.path, '/__herdr/open');
      expect(url.queryParameters['t'], transport.webInfo.token);
      expect(url.queryParameters['to'], '/app/x%20y?tab=a%26b&n=1#top');
      expect(url.hasFragment, isFalse, reason: 'the page that sends the browser on would drop it');
      expect(transport.webBridges.single, isA<PortForward>().having((s) => s.port, 'port', 3000));
    });

    test('the entry URL goes to the entry listener, not to the port the dev server is reached on', () async {
      transport.webInfo = const WebBridgeInfo(port: 3000, token: '0123456789abcdef0123456789abcdef', entryPort: 51999);
      final url = await web.forwardUrl(Uri.parse('http://localhost:3000/app'));
      expect(url.port, 51999, reason: 'a connection the browser keeps to port 3000 is the dev server\'s, the token must not ride on it');
      expect(url.queryParameters['to'], '/app');
    });

    test('an encoded fragment is not encoded twice', () async {
      final url = await web.forwardUrl(Uri.parse('http://localhost:3000/#a%20b'));
      expect(url.queryParameters['to'], '/#a%20b');
    });

    test('no port means 80, no path means the root', () async {
      final url = await web.forwardUrl(Uri.parse('http://localhost'));
      expect((transport.webBridges.single as PortForward).port, 80);
      expect(url.queryParameters['to'], '/');
      expect(url.hasFragment, isFalse);
    });

    test('every spelling of the machine itself is one listener', () async {
      for (final host in ['0.0.0.0', '[::]', '127.0.0.1', '[::1]', 'localhost', 'LOCALHOST']) {
        await web.forwardUrl(Uri.parse('http://$host:8080'));
      }
      expect(transport.webBridges.map((s) => s.key).toSet(), {'f|localhost|8080'});
    });

    test('a listener that could not take the target port number tells the person once', () async {
      final notes = <String>[];
      transport.webInfo = const WebBridgeInfo(port: 51111, token: '0123456789abcdef0123456789abcdef');
      final url = await web.forwardUrl(Uri.parse('http://localhost:3000/x'), onNote: notes.add);
      expect(url.port, 51111, reason: 'the page still opens, on the port it got');
      expect(notes, ['Opened on port 51111: a page that expects localhost:3000 may not work.']);

      // The same number: nothing to say.
      notes.clear();
      transport.webInfo = const WebBridgeInfo(port: 3000, token: '0123456789abcdef0123456789abcdef');
      await web.forwardUrl(Uri.parse('http://localhost:3000'), onNote: notes.add);
      expect(notes, isEmpty);
    });

    test('machine name reaches the listener for its error pages', () async {
      await web.forwardUrl(Uri.parse('http://localhost:3000'));
      expect(transport.webBridges.single.machineName, 'build-box');
    });

    test('a refusal reads as a sentence about this phone', () async {
      transport.webFailure = const HerdrTransportException('the machine does not allow port forwarding', fatal: true);
      await expectLater(
        web.forwardUrl(Uri.parse('http://localhost:3000')),
        throwsA(isA<WebPreviewException>().having(
          (e) => e.message,
          'message',
          "Couldn't open on this phone: the machine does not allow port forwarding.",
        )),
      );
      transport.webFailure = const HerdrTransportException('Cannot open a local port: SocketException.');
      await expectLater(
        web.forwardUrl(Uri.parse('http://localhost:3000')),
        throwsA(isA<WebPreviewException>().having(
          (e) => e.message,
          'message',
          "Couldn't open on this phone: cannot open a local port: SocketException.",
        )),
      );
    });
  });

  group('an HTML file', () {
    test('serves the file\'s own folder and opens the file in it', () async {
      final url = await web.staticUrl(_file('/home/dev/report/out/index.html'), fragment: 'sec 2');
      final spec = transport.webBridges.single as StaticSite;
      expect(spec.root, '/home/dev/report/out');
      expect(url.queryParameters['to'], '/index.html#sec%202');
      expect(url.host, 'localhost');
    });

    test('a name with spaces and non-ASCII letters survives both encodings', () async {
      final url = await web.staticUrl(_file('/work/My Chartü.html'));
      expect(url.queryParameters['to'], '/My%20Chart%C3%BC.html');
      expect(Uri.decodeComponent(url.queryParameters['to']!), '/My Chartü.html');
    });

    test('a file in the top folder serves the root', () async {
      await web.staticUrl(_file('/index.html'));
      expect((transport.webBridges.single as StaticSite).root, '/');
    });

    test('a machine without files says so, a path that is not absolute is refused', () async {
      transport.fs = null;
      await expectLater(
        web.staticUrl(_file('/a/b.html')),
        throwsA(isA<WebPreviewException>().having((e) => e.message, 'message', 'Files are not available on this machine.')),
      );
      transport.fs = FakeFs();
      await expectLater(web.staticUrl(_file('b.html')), throwsA(isA<WebPreviewException>()));
      expect(transport.webBridges, isEmpty);
    });
  });
}
