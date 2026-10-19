import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/models/web_bridge.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/web_preview.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import '../../render/visible_text.dart';
import '../../support/open_link.dart';
import '../pane/link_sheet.dart';
import 'web_navigation.dart';

/// What a [WebPreviewScreen] shows.
sealed class WebPage {
  const WebPage();

  /// What the bar says before the page has a title of its own.
  String get label;

  /// What Copy link (or Copy path) copies before the page has loaded.
  String get address;
}

/// A dev server address on the machine (`http://localhost:8790/#b`).
final class ServerPage extends WebPage {
  const ServerPage(this.link);

  final Uri link;

  MachinePage get _page => MachinePage.server(link);

  @override
  String get label => _page.label;

  @override
  String get address => link.toString();
}

/// An HTML or SVG file on the machine, served from its own folder: [stat]
/// when it is known, else [path] (relative to [cwd]) looked up first.
final class FilePage extends WebPage {
  const FilePage(this.path, {this.cwd}) : stat = null;
  FilePage.stat(RemoteStat this.stat)
      : path = stat.path,
        cwd = null;

  final String path;
  final String? cwd;
  final RemoteStat? stat;

  @override
  String get label => RemotePath.basename(path);

  @override
  String get address => path;
}

/// Shows [page] of [machine] in herdr ([WebPreviewScreen]). The screen goes
/// up at once and asks the machine inside it.
Future<void> openWebPreview(BuildContext context, MachineConnection machine, WebPage page) {
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => WebPreviewScreen(machine: machine, page: page)),
  );
}

/// A page from a machine, shown inside herdr: a dev server on the machine's
/// `localhost`, or an HTML file from its folder, carried over the machine's
/// SSH connection by a loopback listener on the phone (`WebBridgeHost`).
///
/// Why inside herdr and not the phone's browser (what this used to do): in a
/// Custom Tab herdr went to the background, Android dropped its SSH
/// connection, and the page waited on "Opening…" forever. While this screen
/// is on the stack its machine's connection is held up
/// ([FleetRepository.holdAlive], with the Watching notice), so switching
/// apps or turning the screen off does not end the page either. Where that
/// cannot hold (no notice: refused, or iOS), a dropped connection is said on
/// the screen and the page comes back by itself when the machine does.
///
/// The view loads only this machine's listeners ([webNavigation]); a page of
/// the web is offered to the phone's browser on the person's tap, never opened
/// by a page's script. JavaScript runs (dev pages need it) with no channel to
/// the app, no file access and no third-party cookies; cookies, web storage
/// and the cache are cleared when the last such screen closes. `Open in
/// browser` in ⋯ hands the page to the phone's browser for what needs it (a
/// Google sign-in refuses embedded views).
class WebPreviewScreen extends StatefulWidget {
  const WebPreviewScreen({super.key, required this.machine, required this.page});

  final MachineConnection machine;
  final WebPage page;

  @override
  State<WebPreviewScreen> createState() => _WebPreviewScreenState();
}

enum _Phase {
  /// The machine is being asked for the listener.
  opening,

  /// The view loads, behind a cover, until the first page is in.
  loading,

  /// A page is shown.
  shown,
}

/// What went wrong, for the panel. The bar already names the page, so the
/// title does not.
typedef _Failure = ({String title, String message});

class _WebPreviewScreenState extends State<WebPreviewScreen> {
  /// Page screens open now, over every machine: the last one to close clears
  /// what the views kept ([_forget]).
  static var _open = 0;

  /// The first page screen to open clears, before its first load, what a
  /// process that was killed with a page open could not.
  late var _forgetFirst = _open == 0;

  late final WebViewController _view = _newView();
  late final Toaster _toaster = Toaster.of(context);

  // -- the bar steps aside while reading ----------------------------------
  //
  // Reading down a page, the bar folds away and the page gets its height, as
  // a browser's does; any scroll up, the top of the page, a new page, and
  // anything that is not the page plainly shown bring it back. It moves only
  // when no finger is on the page, so the page never jumps under a finger
  // (the view never moves under a finger: herdr-motion).

  /// How far the page is read down, in one go, before the bar folds away.
  static const _barHideAfter = 48.0;

  /// How far a scroll up brings the bar back: a small pull is enough.
  static const _barShowAfter = 16.0;

  bool _barHidden = false;
  bool? _barWanted;
  double? _scrollY;
  double _scrollRun = 0;
  int _fingers = 0;
  VoidCallback? _release;

  var _phase = _Phase.opening;
  _Failure? _failure;

  /// The page that failed to load: what Retry opens again.
  Uri? _failedUrl;

  /// The machine's connection dropped while a page was shown: the page comes
  /// back by itself when it is live again.
  var _linkLost = false;

  /// The page shown (the phone's address).
  Uri? _url;
  String? _title;
  var _progress = 0;
  Timer? _titleTimer;

  /// How many pages of this screen's own sit behind the one shown in the
  /// view's history. Back goes back while there is one, and leaves when there
  /// is none, without a trip through the entry page the view keeps behind the
  /// first page (Android's plugin loads every navigation anew, so that entry
  /// stays in the history; landing on it would show "Opening…").
  var _behind = 0;

  /// The next page is the first after an entry page: it starts with [_carry]
  /// pages behind it.
  var _afterEntry = false;
  var _carry = 0;

  /// Back was asked of the view: a page it lands on that is an entry URL is
  /// not a page (see [_skipEntry]).
  var _goingBack = false;

  /// The view is on an entry URL: covered, so its "Opening…" never shows.
  var _atEntry = false;

  /// The last address let through, until a page starts: Android hands a
  /// download back as a second request for the same address, which loading
  /// would answer with the same download, forever.
  String? _pending;

  WebPreview get _web => widget.machine.web;

  @override
  void initState() {
    super.initState();
    _forgetFirst;
    _open++;
    widget.machine.addListener(_onLink);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // After the first frame: the hold tells the fleet's listeners, which
      // must not rebuild while this route is being built.
      _release = context.read<FleetRepository>().holdAlive(
            widget.machine.profile.id,
            page: '${widget.page.label} on ${widget.machine.profile.label}',
          );
      unawaited(_openPage());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // While nothing is shown the view is the screen's own colour, so no
    // white flashes in the dark; a page shown gets the web's own default.
    if (_phase != _Phase.shown) unawaited(_view.setBackgroundColor(context.ds.bg));
  }

  @override
  void dispose() {
    widget.machine.removeListener(_onLink);
    _titleTimer?.cancel();
    final release = _release;
    // Not inside the frame that unmounts this route: the hold tells the
    // fleet's listeners, which may rebuild.
    if (release != null) scheduleMicrotask(release);
    if (--_open == 0) unawaited(_forget(_view));
    super.dispose();
  }

  /// Clears the cookies, web storage (local storage, IndexedDB) and cache
  /// every page view keeps, for all sites. Why: storage is kept per origin,
  /// and an origin is the phone's `localhost:<port>`, which two machines can
  /// hold one after the other: one machine's page would read the other's
  /// storage and send its listener cookies. Service workers are not cleared
  /// (the plugin has no call for them).
  static Future<void> _forget(WebViewController view) async {
    try {
      await WebViewCookieManager().clearCookies();
      await view.clearLocalStorage();
      await view.clearCache();
    } on Object catch (e) {
      debugPrint('herdr: page storage not cleared: $e');
    }
  }

  WebViewController _newView() {
    final view = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setOnScrollPositionChange(_onScroll)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onProgress: (p) {
            if (mounted && p != _progress) setState(() => _progress = p);
          },
          onUrlChange: (change) => _onUrl(change.url),
          onWebResourceError: _onError,
        ),
      );
    final android = view.platform;
    if (android is AndroidWebViewController) {
      unawaited(android.setAllowFileAccess(false));
      unawaited(android.setAllowContentAccess(false));
      unawaited(android.setGeolocationEnabled(false));
      unawaited(android.setMixedContentMode(MixedContentMode.neverAllow));
      final cookies = WebViewCookieManager().platform;
      if (cookies is AndroidWebViewCookieManager) unawaited(cookies.setAcceptThirdPartyCookies(android, false));
      // `window.open` cannot be turned off through the plugin; a new window
      // is asked of [_onNavigation] like any navigation and opens nowhere
      // the rule refuses.
    }
    return view;
  }

  void _onScroll(ScrollPositionChange change) {
    if (!mounted) return;
    // Android reports device pixels, iOS points.
    final scale = defaultTargetPlatform == TargetPlatform.android ? MediaQuery.devicePixelRatioOf(context) : 1.0;
    final y = change.y / scale;
    final last = _scrollY;
    _scrollY = y;
    if (y <= 0) {
      _scrollRun = 0;
      return _wantBar(true);
    }
    if (last == null) return;
    final dy = y - last;
    if (dy == 0) return;
    if (_scrollRun != 0 && dy.sign != _scrollRun.sign) _scrollRun = 0;
    _scrollRun += dy;
    if (_scrollRun > _barHideAfter) {
      _wantBar(false);
    } else if (_scrollRun < -_barShowAfter) {
      _wantBar(true);
    }
  }

  void _wantBar(bool shown) {
    _barWanted = shown;
    if (_fingers == 0) _applyBar();
  }

  void _applyBar() {
    final want = _barWanted;
    _barWanted = null;
    if (want == null || _barHidden == !want || !mounted) return;
    setState(() => _barHidden = !want);
  }

  void _fingerUp(PointerEvent _) {
    if (_fingers > 0) _fingers--;
    if (_fingers == 0) _applyBar();
  }

  // -- opening ---------------------------------------------------------------

  /// Asks the machine for the page ([at]: a page of it that failed, else the
  /// one this screen was opened for) and loads it. A page opened again starts
  /// its own history: Back leaves after it.
  Future<void> _openPage({Uri? at}) async {
    setState(() {
      _phase = _Phase.opening;
      _failure = null;
      _progress = 0;
    });
    try {
      if (_forgetFirst) {
        _forgetFirst = false;
        await _forget(_view);
      }
      final entry = at != null && _web.machinePage(at) != null ? await _web.reopen(at) : await _entryOf(widget.page);
      if (!mounted) return;
      setState(() => _phase = _Phase.loading);
      _carry = 0;
      await _view.loadRequest(entry);
    } on WebPreviewException catch (e) {
      _fail('Couldn’t open this page', e.reason, at ?? _url);
    } on RemoteFileException catch (e) {
      _fail(
        'Couldn’t open this page',
        e.kind == RemoteFileErrorKind.notFound
            ? '${visibleText(widget.page.label)} is not on the machine any more.'
            : visibleText(e.message),
        at,
      );
    } on Object catch (e) {
      debugPrint('herdr: page not opened: $e');
      _fail('Couldn’t open this page', 'Something went wrong on the phone. Retry tries again.', at);
    }
  }

  /// The entry URL of [page]: the only URL that carries the listener's token.
  Future<Uri> _entryOf(WebPage page) async {
    switch (page) {
      case ServerPage(:final link):
        return _web.forwardUrl(link, onNote: _toaster.show);
      case FilePage(:final stat?):
        return _web.staticUrl(stat);
      case FilePage(:final path, :final cwd):
        final files = widget.machine.files;
        if (!files.supported) throw const WebPreviewException('Files are not available on this machine.');
        return _web.staticUrl(await files.stat(await files.resolve(path, cwd: cwd)));
    }
  }

  void _fail(String title, String message, Uri? url) {
    if (!mounted) return;
    _goingBack = false;
    setState(() {
      _failure = (title: title, message: message);
      _failedUrl = url;
      if (_phase == _Phase.opening) _phase = _Phase.loading;
    });
  }

  void _retry() => unawaited(_openPage(at: _failedUrl));

  /// The machine's connection went down or came back. A page shown over a
  /// connection that dropped (Android froze herdr without the notice, or the
  /// network went) cannot work, so the screen says so; back, the page opens
  /// again by itself.
  void _onLink() {
    if (!mounted) return;
    final live = widget.machine.isLive;
    if (!live && !_linkLost && _url != null) {
      setState(() {
        _linkLost = true;
        _failure = (
          title: 'Lost the connection to ${widget.machine.profile.label}',
          message: 'The page comes back by itself when herdr is connected again.',
        );
        _failedUrl = _url;
      });
    } else if (live && _linkLost) {
      _linkLost = false;
      unawaited(_openPage(at: _failedUrl));
    }
  }

  // -- the view's events -------------------------------------------------------

  NavigationDecision _onNavigation(NavigationRequest request) {
    final url = Uri.tryParse(request.url);
    if (url == null) return NavigationDecision.prevent;
    // Back reached an entry URL, which sends the view on again at once; Back
    // goes past it instead ([_skipEntry]).
    if (_goingBack && _atEntry) return NavigationDecision.prevent;
    switch (webNavigation(url, ports: _web.ports, mainFrame: request.isMainFrame)) {
      case WebNavigation.load:
        if (request.isMainFrame && _pending == request.url) {
          // A file: Android asks for it again instead of showing it.
          if (mounted) setState(() => _progress = 100);
          _toaster.show('That link is a file, and herdr doesn’t download files. Open in browser (⋯) can.');
          return NavigationDecision.prevent;
        }
        if (request.isMainFrame) _pending = request.url;
        return NavigationDecision.navigate;
      case WebNavigation.web:
        _offerWeb(url);
        return NavigationDecision.prevent;
      case WebNavigation.refuse:
        if (request.isMainFrame) _refused(url);
        return NavigationDecision.prevent;
    }
  }

  /// A page of the web the page wanted to go to. A script can ask for that
  /// without anyone's tap, so nothing opens by itself: the person is told
  /// where it leads and opens it in the phone's browser with a tap.
  void _offerWeb(Uri url) {
    _toaster.show(
      '${visibleText(url.host)} isn’t from ${widget.machine.profile.label}.',
      action: ToastAction('Open', () => unawaited(_openWeb(url))),
    );
  }

  /// [url] of the web in the phone's browser: `https` at once, plain `http`
  /// through the link sheet, which shows the whole address and says it is
  /// not encrypted.
  Future<void> _openWeb(Uri url) async {
    if (url.scheme == 'https') {
      if (!await openInBrowser(url.toString())) {
        _toaster.show('Couldn’t open on this phone: no browser could open it.', kind: ToastKind.failed);
      }
    } else if (mounted) {
      await showLinkSheet(context, url.toString());
    }
  }

  /// Says why [url] did not open. Another port of the machine's `localhost`
  /// (a front end linking its API) is one deliberate tap away: the same
  /// forward `Open page` would open, never on its own.
  void _refused(Uri url) {
    final where = visibleText(url.hasPort ? '${url.host}:${url.port}' : url.host);
    if (WebPreview.canPreview(url.toString())) {
      final service = sensitiveServiceOf(url.hasPort ? url.port : 80);
      if (service != null) {
        _toaster.show('$where is a $service port. Open its link from the terminal if you mean to.');
        return;
      }
      _toaster.show(
        '$where isn’t open on this phone.',
        action: ToastAction('Open', () => unawaited(_forward(url))),
      );
      return;
    }
    if (isMachineLocalUrl(url.toString())) {
      _toaster.show('$where isn’t open on this phone.');
      return;
    }
    _toaster.show('herdr doesn’t open ${visibleText(url.scheme)}: links from a page.');
  }

  /// Another port of the machine, on the person's tap. Back from it returns
  /// to the page that linked it.
  Future<void> _forward(Uri link) async {
    if (!mounted) return;
    try {
      final entry = await _web.forwardUrl(link, onNote: _toaster.show);
      if (!mounted) return;
      _carry = _behind + 1;
      await _view.loadRequest(entry);
    } on WebPreviewException catch (e) {
      _toaster.show(e.message, kind: ToastKind.failed);
    }
  }

  void _onPageStarted(String url) {
    _pending = null;
    // A new page starts at its top, with the bar.
    _scrollY = null;
    _scrollRun = 0;
    _barWanted = null;
    _barHidden = false;
    final uri = Uri.tryParse(url);
    if (!mounted) return;
    setState(() {
      if (uri != null) _atEntry = WebPreview.isEntryUrl(uri);
      if (!_linkLost) _failure = null;
      _progress = 0;
    });
  }

  void _onPageFinished(String url) {
    final uri = Uri.tryParse(url);
    if (!mounted || uri == null || WebPreview.isEntryUrl(uri) || _failure != null) return;
    if (_phase != _Phase.shown) {
      // The web's default canvas: a page with no background of its own
      // expects white, as in any browser.
      // design-lint: allow(raw-color) the web's own default canvas, not a herdr surface
      unawaited(_view.setBackgroundColor(const Color(0xFFFFFFFF)));
      setState(() => _phase = _Phase.shown);
    }
    _onUrl(url);
  }

  /// The view shows [url]: counts the page in [_behind] (once per change:
  /// a page's load reports its address twice), and reads its title.
  void _onUrl(String? url) {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !mounted || uri.scheme == 'about') return;
    if (WebPreview.isEntryUrl(uri)) {
      _atEntry = true;
      if (_goingBack) {
        unawaited(_skipEntry());
      } else {
        _afterEntry = true;
      }
      return;
    }
    _atEntry = false;
    if (_goingBack) {
      _goingBack = false;
      if (_behind > 0) _behind--;
    } else if (_afterEntry) {
      _afterEntry = false;
      _behind = _carry;
      _carry = 0;
    } else if (uri != _url) {
      _behind++; // a link, a `#section`, a single-page app's route
    }
    setState(() => _url = uri);
    unawaited(_readTitle());
    // A single-page app sets its title after its route renders.
    _titleTimer?.cancel();
    _titleTimer = Timer(Dwell.titleSettle, () => unawaited(_readTitle()));
  }

  Future<void> _readTitle() async {
    final shown = _url;
    final title = await _view.getTitle();
    if (!mounted || shown == null || _url != shown) return;
    final usable = _usable(title, shown.toString());
    if (usable != _title) setState(() => _title = usable);
  }

  /// Back landed on an entry URL, the page that sends the view on with a
  /// cookie: it is no page of the machine, and showing it would send the
  /// person forward again. Back goes on past it, or leaves the screen when
  /// it was the first thing loaded.
  Future<void> _skipEntry() async {
    if (await _view.canGoBack()) {
      await _view.goBack();
    } else if (mounted) {
      _goingBack = false;
      Navigator.of(context).pop();
    }
  }

  void _onError(WebResourceError error) {
    if (error.isForMainFrame == false) return;
    final url = error.url == null ? _url : Uri.tryParse(error.url!);
    _fail('Couldn’t load this page', _why(error), url);
  }

  /// What a failed load means here, and what Retry does about it.
  String _why(WebResourceError error) {
    final machine = widget.machine.profile.label;
    return switch (error.errorType) {
      WebResourceErrorType.connect =>
        'herdr stopped serving it on this phone (after 10 minutes unused, or a new connection). Retry opens it again.',
      WebResourceErrorType.timeout => '$machine took too long to answer. Retry asks again.',
      WebResourceErrorType.io => 'The connection to $machine broke while the page loaded. Retry asks again.',
      WebResourceErrorType.redirectLoop => 'The page sends itself round in a loop. Retry asks again.',
      WebResourceErrorType.webContentProcessTerminated => 'The page stopped: its view ran out of memory or crashed. Retry opens it again.',
      _ when error.description.contains('EMPTY_RESPONSE') || error.description.contains('CONNECTION_CLOSED') =>
        'The server on $machine closed the connection without an answer. Is it still running? Retry asks again.',
      _ when error.description.contains('CONNECTION_RESET') =>
        'The connection to $machine broke while the page loaded. Retry asks again.',
      _ => 'It didn’t load (${error.description}). Retry asks again.',
    };
  }

  /// [title] when it names the page: not empty and not the address itself
  /// (what a page without a `<title>` reports).
  static String? _usable(String? title, String url) {
    final t = title?.trim();
    if (t == null || t.isEmpty || t == url || t.contains('://')) return null;
    return t;
  }

  // -- the person's actions ------------------------------------------------------

  /// Back goes back in the page's history first, then leaves.
  Future<void> _back() async {
    if (_goingBack) return;
    if (_behind > 0 && await _view.canGoBack()) {
      _goingBack = true;
      await _view.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  MachinePage? get _shownPage => _url == null ? null : _web.machinePage(_url!);

  /// The page shown is not from the machine (a form a page posted to another
  /// site, which Android does not ask about).
  bool get _foreign => _url != null && _shownPage == null;

  void _showOptions() {
    final page = _shownPage;
    final foreign = _foreign;
    final isFile = !foreign && widget.page is FilePage;
    final ds = context.ds;
    unawaited(
      showActionSheet(
        context,
        title: visibleText(_title ?? page?.label ?? widget.page.label),
        actions: [
          SheetAction(
            label: isFile ? 'Copy path' : 'Copy link',
            icon: LucideIcons.link,
            onTap: () => copyText(
              context,
              foreign ? _url.toString() : page?.address ?? widget.page.address,
              what: isFile ? 'Path copied' : 'Link copied',
            ),
          ),
          SheetAction(
            label: 'Open in browser',
            icon: LucideIcons.externalLink,
            onTap: () => unawaited(foreign ? _openWeb(_url!) : _openInBrowser()),
          ),
        ],
        footer: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.sm),
            child: Text(
              'For a page that needs your browser, such as a sign-in. The browser’s copy works only while this screen stays open.',
              style: Type.caption.copyWith(color: ds.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// The page in the phone's browser, for what an embedded view cannot do
  /// (Google refuses sign-in in one). The browser has none of this view's
  /// cookies, so it gets an entry URL of its own; the page keeps working
  /// while this screen (and its hold on the connection) stays.
  Future<void> _openInBrowser() async {
    try {
      final url = _url;
      final entry = url != null && _web.machinePage(url) != null ? await _web.reopen(url) : await _entryOf(widget.page);
      if (!await openPreviewUrl(entry)) {
        _toaster.show('Couldn’t open on this phone: no browser could open it.', kind: ToastKind.failed);
      }
    } on WebPreviewException catch (e) {
      _toaster.show(e.message, kind: ToastKind.failed);
    } on RemoteFileException catch (e) {
      _toaster.show(visibleText(e.message), kind: ToastKind.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final page = _shownPage;
    final foreign = _foreign;
    final place = page?.place ?? switch (widget.page) {
      ServerPage(:final link) => MachinePage.server(link).place,
      FilePage() => widget.page.label,
    };
    final title = visibleText(_title ?? (foreign ? _url!.host : page?.label ?? widget.page.label));
    final address = foreign ? visibleText(_url!.host) : visibleText(page?.label ?? place);
    final failure = _failure;
    final covered = failure != null || _phase != _Phase.shown || _atEntry;
    final loading = failure == null && _phase != _Phase.opening && _progress < 100;
    return PopScope(
      canPop: _behind == 0 && !_goingBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        backgroundColor: ds.bg,
        body: Column(
          children: [
            // The status bar's height stays: only the bar itself folds.
            SizedBox(height: MediaQuery.paddingOf(context).top),
            Collapse(
              open: !_barHidden || covered || MediaQuery.accessibleNavigationOf(context),
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: AppTopBar(
              title: title,
              // The address in a pill, as a browser shows it: the screen reads as
              // a web page and not as one of herdr's own (an owner's check found
              // title-over-host alone looked like any other screen). Said once:
              // a title that is the address leaves the pill the machine's name.
              // It is the bar's second line, not a row of its own, so the page
              // keeps the height.
              subtitleLine: AddressPill(
                address: address == title ? null : address,
                where: widget.machine.profile.label,
                foreign: foreign,
              ),
              actions: [
                CircleButton(
                  icon: LucideIcons.rotateCw,
                  tooltip: 'Reload',
                  // A failure has its own Retry, in the panel.
                  onPressed: _phase == _Phase.opening || failure != null ? null : () => unawaited(_view.reload()),
                ),
                CircleButton(icon: LucideIcons.ellipsis, tooltip: 'Page options', onPressed: _showOptions),
              ],
                ),
              ),
            ),
            _LoadBar(progress: loading ? _progress : null),
            Expanded(
              child: Listener(
                // Translucent: the page's own view takes the touch; this only counts fingers.
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => _fingers++,
                onPointerUp: _fingerUp,
                onPointerCancel: _fingerUp,
                child: Padding(
                // The app is edge to edge: a page's own footer must not sit
                // under the gesture bar.
                padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                child: Stack(
                  children: [
                    Positioned.fill(child: WebViewWidget(controller: _view)),
                    if (covered)
                      Positioned.fill(
                        child: ColoredBox(
                          color: ds.bg,
                          child: failure != null
                              ? ListView(
                                  padding: const EdgeInsets.all(Gap.lg),
                                  children: [
                                    StatusPanel(
                                      color: _linkLost ? ds.blocked : ds.danger,
                                      icon: _linkLost ? LucideIcons.unplug : LucideIcons.globe,
                                      title: failure.title,
                                      message: failure.message,
                                      liveRegion: true,
                                      trailing: AppButton(
                                        label: 'Retry',
                                        kind: AppButtonKind.secondary,
                                        compact: true,
                                        onPressed: _retry,
                                      ),
                                    ),
                                  ],
                                )
                              : _phase == _Phase.opening
                                  ? const Center(child: BusySpinner())
                                  : null,
                        ),
                      ),
                  ],
                ),
              ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The edge between herdr and the page: a hairline under the bar, always,
/// that fills with the accent from the left as a page loads ([progress] of
/// 100) and is plain again when it is in. It moves only with real progress:
/// no loop.
class _LoadBar extends StatelessWidget {
  const _LoadBar({required this.progress});

  final int? progress;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final p = progress;
    return SizedBox(
      height: Gap.hair,
      child: ColoredBox(
        color: ds.hairline,
        child: p == null
            ? null
            : Align(
                alignment: Alignment.centerLeft,
                child: AnimatedFractionallySizedBox(
                  duration: Motion.of(context, Motion.standard),
                  curve: Motion.easeOut,
                  widthFactor: p.clamp(0, 100) / 100,
                  heightFactor: 1, // the hairline's own height; Align alone would give none
                  child: ColoredBox(color: ds.accent),
                ),
              ),
      ),
    );
  }
}
