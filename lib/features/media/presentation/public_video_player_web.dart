import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../../../shared/i18n/app_localizations.dart';

class PublicVideoPlayer extends StatefulWidget {
  const PublicVideoPlayer({super.key, required this.url, required this.label});

  final Uri url;
  final String label;

  @override
  State<PublicVideoPlayer> createState() => _PublicVideoPlayerState();
}

class _PublicVideoPlayerState extends State<PublicVideoPlayer> {
  web.HTMLVideoElement? _video;
  bool _expanded = false;
  int _viewGeneration = 0;

  void _createVideo(Object element, int generation) {
    if (!mounted || !_expanded || _viewGeneration != generation) return;
    final video = element as web.HTMLVideoElement;
    video
      ..controls = true
      ..playsInline = true
      ..preload = 'none'
      ..setAttribute('aria-label', widget.label);
    video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'contain'
      ..backgroundColor = 'black';
    video.src = widget.url.toString();
    _video = video;
  }

  void _releaseVideo() {
    final video = _video;
    _video = null;
    video
      ?..pause()
      ..removeAttribute('src')
      ..load();
  }

  @override
  void didUpdateWidget(covariant PublicVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _viewGeneration++;
      _releaseVideo();
      _expanded = false;
    } else if (oldWidget.label != widget.label) {
      _video?.setAttribute('aria-label', widget.label);
    }
  }

  @override
  void dispose() {
    _releaseVideo();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final generation = _viewGeneration;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: () {
            if (_expanded) _releaseVideo();
            setState(() {
              _viewGeneration++;
              _expanded = !_expanded;
            });
          },
          icon: Icon(_expanded ? Icons.expand_less : Icons.play_circle_outline),
          label: Text(
            l10n.t(_expanded ? 'media.close_video' : 'media.open_video'),
          ),
        ),
        if (_expanded)
          AspectRatio(
            aspectRatio: 16 / 9,
            child: HtmlElementView.fromTagName(
              tagName: 'video',
              onElementCreated: (element) => _createVideo(element, generation),
            ),
          ),
      ],
    );
  }
}
