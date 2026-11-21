import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/i18n/app_localizations.dart';

class PublicVideoPlayer extends StatelessWidget {
  const PublicVideoPlayer({super.key, required this.url, required this.label});

  final Uri url;
  final String label;

  Future<void> _open(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Keep the copy-link action available when the OS cannot open a browser.
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.t('media.video_open_failed'))));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canOpen =
        (url.scheme == 'http' || url.scheme == 'https') &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty;
    return Tooltip(
      message: label,
      child: OutlinedButton.icon(
        onPressed: canOpen ? () => _open(context) : null,
        icon: const Icon(Icons.open_in_new),
        label: Text(l10n.t('media.open_video_in_browser')),
      ),
    );
  }
}
