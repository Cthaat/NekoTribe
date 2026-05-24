import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/post_models.dart';

class EditPostScreen extends ConsumerStatefulWidget {
  const EditPostScreen({super.key, required this.postId});

  final int postId;

  @override
  ConsumerState<EditPostScreen> createState() => _EditPostScreenState();
}

class _EditPostScreenState extends ConsumerState<EditPostScreen> {
  final _controller = TextEditingController();
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
      await ref.read(postsApiProvider).updatePost(
            postId: widget.postId,
            content: _controller.text.trim(),
            visibility: _visibility,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorView.describe(context, e))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit post'),
        actions: [
          TextButton(
            onPressed: _saving || _post == null ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(error: _error!, onRetry: _load)
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _controller,
                        minLines: 5,
                        maxLines: 10,
                        maxLength: 2000,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Content',
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: _visibility,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Visibility',
                        ),
                        onChanged: (value) =>
                            setState(() => _visibility = value ?? 'public'),
                        items: const [
                          DropdownMenuItem(
                            value: 'public',
                            child: Text('Public'),
                          ),
                          DropdownMenuItem(
                            value: 'followers',
                            child: Text('Followers'),
                          ),
                          DropdownMenuItem(
                            value: 'private',
                            child: Text('Private'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
    );
  }
}
