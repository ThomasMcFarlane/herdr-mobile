// Renders the video states of the file viewer to PNGs for review: the card of a
// big video (what Play will copy), the copy under way, the player, a copy that
// failed, a video the phone cannot open, and the card of a file that is not
// shown (Share or save). A long Vietnamese name; light at 412x892, and dark at
// 320x640 at 1.6 text scale. Off by default; it writes files:
//
//   VIDEO_SHOTS=1 flutter test test/ui/video_view_shots_test.dart
//
// Output: $VIDEO_SHOTS_DIR (default /tmp/video_shots)/<case>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/files/video_view.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../support/fake_fs.dart';
import '../support/fake_staging.dart';
import '../support/fake_video_platform.dart';
import '../support/files_support.dart';
import '../support/photo_support.dart' show FakeExport;
import '../support/shot.dart' show loadAppFonts;

const _name = 'Bản ghi màn hình buổi demo thanh toán — phiên bản cuối cùng (đã chỉnh sửa lần 3) 2026-05-20 at 09.30.mp4';
const _dir = '/home/dev/payments-api/docs/demo';

void main() {
  if (Platform.environment['VIDEO_SHOTS'] == null) {
    test('video shots are off (set VIDEO_SHOTS=1)', () {}, skip: 'set VIDEO_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['VIDEO_SHOTS_DIR'] ?? '/tmp/video_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Size size,
    Brightness brightness,
    double scale, {
    required int bytes,
    String file = _name,
    FakeStaging? staging,
    Object? openFails,
    Future<void> Function()? then,
  }) async {
    final fs = FakeFs()..addFile('$_dir/$file', Uint8List(bytes));
    final platform = FakeVideoPlatform()..openFails = openFails;
    final before = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = before);
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: key, child: child!),
        ),
        home: FileViewerScreen(
          machine: machineWithFiles(fs),
          stat: RemoteStat(
            path: '$_dir/$file',
            kind: RemoteEntryKind.file,
            size: bytes,
            modified: DateTime.utc(2026, 5, 20, 9, 30),
          ),
          staging: staging ?? FakeStaging(),
          export: FakeExport(),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await then?.call();
    await tester.pump(const Duration(milliseconds: 600));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-x$scale'}';
      await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  final sizes = [
    (const Size(412, 892), Brightness.light, 1.0),
    (const Size(320, 640), Brightness.dark, 1.6),
  ];
  const big = videoAutoCopyLimit * 10;

  for (final (size, b, scale) in sizes) {
    testWidgets('card ${size.width} $b', (tester) async {
      await shoot(tester, 'card', size, b, scale, bytes: big);
    });
    testWidgets('copying ${size.width} $b', (tester) async {
      final staging = FakeStaging()..hold = Completer<void>();
      await shoot(
        tester,
        'copying',
        size,
        b,
        scale,
        bytes: big,
        staging: staging,
        then: () async {
          await tester.tap(find.text('Play'));
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        },
      );
    });
    testWidgets('player ${size.width} $b', (tester) async {
      await shoot(tester, 'player', size, b, scale, bytes: 4000000);
    });
    testWidgets('copy-failed ${size.width} $b', (tester) async {
      final staging = FakeStaging()
        ..failWith = RemoteFileException(
          RemoteFileErrorKind.network,
          'The connection to devbox dropped while the file was being copied (3.1 MB of 240 MB).',
        );
      await shoot(tester, 'copy-failed', size, b, scale, bytes: 4000000, staging: staging);
    });
    testWidgets('cannot-play ${size.width} $b', (tester) async {
      await shoot(tester, 'cannot-play', size, b, scale, bytes: 4000000, openFails: PlatformException(code: 'unsupported'));
    });
    testWidgets('binary-card ${size.width} $b', (tester) async {
      await shoot(tester, 'binary-card', size, b, scale, bytes: 4000000, file: 'build-output-2026-05-20.dat');
    });
  }
}
