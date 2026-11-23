import 'package:flutter/material.dart';

import '../domain/chat_models.dart';

class ChatReplyQuote extends StatelessWidget {
  const ChatReplyQuote({super.key, required this.replyTo});

  final V2ChatMessageReply replyTo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.55,
        ),
        border: Border(
          left: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply_rounded, size: 16),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${replyTo.authorName}: ${replyTo.content}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class ChatReactionChip extends StatelessWidget {
  const ChatReactionChip({super.key, required this.reaction, this.onPressed});

  final V2ChatReactionSummary reaction;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ActionChip(
      visualDensity: VisualDensity.compact,
      side: BorderSide(
        color: reaction.reactedByMe
            ? theme.colorScheme.primary.withValues(alpha: 0.45)
            : theme.dividerColor,
      ),
      backgroundColor: reaction.reactedByMe
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(reaction.emoji),
          const SizedBox(width: 4),
          Text('${reaction.count}'),
        ],
      ),
      onPressed: onPressed,
    );
  }
}
