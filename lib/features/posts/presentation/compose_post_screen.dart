import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../ai/presentation/ai_writing_screen.dart';
import '../data/posts_api.dart';
import '../domain/post_draft_metadata.dart';
import '../domain/post_models.dart';

class ComposePostScreen extends ConsumerStatefulWidget {
  const ComposePostScreen({
    super.key,
    this.replyToPostId,
    this.quotedPostId,
    this.initialDraft,
  });

  final int? replyToPostId;
  final int? quotedPostId;
  final String? initialDraft;

  @override
  ConsumerState<ComposePostScreen> createState() => _ComposePostScreenState();
}

class _ComposePostScreenState extends ConsumerState<ComposePostScreen> {
  static const _maxMedia = 4;
  static const _maxMediaBytes = 500 * 1024 * 1024;
  final _controller = TextEditingController();
  final _locationController = TextEditingController();
  final _tagController = TextEditingController();
  final List<V2MediaAsset> _media = [];
  final _privatePreviews = <V2MediaAsset, Uint8List>{};
  CancelToken? _mediaUpload;
  String _visibility = 'public';
  bool _busy = false;
  bool _uploading = false;
  bool _deleting = false;
  bool _assistantApplied = false;
  String? _error;
  int _draftRevision = 0;
  late final VoidCallback _stopSessionListener;

  bool get _working => _busy || _uploading || _deleting;
  bool get _public => _visibility == 'public';

  @override
  void initState() {
    super.initState();
    final draft = widget.initialDraft;
    if (draft != null && draft.length <= 280) _controller.text = draft;
    final store = ref.read(tokenStoreProvider);
    var sessionRevision = store.revision;
    _stopSessionListener = store.listenSessionChanges(() {
      if (sessionRevision == store.revision) return;
      sessionRevision = store.revision;
      _clearAssistantDraft();
      _clearMediaScope();
    });
    ref.listenManual(appConfigProvider, (_, _) {
      _clearAssistantDraft();
      _clearMediaScope();
    });
  }

  @override
  void didUpdateWidget(covariant ComposePostScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replyToPostId != widget.replyToPostId ||
        oldWidget.quotedPostId != widget.quotedPostId) {
      _clearMediaScope();
    }
  }

  void _clearMediaScope() {
    if (!mounted) return;
    _mediaUpload?.cancel();
    _mediaUpload = null;
    setState(() {
      _draftRevision++;
      _media.clear();
      _privatePreviews.clear();
      _busy = _uploading = _deleting = false;
      _error = null;
    });
  }

  bool _isCurrent(int revision) => mounted && revision == _draftRevision;

  void _clearAssistantDraft() {
    if (widget.initialDraft != null || _assistantApplied) _controller.clear();
    _assistantApplied = false;
  }

  @override
  void dispose() {
    _mediaUpload?.cancel();
    _stopSessionListener();
    _controller.dispose();
    _locationController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _pickMedia(FileType type) async {
    if (_working || !requireAuthenticatedAction(context, ref)) return;
    if (ref.read(tokenStoreProvider).isSessionChanging) return;
    final revision = _draftRevision;
    final scope = _public ? null : 'post';
    final isVideo = type == FileType.video;
    final mediaType = isVideo ? 'video' : 'image';
    final cancel = CancelToken();
    _mediaUpload = cancel;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: type,
        allowMultiple: true,
        withData: !isVideo,
        withReadStream: isVideo && kIsWeb,
      );
      if (!_isCurrent(revision) || result == null) return;
      if (_media.length + result.files.length > _maxMedia) {
        setState(
          () => _error = AppLocalizations.of(context).t('compose.media_limit'),
        );
        return;
      }
      if (result.files.any((file) => file.size > _maxMediaBytes)) {
        setState(
          () => _error = AppLocalizations.of(context).t('compose.media_size'),
        );
        return;
      }
      final api = ref.read(mediaApiProvider);
      for (final f in result.files) {
        final V2MediaAsset asset;
        final stream = f.readStream;
        if (f.bytes != null) {
          asset = await api.uploadBytes(
            bytes: f.bytes!,
            fileName: f.name,
            mediaType: mediaType,
            accessScope: scope,
            cancelToken: cancel,
          );
        } else if (stream != null) {
          asset = await api.uploadStream(
            chunks: stream,
            length: f.size,
            fileName: f.name,
            mediaType: mediaType,
            accessScope: scope,
            cancelToken: cancel,
          );
        } else if (!kIsWeb && f.path != null) {
          asset = await api.uploadFile(
            file: File(f.path!),
            mediaType: mediaType,
            accessScope: scope,
            cancelToken: cancel,
          );
        } else {
          continue;
        }
        if (!_isCurrent(revision)) return;
        setState(() {
          _media.add(asset);
          if (scope != null && !isVideo && f.bytes != null) {
            _privatePreviews[asset] = f.bytes!;
          }
        });
      }
    } catch (e) {
      if (!_isCurrent(revision)) return;
      setState(() {
        _error = e is ApiException && e.statusCode == 401
            ? AppLocalizations.of(context).t('compose.media_retry')
            : ErrorView.describe(context, e);
      });
    } finally {
      if (_isCurrent(revision)) {
        _mediaUpload = null;
        setState(() => _uploading = false);
      }
    }
  }

  Future<void> _removeMedia(V2MediaAsset asset) async {
    if (_working || !requireAuthenticatedAction(context, ref)) return;
    final revision = _draftRevision;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await ref.read(mediaApiProvider).deleteMedia(asset.mediaId);
      if (!_isCurrent(revision)) return;
      setState(() {
        _media.remove(asset);
        _privatePreviews.remove(asset);
      });
    } catch (error) {
      if (!_isCurrent(revision)) return;
      setState(() {
        _error = error is ApiException && error.statusCode == 409
            ? AppLocalizations.of(context).t('compose.media_in_use')
            : ErrorView.describe(context, error);
      });
    } finally {
      if (_isCurrent(revision)) setState(() => _deleting = false);
    }
  }

  Future<void> _publish() async {
    if (_working) return;
    if (_controller.text.trim().isEmpty && _media.isEmpty) return;
    if (!requireAuthenticatedAction(context, ref)) return;
    if (ref.read(tokenStoreProvider).isSessionChanging) return;
    final revision = _draftRevision;
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
            location: _locationController.text.trim().isEmpty
                ? null
                : _locationController.text.trim(),
            tags: _tagNames(),
          );
      if (!_isCurrent(revision)) return;
      Navigator.of(context).pop(post);
    } catch (e) {
      if (!_isCurrent(revision)) return;
      setState(() {
        _error = e is UnconfirmedPostError
            ? AppLocalizations.of(context).t('compose.publish_unconfirmed')
            : ErrorView.describe(context, e);
      });
    } finally {
      if (_isCurrent(revision)) setState(() => _busy = false);
    }
  }

  Future<void> _openWritingAssistant() async {
    if (_working || !requireAuthenticatedAction(context, ref)) return;
    final store = ref.read(tokenStoreProvider);
    if (store.isSessionChanging) return;
    final revision = _draftRevision;
    final session = store.revision;
    final source = _controller.text;
    bool current() =>
        _isCurrent(revision) &&
        !store.isSessionChanging &&
        store.revision == session &&
        _controller.text == source;
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => AiWritingScreen(composerDraft: current() ? source : ''),
      ),
    );
    if (!current() || result == null || result.trim().isEmpty || result.length > 280) {
      return;
    }
    _assistantApplied = true;
    _controller.value = TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
  }

  bool _canSelectVisibility(String value) =>
      _media.isEmpty || (value == 'public') == _public;

  Widget _mediaPreview(V2MediaAsset asset, ThemeData theme) {
    if (asset.isVideo) {
      return Tooltip(
        message: asset.fileName,
        child: ColoredBox(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Icon(
            asset.usesContentRoute ? Icons.lock_outline : Icons.movie_outlined,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final placeholder = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        asset.usesContentRoute
            ? Icons.lock_outline
            : Icons.broken_image_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    if (asset.usesContentRoute) {
      final bytes = _privatePreviews[asset];
      return bytes == null
          ? placeholder
          : Image.memory(
              bytes,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => placeholder,
            );
    }
    return Image.network(
      ref.read(assetUrlResolverProvider).resolve(asset.publicUrl),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => placeholder,
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
              onPressed: _working ? null : _publish,
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
                  key: const Key('compose-content-field'),
                  controller: _controller,
                  maxLines: 8,
                  minLines: 5,
                  maxLength: 280,
                  decoration: InputDecoration(
                    hintText: l10n.t('compose.placeholder'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('compose-location-field'),
                  controller: _locationController,
                  maxLength: 60,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.t('compose.location'),
                    hintText: l10n.t('compose.location_hint'),
                    prefixIcon: const Icon(Icons.location_on_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('compose-tags-field'),
                  controller: _tagController,
                  maxLength: 120,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: l10n.t('compose.tags'),
                    hintText: l10n.t('compose.tags_hint'),
                    prefixIcon: const Icon(Icons.tag_outlined),
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
                                child: _mediaPreview(asset, theme),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: InkWell(
                                key: ValueKey(
                                  'compose-remove-media-${asset.mediaId}',
                                ),
                                onTap: _working
                                    ? null
                                    : () => _removeMedia(asset),
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
                      onPressed: _working || _media.length >= _maxMedia
                          ? null
                          : () => _pickMedia(FileType.image),
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
                      onPressed: _working || _media.length >= _maxMedia
                          ? null
                          : () => _pickMedia(FileType.video),
                      tooltip: l10n.t('compose.video'),
                      icon: Icon(
                        Icons.video_file_outlined,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    IconButton(
                      onPressed: _working ? null : _openWritingAssistant,
                      tooltip: l10n.t('ai.writing.title'),
                      icon: Icon(
                        Icons.psychology_alt_outlined,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _public ? Icons.public : Icons.lock_outline,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    DropdownButton<String>(
                      key: const Key('compose-visibility-field'),
                      value: _visibility,
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      onChanged: _working
                          ? null
                          : (value) {
                              if (value != null &&
                                  _canSelectVisibility(value)) {
                                setState(() => _visibility = value);
                              }
                            },
                      items: [
                        DropdownMenuItem(
                          value: 'public',
                          enabled: _canSelectVisibility('public'),
                          child: Text(l10n.t('common.public')),
                        ),
                        DropdownMenuItem(
                          value: 'followers',
                          enabled: _canSelectVisibility('followers'),
                          child: Text(l10n.t('common.followers_only')),
                        ),
                        DropdownMenuItem(
                          value: 'mentioned',
                          enabled: _canSelectVisibility('mentioned'),
                          child: Text(l10n.t('common.mentioned_only')),
                        ),
                        DropdownMenuItem(
                          value: 'private',
                          enabled: _canSelectVisibility('private'),
                          child: Text(l10n.t('common.private')),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_media.isNotEmpty)
                  Text(
                    l10n.t('compose.media_visibility_locked'),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall,
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

  List<String> _tagNames() {
    return draftTagNames(content: _controller.text, tags: _tagController.text);
  }
}
