import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/group_models.dart';
import 'group_image_upload.dart';

class GroupDetailScreen extends ConsumerStatefulWidget {
  const GroupDetailScreen({super.key, required this.slug});
  final String slug;

  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen> {
  V2Group? _group;
  List<V2GroupPost> _posts = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasNext = false;
  int _page = 1;
  Object? _error;
  bool _busy = false;
  bool _composing = false;
  bool _expired = false;
  int _request = 0;
  late final VoidCallback _stopSessionListener;

  static const _pageSize = 20;

  @override
  void initState() {
    super.initState();
    final tokens = ref.read(tokenStoreProvider);
    _expired = tokens.isSessionChanging;
    _stopSessionListener = tokens.listenSessionChanges(_expire);
    ref.listenManual(groupsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    _load();
  }

  @override
  void dispose() {
    _stopSessionListener();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant GroupDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.slug != widget.slug) _expire();
  }

  void _expire() {
    if (!mounted || _expired) return;
    _request++;
    setState(() {
      _expired = true;
      _group = null;
      _posts = [];
    });
  }

  Future<void> _load() async {
    if (!mounted || _expired) return;
    final request = ++_request;
    bool current() => mounted && request == _request;
    setState(() {
      _loading = true;
      _error = null;
      _page = 1;
      _hasNext = false;
      _loadingMore = false;
    });
    try {
      final api = ref.read(groupsApiProvider);
      final group = await api.getGroup(widget.slug);
      if (!current()) return;
      if (group.groupId <= 0 || group.slug != widget.slug) {
        throw const FormatException('Unexpected group');
      }
      final posts = group.privacy == 'public' || _activeMember(group)
          ? await api.posts(group.groupId, page: 1, size: _pageSize)
          : null;
      if (!current()) return;
      setState(() {
        _group = group;
        _posts = posts?.items ?? [];
        _page = 1;
        _hasNext = posts?.hasNext ?? false;
        _loading = false;
      });
    } catch (e) {
      if (!current()) return;
      _group = null;
      _posts = [];
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMorePosts() async {
    if (_expired || _loadingMore || !_hasNext || _loading || _group == null) {
      return;
    }
    final request = _request;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final page = await ref
          .read(groupsApiProvider)
          .posts(_group!.groupId, page: next, size: _pageSize);
      if (!mounted || request != _request) return;
      setState(() {
        _posts = [..._posts, ...page.items];
        _page = next;
        _hasNext = page.hasNext;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  Future<void> _toggleMembership() async {
    final group = _group;
    if (_expired ||
        _loading ||
        group == null ||
        _busy ||
        !_canChangeMembership(group)) {
      return;
    }
    final api = ref.read(groupsApiProvider);
    bool current() =>
        mounted && !_expired && identical(ref.read(groupsApiProvider), api);
    setState(() => _busy = true);
    try {
      final status = group.membership.status;
      if (status == 'active' || status == 'muted' || status == 'pending') {
        await api.leaveGroup(group.groupId);
      } else {
        await api.joinGroup(group.groupId);
      }
      if (!current()) return;
      await _load();
    } catch (e) {
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _composePost() async {
    final group = _group;
    if (_expired ||
        _loading ||
        _composing ||
        group == null ||
        !_canPost(group)) {
      return;
    }
    setState(() => _composing = true);
    final api = ref.read(groupsApiProvider);
    final request = _request;
    bool current() =>
        mounted &&
        request == _request &&
        identical(ref.read(groupsApiProvider), api);
    var draft = '';
    var announcement = false;
    final attachments = <String>[];
    var uploading = false;
    var dialogEnded = false;
    String? attachmentError;
    final canAnnounce = _canManageGroup(group.membership.role);
    final l10n = AppLocalizations.of(context);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) {
            final bytes = utf8.encode(draft.trim()).length;
            return AlertDialog(
              title: Text(l10n.t('group.new_post')),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      onChanged: (value) => update(() => draft = value),
                      maxLines: 5,
                      minLines: 3,
                      decoration: InputDecoration(
                        hintText: l10n.t('group.compose_hint'),
                        errorText: bytes > 4000
                            ? l10n.t('group.compose_too_long')
                            : null,
                      ),
                    ),
                    if (canAnnounce)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.t('group.compose_announcement')),
                        value: announcement,
                        onChanged: (value) =>
                            update(() => announcement = value ?? false),
                      ),
                    if (attachments.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (
                            var index = 0;
                            index < attachments.length;
                            index++
                          )
                            InputChip(
                              key: ValueKey(attachments[index]),
                              avatar: AppMediaImage(
                                url: attachments[index],
                                width: 24,
                                height: 24,
                              ),
                              label: Text(
                                l10n
                                    .t('group.compose_image_number')
                                    .replaceFirst('{number}', '${index + 1}'),
                              ),
                              deleteButtonTooltipMessage: l10n.t(
                                'group.compose_remove_image',
                              ),
                              onDeleted: uploading
                                  ? null
                                  : () => update(
                                      () => attachments.removeAt(index),
                                    ),
                            ),
                        ],
                      ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.image_outlined),
                      label: Text(
                        l10n.t(
                          uploading
                              ? 'group.compose_uploading'
                              : 'group.compose_add_image',
                        ),
                      ),
                      onPressed: uploading
                          ? null
                          : () async {
                              if (!current()) return;
                              bool dialogCurrent() =>
                                  !dialogEnded &&
                                  dialogContext.mounted &&
                                  current();
                              update(() {
                                uploading = true;
                                attachmentError = null;
                              });
                              try {
                                final raw = await pickAndUploadGroupImage(
                                  ref: ref,
                                  isCurrent: dialogCurrent,
                                );
                                if (!dialogCurrent() || raw == null) return;
                                final url = raw.trim();
                                final uri = Uri.tryParse(url);
                                if (uri == null ||
                                    url.contains(',') ||
                                    !((url.startsWith('/') &&
                                            !url.startsWith('//')) ||
                                        ((uri.scheme == 'http' ||
                                                uri.scheme == 'https') &&
                                            uri.host.isNotEmpty))) {
                                  throw const FormatException(
                                    'Invalid group image URL',
                                  );
                                }
                                if (attachments.contains(url)) return;
                                if (utf8
                                        .encode([...attachments, url].join(','))
                                        .length >
                                    2000) {
                                  update(
                                    () => attachmentError =
                                        'group.compose_attachment_limit',
                                  );
                                } else {
                                  update(() => attachments.add(url));
                                }
                              } catch (_) {
                                if (dialogCurrent()) {
                                  update(
                                    () => attachmentError =
                                        'group.compose_attachment_failed',
                                  );
                                }
                              } finally {
                                if (dialogCurrent()) {
                                  update(() => uploading = false);
                                }
                              }
                            },
                    ),
                    if (attachmentError != null) Text(l10n.t(attachmentError!)),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.t('common.cancel')),
                ),
                FilledButton(
                  onPressed: uploading || bytes == 0 || bytes > 4000
                      ? null
                      : () => Navigator.pop(dialogContext, true),
                  child: Text(l10n.t('common.post')),
                ),
              ],
            );
          },
        ),
      );
      dialogEnded = true;
      if (!current() || confirmed != true) return;
      await api.createPost(
        groupId: group.groupId,
        content: draft.trim(),
        isAnnouncement: canAnnounce && announcement,
        mediaUrls: List.of(attachments),
      );
      if (!current()) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('group.compose_success'))));
      await _load();
    } catch (e) {
      if (!current()) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e is FormatException
                ? l10n.t('group.compose_unconfirmed')
                : ErrorView.describe(context, e),
          ),
        ),
      );
    } finally {
      if (mounted && !_expired) setState(() => _composing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(groupsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _group?.name ?? l10n.t('group.group'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // Manage is owner/admin/moderator only — not every member.
          if (!_loading &&
              _group != null &&
              _activeMember(_group!) &&
              _canManageGroup(_group!.membership.role))
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: l10n.t('common.settings'),
              onPressed: () => context.push('/groups/${widget.slug}/manage'),
            ),
        ],
      ),
      floatingActionButton:
          !_loading && !_busy && _group != null && _canPost(_group!)
          ? FloatingActionButton.extended(
              onPressed: _composing ? null : _composePost,
              icon: const Icon(Icons.edit),
              label: Text(l10n.t('group.new_post')),
            )
          : null,
      body: _expired
          ? EmptyView(message: l10n.t('visibility.sessionChanged'))
          : _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _group == null
          ? const SizedBox.shrink()
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                        _loadMorePosts();
                      }
                      return false;
                    },
                    child: ListView(
                      children: [
                        if (_group!.coverUrl != null)
                          AppMediaImage(
                            url: _group!.coverUrl!,
                            height: 180,
                            borderRadius: BorderRadius.zero,
                          ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Row(
                            children: [
                              AppAvatar(url: _group!.avatarUrl, size: 64),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _group!.name,
                                      style: theme.textTheme.titleLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 12,
                                      runSpacing: 4,
                                      children: [
                                        _MetaPiece(
                                          icon: Icons.people_outline,
                                          text:
                                              '${_group!.memberCount} ${l10n.t('group.members')}',
                                        ),
                                        _MetaPiece(
                                          icon: Icons.lock_outline,
                                          text: _group!.privacyDesc.isEmpty
                                              ? _group!.privacy
                                              : _group!.privacyDesc,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _busy || !_canChangeMembership(_group!)
                                  ? null
                                  : _toggleMembership,
                              style: _group!.membership.isMember
                                  ? FilledButton.styleFrom(
                                      backgroundColor: theme
                                          .colorScheme
                                          .surfaceContainerHighest,
                                      foregroundColor:
                                          theme.colorScheme.onSurface,
                                    )
                                  : null,
                              child: _busy
                                  ? const SizedBox(
                                      height: 16,
                                      width: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Text(l10n.t(_membershipLabel(_group!))),
                            ),
                          ),
                        ),
                        if (_group!.description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                            child: Text(
                              _group!.description,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        if (_group!.tags.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: _group!.tags
                                  .map((t) => Chip(label: Text('#$t')))
                                  .toList(),
                            ),
                          ),
                        Divider(height: 1, color: theme.dividerColor),
                        if (_posts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                              child: Text(
                                l10n.t(
                                  _group!.privacy != 'public' &&
                                          !_activeMember(_group!)
                                      ? 'group.member_posts_only'
                                      : 'group.no_posts',
                                ),
                              ),
                            ),
                          )
                        else
                          ..._posts.map(
                            (p) => _GroupPostTile(
                              post: p,
                              onTap: () => context.push(
                                '/groups/${widget.slug}/posts/${p.postId}',
                              ),
                            ),
                          ),
                        if (_hasNext)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

bool _canManageGroup(String? role) {
  return role == 'owner' || role == 'admin' || role == 'moderator';
}

bool _activeMember(V2Group group) => group.membership.status == 'active';

bool _canPost(V2Group group) {
  if (!_activeMember(group)) return false;
  final role = group.membership.role;
  return switch (group.postPermission) {
    'all' => true,
    'moderator_up' => _canManageGroup(role),
    'admin_only' => role == 'owner' || role == 'admin',
    _ => false,
  };
}

bool _canChangeMembership(V2Group group) {
  final status = group.membership.status;
  if (status == 'pending') return true;
  if (status == 'active' || status == 'muted') {
    return group.membership.role != 'owner';
  }
  return !group.membership.isMember &&
      status == null &&
      group.privacy != 'secret';
}

String _membershipLabel(V2Group group) {
  if (group.membership.status == 'pending') return 'group.cancel_request';
  if (_activeMember(group) || group.membership.status == 'muted') {
    return group.membership.role == 'owner'
        ? 'group.membership_owner'
        : 'group.leave';
  }
  return _canChangeMembership(group)
      ? 'group.join'
      : 'group.membership_unavailable';
}

class _MetaPiece extends StatelessWidget {
  const _MetaPiece({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _GroupPostTile extends StatelessWidget {
  const _GroupPostTile({required this.post, required this.onTap});
  final V2GroupPost post;
  final VoidCallback onTap;

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.MMMd().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppAvatar(url: post.author.avatarUrl, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.author.displayName.isEmpty
                            ? post.author.username
                            : post.author.displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _formatDate(post.createdAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (post.isPinned)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.push_pin,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                if (post.isAnnouncement)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.campaign,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(post.content, style: theme.textTheme.bodyMedium),
            if (post.mediaUrls.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: post.mediaUrls
                    .map(
                      (url) => ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AppMediaImage(
                          url: url,
                          width: 120,
                          height: 120,
                          borderRadius: BorderRadius.zero,
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 8),
            DefaultTextStyle(
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.favorite_border,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text('${post.likesCount}'),
                  const SizedBox(width: 14),
                  Icon(
                    Icons.mode_comment_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text('${post.commentsCount}'),
                  const SizedBox(width: 14),
                  Icon(
                    Icons.visibility_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text('${post.viewsCount}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
