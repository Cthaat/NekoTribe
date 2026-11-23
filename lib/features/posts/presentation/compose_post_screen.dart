import 'dart:async';
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
import '../../groups/presentation/group_detail_screen.dart';
import '../../media/data/media_api.dart';
import '../data/local_post_drafts.dart';
import '../data/posts_api.dart';
import '../domain/post_draft.dart';
import '../domain/post_draft_metadata.dart';
import '../domain/post_markdown.dart';
import '../domain/post_models.dart';
import '../domain/post_poll.dart';
import 'post_draft_actions.dart';
import 'post_draft_scope.dart';
import 'post_drafts_screen.dart';
import 'post_markdown_field.dart';
import 'post_poll_composer.dart';

class ComposePostScreen extends ConsumerStatefulWidget {
  const ComposePostScreen({
    super.key,
    this.replyToPostId,
    this.quotedPostId,
    this.initialDraft,
    this.cloudDraft,
  });

  final int? replyToPostId;
  final int? quotedPostId;
  final String? initialDraft;
  final ScopedPostDraft? cloudDraft;

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
  final _imageAltTexts = <int, String?>{};
  final _imageTags = <String>{};
  final _restoredMediaIds = <int>[];
  V2PostDraft? _cloud;
  V2PostDraftInput? _initialCloudInput;
  bool _draftWorking = false;
  bool _cloudExpired = false;
  CancelToken? _mediaUpload;
  CancelToken? _imageRequest;
  int? _imageMediaId;
  DialogRoute<_ImageDescriptionUpdate>? _imageDialog;
  String _visibility = 'public';
  String _markdown = '';
  bool _usingMarkdown = false;
  V2CreatePostPoll? _poll;
  bool _busy = false;
  bool _uploading = false;
  bool _deleting = false;
  bool _assistantApplied = false;
  bool _unmodifiedAssistantText = false;
  LocalPostDraftSession? _localDraft;
  String? _error;
  int _draftRevision = 0;
  late final VoidCallback _stopSessionListener;

  bool get _regularWorking =>
      _busy || _uploading || _deleting || _imageRequest != null;
  bool get _working => _regularWorking || _draftWorking;
  bool get _published => _cloud?.status == PostDraftStatus.published;
  bool get _editorLocked => _working || _published;
  bool get _public => _visibility == 'public';
  bool get _isStandalone =>
      widget.replyToPostId == null && widget.quotedPostId == null;
  bool get _usesLocalDraft =>
      _isStandalone && widget.initialDraft == null && widget.cloudDraft == null;

  @override
  void initState() {
    super.initState();
    final draft = widget.initialDraft;
    if (draft != null && draft.length <= 280) _controller.text = draft;
    final cloud = widget.cloudDraft;
    if (cloud != null) {
      _cloudExpired = !cloud.scope.isCurrent(ref);
      if (!_cloudExpired) _restoreCloudInput(cloud.draft);
    }
    final store = ref.read(tokenStoreProvider);
    var sessionRevision = store.revision;
    _stopSessionListener = store.listenSessionChanges(() {
      if (sessionRevision != store.revision) {
        sessionRevision = store.revision;
        _dropLocalDraft();
        _expireCloudDraft();
        _clearAssistantDraft();
        _clearMediaScope();
      }
      _openLocalDraft();
    });
    ref.listenManual(appConfigProvider, (_, _) {
      _dropLocalDraft();
      _expireCloudDraft();
      _clearAssistantDraft();
      _clearMediaScope();
      _openLocalDraft();
    });
    ref.listenManual(authSessionProvider, (_, next) {
      if (!next.loading && !next.isAuthenticated && _localDraft != null) {
        _dropLocalDraft();
        _expireCloudDraft();
        _clearAssistantDraft();
        _clearMediaScope();
      } else {
        _openLocalDraft();
      }
    });
    _openLocalDraft();
  }

  @override
  void didUpdateWidget(covariant ComposePostScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replyToPostId != widget.replyToPostId ||
        oldWidget.quotedPostId != widget.quotedPostId) {
      _dropLocalDraft();
      _clearMediaScope();
      _openLocalDraft();
    }
  }

  void _openLocalDraft() {
    if (!mounted || !_usesLocalDraft || _localDraft != null || _cloudExpired) {
      return;
    }
    final tokens = ref.read(tokenStoreProvider);
    final auth = ref.read(authSessionProvider);
    if (tokens.isSessionChanging || (!auth.loading && !auth.isAuthenticated)) {
      return;
    }
    final local = LocalPostDraftSession(
      storage: ref.read(localPostDraftStoreProvider),
      tokens: tokens,
      backend: ref.read(appConfigProvider).apiBaseUrl,
    );
    setState(() => _localDraft = local);
    if (_controller.text.isNotEmpty || _usingMarkdown) {
      local.preventRestore();
    } else {
      unawaited(_restoreLocalDraft(local));
    }
  }

  Future<void> _restoreLocalDraft(LocalPostDraftSession local) async {
    final saved = await local.restore();
    if (saved == null ||
        !mounted ||
        !identical(_localDraft, local) ||
        !local.canRestore) {
      return;
    }
    local.acceptRestored(saved);
    setState(() {
      _usingMarkdown = saved.markdown;
      if (saved.markdown) {
        _markdown = saved.text;
      } else {
        _controller.text = saved.text;
      }
    });
  }

  void _dropLocalDraft() {
    if (_localDraft == null) return;
    _localDraft?.invalidate();
    _localDraft = null;
    _controller.clear();
    _unmodifiedAssistantText = false;
  }

  void _cacheLocalText() {
    _unmodifiedAssistantText = false;
    _localDraft?.update((
      text: _usingMarkdown ? _markdown : _controller.text,
      markdown: _usingMarkdown,
    ));
  }

  Future<void> _discardLocalDraft() async {
    final local = _localDraft;
    if (local == null || _editorLocked) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmDraftAction(
      context,
      'draft.discard_local',
      l10n.t('draft.confirm_discard_local'),
    );
    if (!confirmed || !mounted || !identical(_localDraft, local)) return;
    setState(() {
      _controller.clear();
      _markdown = '';
      _usingMarkdown = false;
      _unmodifiedAssistantText = false;
    });
    final cleared = await local.discard();
    if (!cleared && mounted && identical(_localDraft, local)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('draft.discard_local_error'))),
      );
    }
  }

  void _clearMediaScope() {
    if (!mounted) return;
    _mediaUpload?.cancel();
    _mediaUpload = null;
    _cancelImageDescription();
    setState(() {
      _draftRevision++;
      _media.clear();
      _restoredMediaIds.clear();
      _privatePreviews.clear();
      _imageAltTexts.clear();
      _imageTags.clear();
      _imageMediaId = null;
      _poll = null;
      _markdown = '';
      _usingMarkdown = false;
      _busy = _uploading = _deleting = false;
      _draftWorking = false;
      _error = null;
    });
  }

  void _expireCloudDraft() {
    if (_cloud == null && widget.cloudDraft == null && !_draftWorking) return;
    _controller.clear();
    _locationController.clear();
    _tagController.clear();
    _initialCloudInput = null;
    _cloud = null;
    _cloudExpired = true;
  }

  void _restoreCloudInput(V2PostDraft draft) {
    final input = draft.payload;
    _cloud = draft;
    _initialCloudInput = input;
    _controller.text = input.content;
    _usingMarkdown = input.markdown != null;
    _markdown = input.markdown ?? '';
    _visibility = input.visibility;
    _locationController.text = input.location;
    _tagController.text = input.tags.join(', ');
    _restoredMediaIds.addAll(input.mediaIds);
    _poll = input.poll;
  }

  List<int> _mediaIds() => [
    ..._restoredMediaIds,
    ..._media.map((item) => item.mediaId),
  ];

  V2PostDraftInput _readCloudInput() {
    final previous = _initialCloudInput;
    final oldTags = previous?.tags ?? [];
    return V2PostDraftInput(
      content: _usingMarkdown && isValidPostMarkdown(_markdown)
          ? previous?.markdown == _markdown
              ? previous!.content
              : postMarkdownExcerpt(_markdown)
          : _controller.text,
      markdown: _usingMarkdown ? _markdown : null,
      visibility: _visibility,
      location: _locationController.text,
      tags: previous != null &&
              _tagController.text == oldTags.join(', ') &&
              _imageTags.isEmpty
          ? oldTags
          : _tagNames(),
      mentionUserIds: previous?.mentionUserIds ?? [],
      mediaIds: _mediaIds(),
      poll: _poll,
    );
  }

  void _setMarkdownMode(bool value) {
    setState(() {
      if (value && _markdown.isEmpty) _markdown = _controller.text;
      if (!value && _controller.text.isEmpty && isValidPostMarkdown(_markdown)) {
        _controller.text = postMarkdownExcerpt(_markdown);
      }
      _usingMarkdown = value;
      _error = null;
    });
    _cacheLocalText();
  }

  Future<void> _openCloudDrafts() async {
    if (_working || !requireAuthenticatedAction(context, ref)) return;
    final store = ref.read(tokenStoreProvider);
    if (store.isSessionChanging) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PostDraftsScreen(
          openEditor: (context, draft) async {
            await Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => draft.draft.payload.groupId == null
                    ? ComposePostScreen(cloudDraft: draft)
                    : GroupDetailScreen.resumeDraft(resumeDraft: draft),
              ),
            );
          },
        ),
      ),
    );
  }

  bool _isCurrent(int revision) => mounted && revision == _draftRevision;

  void _clearAssistantDraft() {
    if (widget.initialDraft != null || _assistantApplied) _controller.clear();
    _assistantApplied = false;
  }

  @override
  void dispose() {
    _mediaUpload?.cancel();
    _cancelImageDescription();
    _stopSessionListener();
    _controller.dispose();
    _locationController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  void _cancelImageDescription() {
    _imageRequest?.cancel();
    _imageRequest = null;
    final dialog = _imageDialog;
    _imageDialog = null;
    if (dialog != null) {
      scheduleMicrotask(() {
        if (dialog.isActive) dialog.navigator?.removeRoute(dialog);
      });
    }
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
      if (_mediaIds().length + result.files.length > _maxMedia) {
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
      if (!(_cloud?.payload.mediaIds.contains(asset.mediaId) ?? false)) {
        await ref.read(mediaApiProvider).deleteMedia(asset.mediaId);
      }
      if (!_isCurrent(revision)) return;
      setState(() {
        _media.remove(asset);
        _privatePreviews.remove(asset);
        _imageAltTexts.remove(asset.mediaId);
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

  Future<void> _describeImage(V2MediaAsset asset) async {
    if (_working ||
        !MediaApi.canDescribe(asset) ||
        !requireAuthenticatedAction(context, ref)) {
      return;
    }
    final store = ref.read(tokenStoreProvider);
    if (store.isSessionChanging) return;
    final revision = _draftRevision;
    final session = store.revision;
    final cancel = CancelToken();
    final api = ref.read(mediaApiProvider);
    final language = AppLocalizations.of(context).locale.languageCode;
    bool current() =>
        _isCurrent(revision) &&
        !store.isSessionChanging &&
        store.revision == session &&
        !cancel.isCancelled &&
        _media.contains(asset);

    setState(() {
      _imageRequest = cancel;
      _imageMediaId = asset.mediaId;
      _error = null;
    });
    try {
      final suggestion = await api.describeImage(
        asset.mediaId,
        locale: language == 'en' ? 'en' : 'zh',
        cancelToken: cancel,
      );
      if (!current()) return;
      final existing = _tagNames().map((tag) => tag.toLowerCase()).toSet();
      final capacity = maxDraftTags - existing.length;
      final topics = suggestion.tags
          .where((tag) => existing.add(tag.toLowerCase()))
          .toList();
      final navigator = Navigator.of(context, rootNavigator: true);
      final dialog = DialogRoute<_ImageDescriptionUpdate>(
        context: context,
        builder: (_) => _ImageDescriptionDialog(
          altText: suggestion.altText,
          topics: topics,
          maxTopics: capacity,
        ),
      );
      _imageDialog = dialog;
      setState(() => _imageMediaId = null);
      final update = await navigator.push(dialog);
      if (identical(_imageDialog, dialog)) _imageDialog = null;
      if (!current() || update == null) return;
      setState(() => _imageMediaId = asset.mediaId);
      final saved = await api.updateAltText(
        asset.mediaId,
        update.altText,
        cancelToken: cancel,
      );
      if (!current()) return;
      setState(() {
        _imageAltTexts[asset.mediaId] = saved;
        _imageTags.addAll(update.tags);
      });
    } catch (error) {
      if (!current()) return;
      setState(() => _error = ErrorView.describe(context, error));
    } finally {
      if (current()) {
        setState(() {
          _imageRequest = null;
          _imageMediaId = null;
        });
      }
    }
  }

  Future<void> _publish() async {
    if (_working || _cloud != null || _cloudExpired) return;
    final markdown = _usingMarkdown ? _markdown : null;
    if (markdown != null && !isValidPostMarkdown(markdown)) {
      setState(() => _error = AppLocalizations.of(context).t('post.markdown.invalid'));
      return;
    }
    final content = markdown == null
        ? _controller.text.trim()
        : postMarkdownExcerpt(markdown);
    if (content.isEmpty && _media.isEmpty) return;
    final poll = _poll;
    if (poll != null && !poll.isValid) {
      setState(() {
        _error = AppLocalizations.of(context).t(
          poll.hasValidOptions
              ? 'poll.invalid_deadline'
              : 'poll.invalid_options',
        );
      });
      return;
    }
    if (!requireAuthenticatedAction(context, ref)) return;
    if (ref.read(tokenStoreProvider).isSessionChanging) return;
    final revision = _draftRevision;
    final local = _localDraft;
    final publishedLocal = _unmodifiedAssistantText ? null : local?.snapshot;
    local?.preventRestore();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final post = await ref
          .read(postsApiProvider)
          .createPost(
            content: content,
            visibility: _visibility,
            replyToPostId: widget.replyToPostId,
            quotedPostId: widget.quotedPostId,
            mediaIds: _mediaIds(),
            location: _locationController.text.trim().isEmpty
                ? null
                : _locationController.text.trim(),
            tags: _tagNames(),
            poll: poll,
            markdown: markdown,
          );
      unawaited(local?.clearPublished(publishedLocal));
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
    _localDraft?.preventRestore();
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
    if (!current() ||
        result == null ||
        result.trim().isEmpty ||
        result.length > 280) {
      return;
    }
    _assistantApplied = true;
    _unmodifiedAssistantText = true;
    _controller.value = TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: result.length),
    );
  }

  bool _canSelectVisibility(String value) =>
      _mediaIds().isEmpty || (value == 'public') == _public;

  String? _altTextFor(V2MediaAsset asset) =>
      _imageAltTexts.containsKey(asset.mediaId)
      ? _imageAltTexts[asset.mediaId]
      : asset.altText;

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
              semanticLabel: _altTextFor(asset),
              errorBuilder: (_, _, _) => placeholder,
            );
    }
    return Image.network(
      ref.read(assetUrlResolverProvider).resolve(asset.publicUrl),
      fit: BoxFit.cover,
      semanticLabel: _altTextFor(asset),
      errorBuilder: (_, _, _) => placeholder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_cloudExpired) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.t('draft.title'))),
        body: EmptyView(message: l10n.t('visibility.sessionChanged')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('compose.publish')),
        actions: [
          if (_isStandalone && widget.cloudDraft == null)
            IconButton(
              tooltip: l10n.t('draft.title'),
              onPressed: _working ? null : _openCloudDrafts,
              icon: const Icon(Icons.cloud_outlined),
            ),
          if (_localDraft != null)
            IconButton(
              key: const Key('post-local-draft-discard'),
              tooltip: l10n.t('draft.discard_local'),
              onPressed: _editorLocked ? null : _discardLocalDraft,
              icon: const Icon(Icons.delete_outline),
            ),
          if (_cloud == null) Padding(
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
                if (_isStandalone)
                  PostMarkdownToggle(
                    selected: _usingMarkdown,
                    onChanged: _editorLocked ? null : _setMarkdownMode,
                  ),
                if (_usingMarkdown)
                  PostMarkdownField(
                    value: _markdown,
                    onChanged: _editorLocked
                        ? null
                        : (value) {
                            setState(() {
                              _markdown = value;
                              _error = null;
                            });
                            _cacheLocalText();
                          },
                  )
                else TextField(
                  key: const Key('compose-content-field'),
                  controller: _controller,
                  onChanged: (_) => _cacheLocalText(),
                  readOnly: _imageRequest != null || _draftWorking || _published,
                  maxLines: 8,
                  minLines: 5,
                  maxLength: widget.cloudDraft == null ? 280 : null,
                  decoration: InputDecoration(
                    hintText: l10n.t('compose.placeholder'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('compose-location-field'),
                  controller: _locationController,
                  readOnly: _draftWorking || _published,
                  maxLength: widget.cloudDraft == null ? 60 : null,
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
                  readOnly: _imageRequest != null || _draftWorking || _published,
                  maxLength: widget.cloudDraft == null ? 120 : null,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: l10n.t('compose.tags'),
                    hintText: l10n.t('compose.tags_hint'),
                    prefixIcon: const Icon(Icons.tag_outlined),
                  ),
                ),
                if (_imageTags.isNotEmpty)
                  ListenableBuilder(
                    listenable: Listenable.merge([_controller, _tagController]),
                    builder: (context, _) {
                      final applied = _tagNames().toSet();
                      return Wrap(
                        spacing: 8,
                        children: [
                          for (final tag in _imageTags)
                            InputChip(
                              label: Text('#$tag'),
                              selected: applied.contains(tag),
                              showCheckmark: false,
                              onDeleted: _editorLocked
                                  ? null
                                  : () =>
                                        setState(() => _imageTags.remove(tag)),
                            ),
                        ],
                      );
                    },
                  ),
                if (_restoredMediaIds.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final id in _restoredMediaIds)
                        InputChip(
                          label: Text(l10n.t('draft.attachment').replaceFirst('{id}', '$id')),
                          onDeleted: _editorLocked
                              ? null
                              : () => setState(() => _restoredMediaIds.remove(id)),
                        ),
                    ],
                  ),
                if (_media.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: _media.any((asset) => _altTextFor(asset) != null)
                        ? 124
                        : 100,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _media.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (_, i) {
                        final asset = _media[i];
                        return _mediaTile(asset, theme, l10n);
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    IconButton(
                      onPressed: _editorLocked || _mediaIds().length >= _maxMedia
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
                      onPressed: _editorLocked || _mediaIds().length >= _maxMedia
                          ? null
                          : () => _pickMedia(FileType.video),
                      tooltip: l10n.t('compose.video'),
                      icon: Icon(
                        Icons.video_file_outlined,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    IconButton(
                      onPressed: _editorLocked || _usingMarkdown
                          ? null
                          : _openWritingAssistant,
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
                      onChanged: _editorLocked
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
                if (_mediaIds().isNotEmpty)
                  Text(
                    l10n.t('compose.media_visibility_locked'),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall,
                  ),
                if (_isStandalone)
                  PostPollComposer(
                    key: ValueKey(_draftRevision),
                    initial: _initialCloudInput?.poll,
                    enabled: !_editorLocked,
                    onChanged: (poll) => setState(() {
                      _poll = poll;
                      _error = null;
                    }),
                  ),
                if (_isStandalone)
                  PostDraftActions(
                    key: ValueKey(('cloud', _draftRevision)),
                    initial: widget.cloudDraft,
                    readInput: _readCloudInput,
                    enabled: !_regularWorking,
                    onWorkingChanged: (working) =>
                        setState(() => _draftWorking = working),
                    onChanged: (draft) {
                      setState(() => _cloud = draft);
                      final local = _localDraft;
                      if (draft.status == PostDraftStatus.published &&
                          local != null && !_unmodifiedAssistantText) {
                        unawaited(local.clearPublished(local.snapshot));
                      }
                    },
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
    return draftTagNames(
      content: _usingMarkdown && isValidPostMarkdown(_markdown)
          ? postMarkdownExcerpt(_markdown)
          : _controller.text,
      tags: _tagController.text,
      imageTags: _imageTags,
    );
  }

  Widget _mediaTile(
    V2MediaAsset asset,
    ThemeData theme,
    AppLocalizations l10n,
  ) {
    final describing = _imageMediaId == asset.mediaId;
    final altText = _altTextFor(asset);
    return SizedBox(
      width: 100,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 100,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _mediaPreview(asset, theme),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: InkWell(
                    key: ValueKey('compose-remove-media-${asset.mediaId}'),
                    onTap: _editorLocked ? null : () => _removeMedia(asset),
                    customBorder: const CircleBorder(),
                    child: const CircleAvatar(
                      radius: 12,
                      backgroundColor: Colors.black54,
                      child: Icon(Icons.close, size: 14, color: Colors.white),
                    ),
                  ),
                ),
                if (MediaApi.canDescribe(asset))
                  Positioned(
                    bottom: 4,
                    left: 4,
                    child: IconButton.filledTonal(
                      onPressed: _editorLocked ? null : () => _describeImage(asset),
                      tooltip: l10n.t('compose.image_description'),
                      icon: describing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome_outlined),
                    ),
                  ),
              ],
            ),
          ),
          if (altText != null)
            Flexible(
              child: Tooltip(
                message: altText,
                child: Text(
                  altText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

typedef _ImageDescriptionUpdate = ({String altText, List<String> tags});

class _ImageDescriptionDialog extends StatefulWidget {
  const _ImageDescriptionDialog({
    required this.altText,
    required this.topics,
    required this.maxTopics,
  });

  final String altText;
  final List<String> topics;
  final int maxTopics;

  @override
  State<_ImageDescriptionDialog> createState() =>
      _ImageDescriptionDialogState();
}

class _ImageDescriptionDialogState extends State<_ImageDescriptionDialog> {
  late String _altText = widget.altText;
  late final Set<String> _selected = widget.topics
      .take(widget.maxTopics)
      .toSet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final valid = MediaApi.validAltText(_altText);
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.t('compose.image_suggestions')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            initialValue: widget.altText,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: l10n.t('compose.image_alt_text'),
              errorText: valid ? null : l10n.t('compose.image_alt_invalid'),
            ),
            onChanged: (value) => setState(() => _altText = value),
          ),
          if (widget.topics.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(l10n.t('compose.image_topics')),
            if (widget.topics.length > widget.maxTopics)
              Text(
                l10n
                    .t('compose.image_topics_limit')
                    .replaceAll('{count}', '${widget.maxTopics}'),
              ),
            Wrap(
              spacing: 8,
              children: [
                for (final topic in widget.topics)
                  FilterChip(
                    label: Text('#$topic'),
                    selected: _selected.contains(topic),
                    onSelected:
                        _selected.contains(topic) ||
                            _selected.length < widget.maxTopics
                        ? (selected) => setState(() {
                            if (selected) {
                              _selected.add(topic);
                            } else {
                              _selected.remove(topic);
                            }
                          })
                        : null,
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.t('common.cancel')),
        ),
        FilledButton(
          onPressed: valid
              ? () => Navigator.of(
                  context,
                ).pop((altText: _altText, tags: _selected.toList()))
              : null,
          child: Text(l10n.t('compose.image_apply')),
        ),
      ],
    );
  }
}
