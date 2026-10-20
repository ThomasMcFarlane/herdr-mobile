import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';

import '../../../data/models/release_info.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

/// Plays a release's walkthrough clip ([ReleaseClip]) over the update sheet,
/// streamed from the release. Why in the app: GitHub serves release files as
/// downloads (`Content-Disposition: attachment`, `application/octet-stream`),
/// so the browser saved the .mp4 instead of playing it (seen on v0.1.20).
///
/// Nothing loads before the tap that opens this screen. It plays once, silent
/// (the clips have no sound), and stops when the screen closes; a tap on the
/// video pauses or resumes, and the end offers Play again. A failure says what
/// happened and offers Retry: never a dead end.
Future<void> openClipPlayer(BuildContext context, ReleaseClip clip, {required String title}) =>
    Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: Motion.page,
      reverseTransitionDuration: Motion.sheetOut,
      pageBuilder: (context, _, _) => ClipPlayerScreen(clip: clip, title: title),
      transitionsBuilder: (context, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Motion.easeOut, reverseCurve: Motion.easeOut),
        child: child,
      ),
    ));

class ClipPlayerScreen extends StatefulWidget {
  const ClipPlayerScreen({super.key, required this.clip, required this.title});

  final ReleaseClip clip;
  final String title;

  @override
  State<ClipPlayerScreen> createState() => _ClipPlayerScreenState();
}

class _ClipPlayerScreenState extends State<ClipPlayerScreen> {
  VideoPlayerController? _video;
  Object? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_video?.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    final old = _video;
    final video = VideoPlayerController.networkUrl(Uri.parse(widget.clip.video));
    setState(() {
      _video = video;
      _failure = null;
    });
    unawaited(old?.dispose());
    try {
      await video.initialize();
      await video.setVolume(0);
      if (!mounted || _video != video) return;
      await video.play();
      setState(() {});
    } on Object catch (e) {
      if (mounted && _video == video) setState(() => _failure = e);
    }
  }

  void _toggle(VideoPlayerController video) {
    final v = video.value;
    if (v.isCompleted || (v.position >= v.duration && v.duration > Duration.zero)) {
      unawaited(video.seekTo(Duration.zero).then((_) => video.play()));
    } else if (v.isPlaying) {
      unawaited(video.pause());
    } else {
      unawaited(video.play());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final video = _video;
    return Scaffold(
      backgroundColor: ds.bg,
      // The bar pads itself below the status bar.
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTopBar(title: widget.title, subtitle: widget.clip.label),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Gap.gutter),
                child: _failure != null
                    ? _Failed(onRetry: () => unawaited(_load()))
                    : video == null || !video.value.isInitialized
                        ? const Center(child: BusySpinner(size: IconSize.lead))
                        : _Stage(video: video, onTap: () => _toggle(video)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The video, whole, with the pause and replay marks drawn only when it is
/// not playing: nothing moves over a playing clip.
class _Stage extends StatelessWidget {
  const _Stage({required this.video, required this.onTap});

  final VideoPlayerController video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: video,
      builder: (context, v, _) {
        final ended = v.isCompleted || (v.duration > Duration.zero && v.position >= v.duration);
        return Semantics(
          button: true,
          label: ended ? 'Play again' : (v.isPlaying ? 'Pause' : 'Play'),
          excludeSemantics: true,
          child: PressBuilder(
            onTap: onTap,
            builder: (context, _) => Center(
              child: AspectRatio(
                aspectRatio: v.aspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: Stack(fit: StackFit.expand, children: [
                    VideoPlayer(video),
                    if (!v.isPlaying)
                      Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: ds.inverseSurface, borderRadius: BorderRadius.circular(Radii.pill)),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.md, Gap.xs),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(ended ? LucideIcons.rotateCcw : LucideIcons.play, size: IconSize.inline, color: ds.onInverse),
                              const SizedBox(width: Gap.xs),
                              Text(ended ? 'Play again' : 'Play', style: Type.labelStrong.copyWith(color: ds.onInverse)),
                            ]),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(
          'Couldn\u2019t play the clip. Check the connection and try again.',
          textAlign: TextAlign.center,
          style: Type.secondary.copyWith(color: ds.dangerText),
        ),
        const SizedBox(height: Gap.md),
        AppButton(label: 'Retry', kind: AppButtonKind.secondary, onPressed: onRetry),
      ]),
    );
  }
}
