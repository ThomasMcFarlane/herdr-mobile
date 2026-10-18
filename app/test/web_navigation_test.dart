// Where a page of a machine shown in herdr may go: only the bridge's own
// listeners load in the view; the web goes to the phone's browser; the rest
// opens nowhere.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/features/web/web_navigation.dart';

void main() {
  const ports = {8790, 41999};
  WebNavigation decide(String url, {bool mainFrame = true}) =>
      webNavigation(Uri.parse(url), ports: ports, mainFrame: mainFrame);

  test('the preview\'s own listeners load, by the names a listener answers to', () {
    for (final url in [
      'http://localhost:8790/',
      'http://localhost:8790/page2.html#section-b',
      'http://127.0.0.1:8790/api?x=1',
      'http://LOCALHOST:8790/',
      'http://localhost:41999/__herdr/open?t=x&to=/',
    ]) {
      expect(decide(url), WebNavigation.load, reason: url);
    }
    expect(decide('about:blank'), WebNavigation.load);
    expect(decide('data:text/html,<p>hi</p>'), WebNavigation.load);
  });

  test('another port or name of the phone itself loads nowhere: not here, and not in the browser, where it would reach the phone', () {
    for (final url in [
      'http://localhost:3000/',
      'http://localhost/',
      'http://127.0.0.2:8790/',
      'http://[::1]:8790/',
      'http://0.0.0.0:8790/',
      'http://app.localhost:8790/',
      'http://printer.local/',
      'https://localhost:8790/',
    ]) {
      expect(decide(url), WebNavigation.refuse, reason: url);
    }
  });

  test('a link to the web goes to the phone\'s browser, sign-in redirects included, never into the view', () {
    for (final url in [
      'https://accounts.google.com/o/oauth2/v2/auth?client_id=x',
      'https://login.tailscale.com/a/l3503a0535f1bf',
      'https://github.com/tuan3w/herdr-mobile',
      'http://example.org/a',
    ]) {
      expect(decide(url), WebNavigation.browser, reason: url);
    }
  });

  test('other schemes open nowhere', () {
    for (final url in ['intent://scan#Intent;scheme=zxing;end', 'file:///sdcard/a.html', 'mailto:a@b.c', 'javascript:alert(1)', 'content://x/y']) {
      expect(decide(url), WebNavigation.refuse, reason: url);
    }
  });

  test('a frame never opens the browser: it cannot take the person anywhere', () {
    expect(decide('https://accounts.google.com/', mainFrame: false), WebNavigation.refuse);
    expect(decide('http://localhost:8790/frame.html', mainFrame: false), WebNavigation.load);
  });
}
