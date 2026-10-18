import 'dart:async';

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
/// is on the stack the connections are held up ([FleetRepository.holdAlive]),
/// with the Watching notice, so switching apps or turning the screen off
/// does not end the page either.
///
/// The view loads only this machine's listeners ([webNavigation]); a link to
/// the web opens in the phone's browser, where sign-ins live. JavaScript runs
/// (dev pages need it) with no channel to the app, no file access and no
/// third-party cookies. `Open in browser` in ⋯ hands the page to the phone's
/// browser for what needs it (a Google sign-in refuses embedded views).
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

/// What went wrong, for the panel.
typedef _Failure = ({String title, String message});

class _WebPreviewScreenState extends State<WebPreviewScreen> {
  late final WebViewController _view = _newView();
  late final Toaster _toaster = Toaster.of(context);
  VoidCallback? _release;

  var _phase = _Phase.opening;
  _Failure? _failure;

  /// The page that failed to load: what Retry opens again.
  Uri? _failedUrl;

  /// The page shown (the phone's address).
  Uri? _url;
  String? _title;
  var _progress = 0;
  var _canGoBack = false;

  /// Back was asked of the view: a page it lands on that is an entry URL is
  /// not a page (see [_skipEntry]).
  var _goingBack = false;

  /// The view is on an entry URL.
  var _atEntry = false;

  /// The last address let through, until a page starts: Android hands a
  /// download back as a second request for the same address, which loading
  /// would answer with the same download, forever.
  String? _pending;

  WebPreview get _web => widget.machine.web;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // After the first frame: the hold tells the fleet's listeners, which
      // must not rebuild while this route is being built.
      _release = context.read<FleetRepository>().holdAlive();
      unawaited(_open());
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
    final release = _release;
    // Not inside the frame that unmounts this route: the hold tells the
    // fleet's listeners, which may rebuild.
    if (release != null) scheduleMicrotask(release);
    super.dispose();
  }

  WebViewController _newView() {
    final view = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onProgress: (p) {
            if (mounted && p != _progress) setState(() => _progress = p);
          },
          onUrlChange: (change) => unawaited(_onUrl(change.url)),
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
    }
    return view;
  }

  // -- opening ---------------------------------------------------------------

  /// Asks the machine for the page ([at]: a page of it that failed, else the
  /// one this screen was opened for) and loads it.
  Future<void> _open({Uri? at}) async {
    setState(() {
      _phase = _Phase.opening;
      _failure = null;
      _progress = 0;
    });
    try {
      final entry = at != null && _web.machinePage(at) != null ? await _web.reopen(at) : await _entryOf(widget.page);
      if (!mounted) return;
      setState(() => _phase = _Phase.loading);
      await _view.loadRequest(entry);
    } on WebPreviewException catch (e) {
      _fail('Couldn’t open ${widget.page.label}', e.message, at ?? _url);
    } on RemoteFileException catch (e) {
      _fail(
        'Couldn’t open ${widget.page.label}',
        e.kind == RemoteFileErrorKind.notFound
            ? '${visibleText(widget.page.label)} is not on the machine any more.'
            : visibleText(e.message),
        at,
      );
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
    setState(() {
      _failure = (title: visibleText(title), message: message);
      _failedUrl = url;
      if (_phase == _Phase.opening) _phase = _Phase.loading;
    });
  }

  void _retry() => unawaited(_open(at: _failedUrl));

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
          _toaster.show('Files don’t download here. Open in browser (⋯) gets them.');
          return NavigationDecision.prevent;
        }
        if (request.isMainFrame) _pending = request.url;
        return NavigationDecision.navigate;
      case WebNavigation.browser:
        unawaited(_toBrowser(request.url));
        return NavigationDecision.prevent;
      case WebNavigation.refuse:
        if (request.isMainFrame) _refused(url);
        return NavigationDecision.prevent;
    }
  }

  /// A link to the web: the phone's browser, with the person's own sign-ins.
  Future<void> _toBrowser(String url) async {
    if (!await openTappedLink(url)) {
      _toaster.show('Couldn’t open on this phone: no browser could open it.', kind: ToastKind.failed);
    }
  }

  /// Says why [url] did not open. Another port of the machine's `localhost`
  /// (a front end linking its API) is one deliberate tap away: the same
  /// forward `Open on phone` would open, never on its own.
  void _refused(Uri url) {
    final where = url.hasPort ? '${url.host}:${url.port}' : url.host;
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
    _toaster.show('herdr doesn’t open ${url.scheme}: links from a page.');
  }

  Future<void> _forward(Uri link) async {
    if (!mounted) return;
    try {
      final entry = await _web.forwardUrl(link, onNote: _toaster.show);
      if (mounted) await _view.loadRequest(entry);
    } on WebPreviewException catch (e) {
      _toaster.show(e.message, kind: ToastKind.failed);
    }
  }

  void _onPageStarted(String url) {
    _pending = null;
    if (!mounted) return;
    setState(() {
      _failure = null;
      _progress = 0;
    });
  }

  void _onPageFinished(String url) {
    final uri = Uri.tryParse(url);
    if (!mounted || uri == null || WebPreview.isEntryUrl(uri) || _failure != null) return;
    _goingBack = false;
    if (_phase != _Phase.shown) {
      // The web's default canvas: a page with no background of its own
      // expects white, as in any browser.
      // design-lint: allow(raw-color) the web's own default canvas, not a herdr surface
      unawaited(_view.setBackgroundColor(const Color(0xFFFFFFFF)));
      setState(() => _phase = _Phase.shown);
    }
    unawaited(_onUrl(url));
  }

  Future<void> _onUrl(String? url) async {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !mounted) return;
    _atEntry = WebPreview.isEntryUrl(uri);
    if (_atEntry) {
      if (_goingBack) await _skipEntry();
      return;
    }
    _goingBack = false; // a page, also one reached without a load (`#section`)
    final title = await _view.getTitle();
    final canGoBack = await _view.canGoBack();
    if (!mounted) return;
    setState(() {
      _url = uri;
      _title = _usable(title, url!);
      _canGoBack = canGoBack;
    });
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
    final label = (url == null ? null : _web.machinePage(url)?.label) ?? widget.page.label;
    _fail('Couldn’t load $label', _why(error), url);
  }

  /// What a failed load means here, and what Retry does about it.
  String _why(WebResourceError error) => switch (error.errorType) {
        WebResourceErrorType.connect =>
          'herdr stopped serving it on this phone (after 10 minutes unused, or a new connection). Retry opens it again.',
        WebResourceErrorType.timeout => 'It took too long to answer. Retry asks again.',
        _ => '${error.description}. Retry asks again.',
      };

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
    if (await _view.canGoBack()) {
      _goingBack = true;
      await _view.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _reload() {
    if (_failure != null) return _retry();
    unawaited(_view.reload());
  }

  MachinePage? get _shownPage => _url == null ? null : _web.machinePage(_url!);

  void _showOptions() {
    final page = _shownPage;
    final isFile = widget.page is FilePage;
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
              page?.address ?? widget.page.address,
              what: isFile ? 'Path copied' : 'Link copied',
            ),
          ),
          SheetAction(
            label: 'Open in browser',
            icon: LucideIcons.externalLink,
            onTap: () => unawaited(_openInBrowser()),
          ),
        ],
        footer: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.sm),
            child: Text(
              'For sign-in pages. The page works while it stays open here.',
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
    final place = page?.place ?? switch (widget.page) {
      ServerPage(:final link) => MachinePage.server(link).place,
      FilePage() => widget.page.label,
    };
    final failure = _failure;
    final covered = failure != null || _phase != _Phase.shown;
    final loading = failure == null && _phase != _Phase.opening && _progress < 100;
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        backgroundColor: ds.bg,
        body: Column(
          children: [
            AppTopBar(
              title: visibleText(_title ?? page?.label ?? widget.page.label),
              // The address in a pill, as a browser shows it: the screen reads as
              // a web page and not as one of herdr's own (an owner's check found
              // title-over-host alone looked like any other screen). The hairline
              // under the bar marks where the page starts.
              bottom: _AddressPill(
                address: visibleText(page?.label ?? place),
                machine: widget.machine.profile.label,
              ),
              actions: [
                CircleButton(
                  icon: LucideIcons.rotateCw,
                  tooltip: 'Reload',
                  onPressed: _phase == _Phase.opening && failure == null ? null : _reload,
                ),
                CircleButton(icon: LucideIcons.ellipsis, tooltip: 'Page options', onPressed: _showOptions),
              ],
            ),
            _LoadBar(progress: loading ? _progress : null),
            Expanded(
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
                                    color: ds.danger,
                                    icon: LucideIcons.globe,
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
          ],
        ),
      ),
    );
  }
}

/// A hairline under the bar that fills with the page's load ([progress] of
/// 100), then goes; nothing while no page loads. It moves only with real
/// progress: no loop.
/// `🌐 localhost:8790/page2.html · tuannd12`: where the page comes from, in a
/// quiet pill under the title, one line, the address cut at its end.
class _AddressPill extends StatelessWidget {
  const _AddressPill({required this.address, required this.machine});

  final String address;
  final String machine;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: DecoratedBox(
          decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.pill)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: Gap.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.globe, size: IconSize.inline, color: ds.textSecondary),
                const SizedBox(width: Gap.xs),
                Flexible(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: address, style: Type.caption.copyWith(color: ds.text)),
                      TextSpan(text: ' · $machine'),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.caption.copyWith(color: ds.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadBar extends StatelessWidget {
  const _LoadBar({required this.progress});

  final int? progress;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final p = progress;
    // Always a hairline: the edge between herdr and the page. Loading fills
    // it with the accent from the left.
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
