import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/routing/auth_navigation.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/safe_back_button.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/pill_tag.dart';
import '../../../shared/widgets/ui/subtle_grid_box.dart';
import '../../../shared/widgets/ui/surface_card.dart';
import '../../posts/data/local_post_drafts.dart';
import '../../links/presentation/content_link_preview.dart';
import '../../posts/domain/post_draft.dart';
import '../../posts/domain/post_markdown.dart';
import '../../posts/domain/post_poll.dart';
import '../../posts/presentation/post_draft_actions.dart';
import '../../posts/presentation/post_draft_scope.dart';
import '../../posts/presentation/post_drafts_screen.dart';
import '../../posts/presentation/post_markdown_body.dart';
import '../../posts/presentation/post_markdown_field.dart';
import '../../posts/presentation/post_poll_card.dart';
import '../../posts/presentation/post_poll_composer.dart';
import '../domain/group_models.dart';
import 'group_image_upload.dart';

class GroupDetailScreen extends ConsumerStatefulWidget {
  const GroupDetailScreen({super.key, required this.slug}) : resumeDraft = null;
  const GroupDetailScreen.resumeDraft({super.key, required this.resumeDraft})
    : slug = '';

  final String slug;
  final ScopedPostDraft? resumeDraft;

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
  DialogRoute<bool>? _composerRoute;
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
    final draft = widget.resumeDraft;
    if (draft == null) {
      _load();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || _expired) return;
        await _composePost(cloud: draft);
        if (mounted && (ModalRoute.isCurrentOf(context) ?? false)) {
          Navigator.of(context).pop();
        }
      });
    }
  }

  @override
  void dispose() {
    _stopSessionListener();
    _dismissComposer();
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
    _dismissComposer();
    setState(() {
      _expired = true;
      _group = null;
      _posts = [];
    });
  }

  void _dismissComposer() {
    final route = _composerRoute;
    if (route != null) {
      scheduleMicrotask(() {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
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

  Future<void> _openCloudDrafts() async {
    final group = _group;
    if (_expired ||
        group == null ||
        !requireAuthenticatedAction(context, ref) ||
        ref.read(tokenStoreProvider).isSessionChanging) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PostDraftsScreen(
          groupId: group.groupId,
          openEditor: (context, draft) => _composePost(
            cloud: draft,
            host: context,
          ),
        ),
      ),
    );
  }

  Future<void> _composePost({
    ScopedPostDraft? cloud,
    BuildContext? host,
  }) async {
    final group = _group;
    final groupId = cloud?.draft.payload.groupId ?? group?.groupId;
    if (_expired ||
        _composing ||
        groupId == null ||
        (cloud == null && (_loading || group?.canWritePosts != true)) ||
        (cloud != null &&
            ((group != null && group.groupId != groupId) ||
                !cloud.scope.isCurrent(ref)))) {
      return;
    }
    setState(() => _composing = true);
    final api = ref.read(groupsApiProvider);
    final request = _request;
    bool current() =>
        mounted &&
        !_expired &&
        request == _request &&
        identical(ref.read(groupsApiProvider), api);
    final initial = cloud?.draft.payload;
    var draft = initial?.content ?? '';
    var markdown = initial?.markdown ?? '';
    var usingMarkdown = initial?.markdown != null;
    var textRevision = 0;
    var announcement = initial?.announcement ?? false;
    V2CreatePostPoll? poll = initial?.poll;
    final attachments = <String>[...?initial?.mediaUrls];
    var receipt = cloud?.draft;
    var draftWorking = false;
    var uploading = false;
    var dialogEnded = false;
    var restoreStarted = false;
    String? attachmentError;
    final canAnnounce = cloud != null || _canManageGroup(group?.membership.role);
    final l10n = AppLocalizations.of(context);
    final auth = ref.read(authSessionProvider);
    final tokens = ref.read(tokenStoreProvider);
    final local = cloud == null &&
            (auth.isAuthenticated || auth.loading) &&
            !tokens.isSessionChanging
        ? LocalPostDraftSession(
            storage: ref.read(localPostDraftStoreProvider),
            tokens: tokens,
            backend: ref.read(appConfigProvider).apiBaseUrl,
            groupId: groupId,
          )
        : null;
    void cacheText() => local?.update((
      text: usingMarkdown ? markdown : draft,
      markdown: usingMarkdown,
    ));
    try {
      final nav = Navigator.of(host ?? context, rootNavigator: true);
      final route = DialogRoute<bool>(
        context: host ?? context,
        themes: InheritedTheme.capture(from: host ?? context, to: nav.context),
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) {
            if (local != null && !restoreStarted) {
              restoreStarted = true;
              unawaited(local.restore().then((saved) {
                if (saved == null ||
                    dialogEnded ||
                    !dialogContext.mounted ||
                    !current() ||
                    !local.canRestore) {
                  return;
                }
                local.acceptRestored(saved);
                update(() {
                  textRevision++;
                  usingMarkdown = saved.markdown;
                  if (saved.markdown) {
                    markdown = saved.text;
                  } else {
                    draft = saved.text;
                  }
                });
              }));
            }
            final bytes = utf8.encode(draft.trim()).length;
            final validContent = usingMarkdown
                ? isValidPostMarkdown(markdown)
                : bytes > 0 && bytes <= 4000;
            final locked = draftWorking ||
                receipt?.status == PostDraftStatus.published;
            return AlertDialog(
              title: Text(l10n.t('group.new_post')),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PostMarkdownToggle(
                      selected: usingMarkdown,
                      onChanged: locked
                          ? null
                          : (value) => update(() {
                              if (value && markdown.isEmpty) markdown = draft;
                              if (!value && draft.isEmpty && isValidPostMarkdown(markdown)) {
                                draft = postMarkdownExcerpt(markdown);
                              }
                              usingMarkdown = value;
                              cacheText();
                            }),
                    ),
                    if (usingMarkdown)
                      PostMarkdownField(
                        value: markdown,
                        onChanged: locked
                            ? null
                            : (value) => update(() {
                                markdown = value;
                                cacheText();
                              }),
                      )
                    else TextFormField(
                      key: ValueKey(('group-compose-text', textRevision)),
                      initialValue: draft,
                      readOnly: locked,
                      onChanged: (value) => update(() {
                        draft = value;
                        cacheText();
                      }),
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
                        onChanged: locked
                            ? null
                            : (value) => update(() => announcement = value ?? false),
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
                              onDeleted: uploading || locked
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
                      onPressed: uploading || locked
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
                    PostPollComposer(
                      initial: initial?.poll,
                      enabled: !uploading && !locked,
                      onChanged: (value) => update(() => poll = value),
                    ),
                    if (local != null)
                      TextButton(
                        key: const Key('group-local-draft-discard'),
                        onPressed: locked
                            ? null
                            : () async {
                                final discard = await confirmDraftAction(
                                  context,
                                  'draft.discard_local',
                                  l10n.t('draft.confirm_discard_local'),
                                );
                                if (!discard || !dialogContext.mounted ||
                                    dialogEnded || !current()) {
                                  return;
                                }
                                update(() {
                                  draft = markdown = '';
                                  usingMarkdown = false;
                                  textRevision++;
                                });
                                final cleared = await local.discard();
                                if (!cleared && dialogContext.mounted &&
                                    !dialogEnded && current()) {
                                  update(() => attachmentError = 'draft.discard_local_error');
                                }
                              },
                        child: Text(l10n.t('draft.discard_local')),
                      ),
                    PostDraftActions(
                      initial: cloud,
                      enabled: !uploading,
                      readInput: () => V2PostDraftInput(
                        groupId: groupId,
                        content: usingMarkdown && isValidPostMarkdown(markdown)
                            ? initial?.markdown == markdown
                                ? initial!.content
                                : postMarkdownExcerpt(markdown)
                            : draft,
                        markdown: usingMarkdown ? markdown : null,
                        mediaUrls: List.of(attachments),
                        announcement: announcement,
                        poll: poll,
                      ),
                      onWorkingChanged: (value) {
                        if (!dialogEnded && dialogContext.mounted) {
                          update(() => draftWorking = value);
                        }
                      },
                      onChanged: (value) {
                        if (!dialogEnded && dialogContext.mounted) {
                          update(() => receipt = value);
                          if (local != null &&
                              value.status == PostDraftStatus.published) {
                            unawaited(local.clearPublished(local.snapshot));
                          }
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: draftWorking
                      ? null
                      : () => Navigator.pop(dialogContext),
                  child: Text(l10n.t('common.cancel')),
                ),
                if (receipt == null) FilledButton(
                  onPressed:
                      uploading || draftWorking ||
                          !validContent ||
                          poll?.isValid == false
                      ? null
                      : () => Navigator.pop(dialogContext, true),
                  child: Text(l10n.t('common.post')),
                ),
              ],
            );
          },
        ),
      );
      _composerRoute = route;
      final confirmed = await nav.push(route);
      dialogEnded = true;
      if (!current()) return;
      if (receipt?.status == PostDraftStatus.published) {
        if (widget.resumeDraft == null) await _load();
        return;
      }
      if (confirmed != true) return;
      if (poll?.isValid == false) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.t('poll.invalid_deadline'))),
        );
        return;
      }
      final publishedLocal = local?.snapshot;
      await api.createPost(
        groupId: groupId,
        content: usingMarkdown ? postMarkdownExcerpt(markdown) : draft.trim(),
        isAnnouncement: canAnnounce && announcement,
        mediaUrls: List.of(attachments),
        poll: poll,
        markdown: usingMarkdown ? markdown : null,
      );
      unawaited(local?.clearPublished(publishedLocal));
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
      _composerRoute = null;
      if (mounted && !_expired) setState(() => _composing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(groupsApiProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    final l10n = AppLocalizations.of(context);
    if (widget.resumeDraft != null) {
      return Scaffold(
        appBar: AppBar(
          leading: const SafeBackButton(fallbackRoute: '/groups'),
          title: Text(l10n.t('draft.title')),
        ),
        body: _expired
            ? EmptyView(message: l10n.t('visibility.sessionChanged'))
            : null,
      );
    }
    final theme = Theme.of(context);
    final social = SocialColors.of(context);
    final scheme = theme.colorScheme;
    final dockInset = MediaQuery.sizeOf(context).width < AppBreakpoints.medium
        ? 80.0
        : 0.0;
    return Scaffold(
      backgroundColor: social.surfaceBase,
      appBar: AppBar(
        leading: const SafeBackButton(fallbackRoute: '/groups'),
        backgroundColor: social.glassSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          _group?.name ?? l10n.t('group.group'),
          style: theme.textTheme.titleLarge?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!_expired && _group != null && !_loading)
            IconButton(
              icon: const Icon(Icons.cloud_outlined),
              tooltip: l10n.t('draft.title'),
              onPressed: _composing ? null : _openCloudDrafts,
            ),
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
          !_loading && !_busy && _group != null && _group!.canWritePosts
          ? Padding(
              padding: EdgeInsets.only(bottom: dockInset),
              child: FloatingActionButton.extended(
                shape: const StadiumBorder(),
                elevation: theme.brightness == Brightness.dark ? 0 : 2,
                onPressed: _composing ? null : _composePost,
                icon: const Icon(Icons.edit),
                label: Text(
                  l10n.t('group.new_post'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
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
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 108),
                      children: [
                        SurfaceCard(
                          padding: EdgeInsets.zero,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Hero(
                                tag: 'group-cover-${_group!.groupId}',
                                child: SizedBox(
                                  height: 132,
                                  width: double.infinity,
                                  child: _group!.coverUrl != null &&
                                          _group!.coverUrl!.trim().isNotEmpty
                                      ? AppMediaImage(
                                          url: _group!.coverUrl!,
                                          height: 132,
                                          width: double.infinity,
                                          borderRadius: BorderRadius.zero,
                                        )
                                      : SubtleGridBox(
                                          backgroundColor: social.surfaceSubtle,
                                          child: const SizedBox.expand(),
                                        ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        AppAvatar(
                                          url: _group!.avatarUrl,
                                          size: 56,
                                          name: _group!.name,
                                          seed: _group!.groupId,
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                _group!.name,
                                                style: theme.textTheme.titleLarge
                                                    ?.copyWith(
                                                      fontSize: 18,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 6),
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
                                                    text:
                                                        _group!
                                                            .privacyDesc
                                                            .isEmpty
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
                                    if (_group!.description.isNotEmpty) ...[
                                      const SizedBox(height: 12),
                                      Text(
                                        _group!.description,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(height: 1.6),
                                      ),
                                    ],
                                    if (_group!.tags.isNotEmpty) ...[
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: _group!.tags
                                            .map((t) => PillTag(label: '#$t'))
                                            .toList(),
                                      ),
                                    ],
                                    const SizedBox(height: 14),
                                    SizedBox(
                                      width: double.infinity,
                                      child: FilledButton(
                                        onPressed:
                                            _busy ||
                                                !_canChangeMembership(_group!)
                                            ? null
                                            : _toggleMembership,
                                        style: FilledButton.styleFrom(
                                          shape: const StadiumBorder(),
                                          backgroundColor:
                                              _group!.membership.isMember
                                              ? social.surfaceSubtle
                                              : scheme.primary,
                                          foregroundColor:
                                              _group!.membership.isMember
                                              ? scheme.onSurface
                                              : scheme.onPrimary,
                                        ),
                                        child: _busy
                                            ? const SizedBox(
                                                height: 16,
                                                width: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : Text(
                                                l10n.t(
                                                  _membershipLabel(_group!),
                                                ),
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (_posts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: EmptyView(
                              message: l10n.t(
                                _group!.privacy != 'public' &&
                                        !_activeMember(_group!)
                                    ? 'group.member_posts_only'
                                    : 'group.no_posts',
                              ),
                            ),
                          )
                        else
                          for (final p in _posts)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _GroupPostTile(
                                post: p,
                                canWrite: _group!.canWritePosts,
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
  const _GroupPostTile({
    required this.post,
    required this.canWrite,
    required this.onTap,
  });
  final V2GroupPost post;
  final bool canWrite;
  final VoidCallback onTap;

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.MMMd().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final social = SocialColors.of(context);
    return SurfaceCard(
      padding: const EdgeInsets.all(16),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppAvatar(
                url: post.author.avatarUrl,
                size: 36,
                name: post.author.displayName.isEmpty
                    ? post.author.username
                    : post.author.displayName,
                seed: post.author.userId,
              ),
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
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _formatDate(post.createdAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: social.inkTertiary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (post.isPinned)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.push_pin_outlined,
                    size: 15,
                    color: theme.colorScheme.primary,
                  ),
                ),
              if (post.isAnnouncement)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.campaign_outlined,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (post.markdown case final source?)
            PostMarkdownBody(source: source)
          else
            Text(
              post.content,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
            ),
          ContentLinkPreview(content: post.content, markdown: post.markdown),
          if (post.poll case final poll?)
            PostPollCard(
              key: ValueKey((post.groupId, post.postId, poll.pollId)),
              groupId: post.groupId,
              postId: post.postId,
              poll: poll,
              canWrite: canWrite,
            ),
          if (post.mediaUrls.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: post.mediaUrls
                  .map(
                    (url) => ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.inner),
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
          const SizedBox(height: 10),
          DefaultTextStyle(
            style: theme.textTheme.bodySmall!.copyWith(
              color: social.inkTertiary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            child: Row(
              children: [
                Icon(
                  Icons.favorite_border,
                  size: 14,
                  color: social.inkTertiary,
                ),
                if (post.likesCount > 0) ...[
                  const SizedBox(width: 4),
                  Text('${post.likesCount}'),
                ],
                const SizedBox(width: 16),
                Icon(
                  Icons.mode_comment_outlined,
                  size: 14,
                  color: social.inkTertiary,
                ),
                if (post.commentsCount > 0) ...[
                  const SizedBox(width: 4),
                  Text('${post.commentsCount}'),
                ],
                const SizedBox(width: 16),
                Icon(
                  Icons.visibility_outlined,
                  size: 14,
                  color: social.inkTertiary,
                ),
                if (post.viewsCount > 0) ...[
                  const SizedBox(width: 4),
                  Text('${post.viewsCount}'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
