import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
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
  V2Post? _post;
  String _visibility = 'public';
  bool _loading = true;
  bool _saving = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _locationController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final post = await ref.read(postsApiProvider).getPost(widget.postId);
      if (!mounted) return;
      setState(() {
        _post = post;
        _controller.text = post.content;
        _locationController.text = post.location;
        _tagController.text = post.tags.join(', ');
        _visibility = post.visibility;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(postsApiProvider)
          .updatePost(
            postId: widget.postId,
            content: _controller.text.trim(),
            visibility: _visibility,
            location: _locationController.text.trim(),
            tags: draftTagNames(
              content: _controller.text,
              tags: _tagController.text,
            ),
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
      body: _loading
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
                        onChanged: (value) =>
                            setState(() => _visibility = value ?? 'public'),
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
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
