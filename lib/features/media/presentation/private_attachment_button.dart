import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../posts/domain/post_models.dart';
import 'save_attachment_native.dart'
    if (dart.library.js_interop) 'save_attachment_web.dart';

class PrivateAttachmentButton extends ConsumerStatefulWidget {
  const PrivateAttachmentButton({super.key, required this.asset});

  final V2MediaAsset asset;

  @override
  ConsumerState<PrivateAttachmentButton> createState() =>
      _PrivateAttachmentButtonState();
}

class _PrivateAttachmentButtonState
    extends ConsumerState<PrivateAttachmentButton> {
  CancelToken? _download;
  late final VoidCallback _stopSessionListener;

  @override
  void initState() {
    super.initState();
    _stopSessionListener = ref
        .read(tokenStoreProvider)
        .listenSessionChanges(_cancel);
    ref.listenManual(mediaApiProvider, (_, _) => _cancel());
  }

  @override
  void didUpdateWidget(covariant PrivateAttachmentButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.privateContentPath != widget.asset.privateContentPath) {
      _cancel();
    }
  }

  void _cancel() {
    final download = _download;
    if (download == null) return;
    download.cancel();
    setState(() => _download = null);
  }

  @override
  void dispose() {
    _stopSessionListener();
    _download?.cancel();
    super.dispose();
  }

  Future<void> _save() async {
    if (_download != null || !requireAuthenticatedAction(context, ref)) return;
    final asset = widget.asset;
    final tokens = ref.read(tokenStoreProvider);
    if (asset.privateContentPath == null || tokens.isSessionChanging) return;
    final api = ref.read(mediaApiProvider);
    final cancel = CancelToken();
    bool isCurrent() => mounted && identical(_download, cancel);
    setState(() => _download = cancel);
    try {
      final safeName = asset.fileName
          .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
          .replaceFirst(RegExp(r'[. ]+$'), '');
      await saveAttachment(
        safeName.isEmpty ? 'attachment-${asset.mediaId}' : safeName,
        readBytes: () => api.downloadPrivate(asset, cancelToken: cancel),
        readParts: () => api.downloadPrivateParts(asset, cancelToken: cancel),
        isCurrent: isCurrent,
      );
    } catch (_) {
      if (!isCurrent()) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('media.download_failed'))));
    } finally {
      if (isCurrent()) setState(() => _download = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fileName = widget.asset.fileName;
    final downloading = _download != null;
    final action = l10n.t(
      downloading ? 'media.cancel_download' : 'media.download',
    );
    return Tooltip(
      message: action,
      child: OutlinedButton.icon(
        onPressed: downloading
            ? _cancel
            : widget.asset.privateContentPath != null
            ? _save
            : null,
        icon: !downloading
            ? const Icon(Icons.download_outlined)
            : const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
        label: Text(
          downloading || fileName.isEmpty ? action : fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
