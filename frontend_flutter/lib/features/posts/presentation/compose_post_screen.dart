import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('compose.publish')),
        actions: [
          FilledButton(
            onPressed: _busy ? null : _publish,
            child: _busy
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.t('compose.publish')),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              maxLines: 6,
              maxLength: 2000,
              decoration: InputDecoration(
                hintText: l10n.t('compose.placeholder'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_media.isNotEmpty)
              SizedBox(
                height: 100,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _media.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final asset = _media[i];
                    return Stack(
                      children: [
                        SizedBox(
                          width: 100,
                          height: 100,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              ref
                                  .read(assetUrlResolverProvider)
                                  .resolve(asset.publicUrl),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const ColoredBox(
                                color: Colors.grey,
                                child: Icon(Icons.broken_image),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: IconButton(
                            iconSize: 18,
                            onPressed: () => setState(() => _media.removeAt(i)),
                            icon: const CircleAvatar(
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
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  onPressed: _uploading ? null : _pickMedia,
                  icon: _uploading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.photo_outlined),
                ),
                const Spacer(),
                DropdownButton<String>(
                  value: _visibility,
                  onChanged: (v) => setState(() => _visibility = v ?? 'public'),
                  items: const [
                    DropdownMenuItem(value: 'public', child: Text('Public')),
                    DropdownMenuItem(
                      value: 'followers',
                      child: Text('Followers'),
                    ),
                    DropdownMenuItem(value: 'private', child: Text('Private')),
                  ],
                ),
              ],
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}
