import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../data/posts_api.dart';
import '../domain/post_draft_metadata.dart';
import '../domain/post_models.dart';

class EditPostScreen extends ConsumerStatefulWidget {
  const EditPostScreen({super.key, required this.postId});

  final int postId;

  @override
  ConsumerState<EditPostScreen> createState() => _EditPostScreenState();
}

class _EditPostScreenState extends ConsumerState<EditPostScreen> {
  final _controller = TextEditingController();
  final _locationController = TextEditingController();
  final _tagController = TextEditingController();
  final _removedMediaIds = <int>{};
  V2Post? _post;
  String _visibility = 'public';
  String _language = 'zh';
  bool _loading = true;
  bool _saving = false;
  bool _expired = false;
  Object? _error;
  late final VoidCallback _stopListening;

  @override
  void initState() {
    super.initState();
    final tokens = ref.read(tokenStoreProvider);
    _expired = tokens.isSessionChanging;
    _stopListening = tokens.listenSessionChanges(_expire);
    _load();
  }

  void _expire() {
    if (!mounted || _expired) return;
    setState(() {
      _expired = true;
      _post = null;
      _loading = _saving = false;
      _controller.clear();
      _locationController.clear();
      _tagController.clear();
      _removedMediaIds.clear();
    });
  }

  @override
  void didUpdateWidget(covariant EditPostScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postId != widget.postId) _expire();
  }

  @override
  void dispose() {
    _stopListening();
    _controller.dispose();
    _locationController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_expired) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final post = await ref.read(postsApiProvider).getPost(widget.postId);
      if (!mounted || _expired) return;
      if (post.postId != widget.postId || !post.viewerState.canDelete) {
        throw const FormatException('Unexpected post for editing');
      }
      setState(() {
        _post = post;
        _removedMediaIds.clear();
        _controller.text = post.content;
        _locationController.text = post.location;
        _tagController.text = post.tags.join(', ');
        _visibility = post.visibility;
        _language = post.language.isEmpty ? 'zh' : post.language;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || _expired) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final post = _post;
    if (_saving || _expired || post == null) return;
    final content = _controller.text == post.content ? null : _controller.text;
    final location = _locationController.text == post.location
        ? null
        : _locationController.text;
    final visibility = _visibility == post.visibility ? null : _visibility;
    final initialLanguage = post.language.isEmpty ? 'zh' : post.language;
    final language = _language == initialLanguage ? null : _language;
    final storedTags = post.tags.join(', ');
    List<String>? tags;
    if (_tagController.text != storedTags || content != null) {
      final draft = draftTagNames(
        content: _controller.text,
        tags: _tagController.text,
      );
      if (_tagController.text != storedTags ||
          !listEquals(
            draft,
            draftTagNames(content: post.content, tags: storedTags),
          )) {
        tags = draft;
      }
    }
    if (content == null &&
        location == null &&
        visibility == null &&
        language == null &&
        tags == null &&
        _removedMediaIds.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final api = ref.read(postsApiProvider);
    final tokens = ref.read(tokenStoreProvider);
    if (tokens.isSessionChanging) return;
    final revision = tokens.revision;
    bool current() =>
        mounted &&
        !_expired &&
        identical(post, _post) &&
        tokens.revision == revision &&
        !tokens.isSessionChanging &&
        identical(api, ref.read(postsApiProvider));
    setState(() => _saving = true);
    try {
      var retainedMedia = post.media
          .where((asset) => !_removedMediaIds.contains(asset.mediaId))
          .toList();
      if (visibility == 'public' &&
          retainedMedia.any((asset) => asset.usesContentRoute)) {
        final confirmed = await _confirmAttachmentRemoval();
        if (!current() || !confirmed) {
          return;
        }
        retainedMedia = retainedMedia
            .where((asset) => !asset.usesContentRoute)
            .toList();
      }
      final updated = await api.updatePost(
        postId: post.postId,
        content: content,
        visibility: visibility,
        language: language,
        location: location,
        tags: tags,
        mediaIds: retainedMedia.length == post.media.length
            ? null
            : retainedMedia.map((asset) => asset.mediaId).toList(),
      );
      if (!current()) return;
      if (updated.postId != post.postId ||
          updated.author.userId != post.author.userId) {
        throw const UnconfirmedPostUpdateError();
      }
      ref.read(savedPostProvider(post.postId).notifier).state = updated;
      Navigator.of(context).pop(updated);
    } catch (e) {
      if (!current()) return;
      final message = e is UnconfirmedPostUpdateError
          ? AppLocalizations.of(context).t('post.edit_unconfirmed')
          : ErrorView.describe(context, e);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmAttachmentRemoval() async {
    final l10n = AppLocalizations.of(context);
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.t('post.publish_with_attachment_removal')),
            content: Text(l10n.t('post.publish_attachment_removal_notice')),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.t('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.t('common.confirm')),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(postsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    final languageLabels = {
      'zh': l10n.t('settings.option.zh'),
      'en': l10n.t('settings.option.en'),
      'ja': l10n.t('post.edit_language_ja'),
      'ko': l10n.t('post.edit_language_ko'),
    };
    final storedLanguage = _post?.language;
    if (storedLanguage != null && storedLanguage.isNotEmpty) {
      languageLabels.putIfAbsent(storedLanguage, () => storedLanguage);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('post.edit_title')),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: FilledButton(
              onPressed: _saving || _post == null ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.t('common.save')),
            ),
          ),
        ],
      ),
      body: _expired
          ? EmptyView(message: l10n.t('post.edit_session_changed'))
          : _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : Align(
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
                        key: const Key('edit-post-content-field'),
                        controller: _controller,
                        enabled: !_saving,
                        minLines: 5,
                        maxLines: 12,
                        maxLength: 280,
                        decoration: InputDecoration(
                          labelText: l10n.t('post.content'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('edit-post-location-field'),
                        controller: _locationController,
                        enabled: !_saving,
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
                        key: const Key('edit-post-tags-field'),
                        controller: _tagController,
                        enabled: !_saving,
                        maxLength: 120,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          labelText: l10n.t('compose.tags'),
                          hintText: l10n.t('compose.tags_hint'),
                          prefixIcon: const Icon(Icons.tag_outlined),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: const Key('edit-post-visibility-field'),
                        initialValue: _visibility,
                        decoration: InputDecoration(
                          labelText: l10n.t('post.visibility'),
                          prefixIcon: const Icon(Icons.public),
                        ),
                        onChanged: _saving
                            ? null
                            : (value) => setState(
                                () => _visibility = value ?? 'public',
                              ),
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
                            value: 'mentioned',
                            child: Text(l10n.t('common.mentioned_only')),
                          ),
                          DropdownMenuItem(
                            value: 'private',
                            child: Text(l10n.t('common.private')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: const Key('edit-post-language-field'),
                        initialValue: _language,
                        decoration: InputDecoration(
                          labelText: l10n.t('common.language'),
                        ),
                        onChanged: _saving
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => _language = value);
                                }
                              },
                        items: [
                          for (final entry in languageLabels.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                      ),
                      if (_post case final post?
                          when post.media.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text(
                          l10n.t('post.edit_keep_attachments'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        for (final (index, asset) in post.media.indexed)
                          CheckboxListTile(
                            key: ValueKey(
                              'edit-post-keep-media-${asset.mediaId}',
                            ),
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              asset.fileName.isEmpty
                                  ? '${l10n.t('post.edit_attachment')} ${index + 1}'
                                  : asset.fileName,
                            ),
                            value: !_removedMediaIds.contains(asset.mediaId),
                            onChanged: _saving
                                ? null
                                : (keep) => setState(() {
                                    if (keep == true) {
                                      _removedMediaIds.remove(asset.mediaId);
                                    } else {
                                      _removedMediaIds.add(asset.mediaId);
                                    }
                                  }),
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
