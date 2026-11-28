import 'package:flutter/material.dart';

import '../../../shared/motion/entrance.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/glass/liquid_glass_surface.dart';
import '../../../shared/widgets/glass/liquid_glass_tokens.dart';
import '../domain/chat_models.dart';

class ChatReplyQuote extends StatelessWidget {
  const ChatReplyQuote({super.key, required this.replyTo, this.onTap});

  final V2ChatMessageReply replyTo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(onTap: onTap, child: Container(
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
    ));
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
          SpringPop(value: (reaction.count, reaction.reactedByMe),
            from: .8, child: Text(reaction.emoji)),
          const SizedBox(width: 4),
          Text('${reaction.count}'),
        ],
      ),
      onPressed: onPressed,
    );
  }
}

typedef ChatQuickAction = ({IconData icon, String label, VoidCallback? run});

class ChatMessageMotion extends StatefulWidget {
  const ChatMessageMotion({super.key, required this.child, required this.actions, this.enter = false});
  final Widget child;
  final List<ChatQuickAction> actions;
  final bool enter;
  @override
  State<ChatMessageMotion> createState() => ChatMessageMotionState();
}

class ChatMessageMotionState extends State<ChatMessageMotion> {
  int _pulse = 0;
  late final bool _enter = widget.enter;
  void highlight() => setState(() => _pulse++);

  Future<void> _showActions() async {
    final visible = widget.actions.where((action) => action.run != null).toList();
    final choice = await showDialog<IconData>(context: context, builder: (sheet) => Dialog(
      backgroundColor: Colors.transparent, elevation: 0,
      child: LiquidGlassSurface(preset: LiquidGlassPreset.popover,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Wrap(alignment: WrapAlignment.center, children: [
          for (final action in visible)
            IconButton(tooltip: action.label, icon: Icon(action.icon),
              onPressed: () => Navigator.pop(sheet, action.icon)),
        ]),
      ),
    ));
    if (mounted && choice != null) {
      for (final action in widget.actions.where((item) => item.icon == choice)) {
        action.run?.call();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = GestureDetector(
      onLongPress: widget.actions.any((action) => action.run != null) ? _showActions : null,
      child: widget.child,
    );
    final reduced = AppMotion.reduced(context);
    final pulse = TweenAnimationBuilder<double>(
      key: ValueKey(_pulse),
      tween: Tween(begin: _pulse == 0 ? 0 : 1, end: 0),
      duration: reduced ? const Duration(milliseconds: 600) : const Duration(milliseconds: 900),
      builder: (_, t, inner) => DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: (reduced && t > 0 ? 1 : t) * .18),
          borderRadius: BorderRadius.circular(AppRadius.tile),
        ), child: inner),
      child: content,
    );
    if (!_enter || reduced) return pulse;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1), duration: const Duration(milliseconds: 480),
      curve: const LiquidSnapCurve(), builder: (_, t, inner) =>
        Transform.translate(offset: Offset(0, 14 * (1 - t)), child: inner), child: pulse,
    );
  }
}

/// Reverse chat lists have variable row heights. Walk mounted viewport ranges
/// until Flutter can reveal the target precisely, fetching history as needed.
Future<void> revealChatQuote({
  required int id, required ScrollController scroll,
  required Map<int, GlobalKey> keys, required List<int> Function() ids,
  required Future<void> Function() loadOlder, required bool Function() hasOlder,
  required bool Function() current,
}) async {
  var rows = ids();
  while (current() && !rows.contains(id) && hasOlder()) {
    await loadOlder();
    if (!current()) return;
    final next = ids();
    if (next.length == rows.length) return;
    rows = next;
  }
  while (current() && scroll.hasClients) {
    final row = keys[id];
    final context = row?.currentContext;
    if (context != null) {
      await Scrollable.ensureVisible(context, alignment: .5,
        duration: AppMotion.resolve(context, AppMotion.base));
      if (current()) (row?.currentState as ChatMessageMotionState?)?.highlight();
      return;
    }
    final position = scroll.position;
    rows = ids();
    final index = rows.indexOf(id);
    final first = rows.indexWhere((key) => keys[key]?.currentContext != null);
    if (first < 0 || index < 0) return;
    final step = position.viewportDimension * (index < first ? -.8 : .8);
    final next = (position.pixels + step).clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((next - position.pixels).abs() < .5) return;
    scroll.jumpTo(next.toDouble());
    await WidgetsBinding.instance.endOfFrame;
  }
}
