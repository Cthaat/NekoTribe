import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/app_avatar.dart';
import '../../../shared/widgets/media_lightbox.dart';
import '../../links/presentation/content_link_preview.dart';
import '../../posts/presentation/post_poll_card.dart';
import '../../posts/presentation/post_markdown_body.dart';
import '../domain/group_models.dart';

class GroupPostCard extends StatelessWidget {
  const GroupPostCard({
    super.key,
    required this.post,
    this.groupName,
    this.canWrite = false,
    this.showModerationActions = true,
    required this.onTap,
    required this.onLike,
    this.onPin,
    this.onDelete,
    required this.onReport,
  });

  final V2GroupPost post;
  final String? groupName;
  final bool canWrite;
  final bool showModerationActions;
  final VoidCallback onTap;
  final VoidCallback? onLike;
  final VoidCallback? onPin;
  final VoidCallback? onDelete;
  final VoidCallback onReport;

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.MMMd().add_Hm().format(dt.toLocal());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
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
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        [
                          if (groupName != null) groupName!,
                          _formatDate(post.createdAt),
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (post.isPinned)
                  Icon(
                    Icons.push_pin,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                if (post.isAnnouncement)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.campaign,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (post.markdown case final source?)
              PostMarkdownBody(source: source)
            else
              Text(post.content, style: theme.textTheme.bodyMedium),
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
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < post.mediaUrls.length; i++)
                    Tooltip(
                      message: l10n.t('media.open'),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.inner),
                        onTap: () => showMediaLightbox(
                          context: context,
                          items: post.mediaUrls
                              .indexed.map((entry) => MediaLightboxItem(url: entry.$2, heroTag: (context, entry.$1)))
                              .toList(growable: false),
                          initialIndex: i,
                        ),
                        child: AppMediaImage(
                          heroTag: (context, i),
                          url: post.mediaUrls[i],
                          width: 108,
                          height: 108,
                          borderRadius: BorderRadius.circular(AppRadius.inner),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Tooltip(
                  message: l10n.t(
                    post.isLikedByMe ? 'common.unlike' : 'common.like',
                  ),
                  child: TextButton.icon(
                    onPressed: onLike,
                    icon: Icon(
                      post.isLikedByMe ? Icons.favorite : Icons.favorite_border,
                      size: 18,
                    ),
                    label: Text('${post.likesCount}'),
                  ),
                ),
                Semantics(
                  label: l10n.t('post.stats.comments'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppGap.md,
                      vertical: AppGap.sm,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.mode_comment_outlined,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: AppGap.sm),
                        Text(
                          '${post.commentsCount}',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                if (showModerationActions)
                  IconButton(
                    tooltip: post.isPinned
                        ? l10n.t('group.unpin')
                        : l10n.t('group.pin'),
                    onPressed: onPin,
                    icon: Icon(
                      post.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                    ),
                  ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (value) {
                    if (value == 'delete') onDelete?.call();
                    if (value == 'report') onReport();
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'report',
                      child: Text(l10n.t('common.report')),
                    ),
                    if (showModerationActions)
                      PopupMenuItem(
                        value: 'delete',
                        enabled: onDelete != null,
                        child: Text(l10n.t('common.delete')),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
