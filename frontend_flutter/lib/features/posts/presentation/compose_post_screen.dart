import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../sentiment_flow/presentation/sentiment_prediction_dialog.dart';
import '../domain/post_models.dart';

class ComposePostScreen extends ConsumerStatefulWidget {
  const ComposePostScreen({super.key, this.replyToPostId, this.quotedPostId});

  final int? replyToPostId;
  final int? quotedPostId;

  @override
  ConsumerState<ComposePostScreen> createState() => _ComposePostScreenState();
}

class _ComposePostScreenState extends ConsumerState<ComposePostScreen> {
  final _controller = TextEditingController();
  final List<V2MediaAsset> _media = [];
  String _visibility = 'public';
  bool _busy = false;
  bool _uploading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickMedia() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    setState(() => _uploading = true);
    final api = ref.read(mediaApiProvider);
    try {
      for (final f in result.files) {
        if (f.bytes != null) {
          final asset = await api.uploadBytes(
            bytes: f.bytes!,
            fileName: f.name,
            mediaType: 'image',
          );
          _media.add(asset);
        } else if (f.path != null) {
          final asset = await api.uploadFile(
            file: File(f.path!),
            mediaType: 'image',
          );
          _media.add(asset);
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _publish() async {
    if (_controller.text.trim().isEmpty && _media.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final post = await ref
          .read(postsApiProvider)
          .createPost(
            content: _controller.text.trim(),
            visibility: _visibility,
            replyToPostId: widget.replyToPostId,
            quotedPostId: widget.quotedPostId,
            mediaIds: _media.map((m) => m.mediaId).toList(),
          );
      if (!mounted) return;
      Navigator.of(context).pop(post);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _analyzeSentiment() async {
    if (!requireAuthenticatedAction(context, ref)) return;
    await showSentimentPredictionDialog(
      context: context,
      text: _controller.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('compose.publish')),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: FilledButton(
              onPressed: _busy ? null : _publish,
              child: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.t('compose.publish')),
            ),
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _controller,
                  maxLines: 8,
                  minLines: 5,
                  maxLength: 2000,
                  decoration: InputDecoration(
                    hintText: l10n.t('compose.placeholder'),
                  ),
                ),
                if (_media.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 100,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _media.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final asset = _media[i];
                        return Stack(
                          children: [
                            SizedBox(
                              width: 100,
                              height: 100,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.network(
                                  ref
                                      .read(assetUrlResolverProvider)
                                      .resolve(asset.publicUrl),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => ColoredBox(
                                    color: theme.colorScheme.surfaceContainerHighest,
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: InkWell(
                                onTap: () =>
                                    setState(() => _media.removeAt(i)),
                                customBorder: const CircleBorder(),
                                child: const CircleAvatar(
                                  radius: 12,
                                  backgroundColor: Colors.black54,
                                  child: Icon(
                                    Icons.close,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton(
                      onPressed: _uploading ? null : _pickMedia,
                      tooltip: l10n.t('compose.media'),
                      icon: _uploading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.photo_outlined,
                              color: theme.colorScheme.primary,
                            ),
                    ),
                    IconButton(
                      onPressed: _busy ? null : _analyzeSentiment,
                      tooltip: l10n.t('sentiment.actions.predict'),
                      icon: Icon(
                        Icons.psychology_alt_outlined,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.public,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    DropdownButton<String>(
                      value: _visibility,
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      onChanged: (v) =>
                          setState(() => _visibility = v ?? 'public'),
                      items: [
                        DropdownMenuItem(
                          value: 'public',
                          child: Text(l10n.t('common.public')),
                        ),
                        DropdownMenuItem(
                          value: 'followers',
                          child: Text(l10n.t('common.followers_only')),
                        ),
                        DropdownMenuItem(
                          value: 'private',
                          child: Text(l10n.t('common.private')),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 18,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
