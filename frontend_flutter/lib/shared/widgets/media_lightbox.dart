import 'package:flutter/material.dart';

import '../i18n/app_localizations.dart';
import 'app_avatar.dart';

class MediaLightboxItem {
  const MediaLightboxItem({required this.url, this.altText, this.description});

  final String url;
  final String? altText;
  final String? description;
}

Future<void> showMediaLightbox({
  required BuildContext context,
  required List<MediaLightboxItem> items,
  int initialIndex = 0,
}) {
  if (items.isEmpty) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (_) => _MediaLightboxDialog(
      items: items,
      initialIndex: initialIndex.clamp(0, items.length - 1),
    ),
  );
}

class _MediaLightboxDialog extends StatefulWidget {
  const _MediaLightboxDialog({
    required this.items,
    required this.initialIndex,
  });

  final List<MediaLightboxItem> items;
  final int initialIndex;

  @override
  State<_MediaLightboxDialog> createState() => _MediaLightboxDialogState();
}

class _MediaLightboxDialogState extends State<_MediaLightboxDialog> {
  late int _index = widget.initialIndex;

  void _move(int delta) {
    setState(() {
      _index = (_index + delta).clamp(0, widget.items.length - 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final item = widget.items[_index];
    final hasPrevious = _index > 0;
    final hasNext = _index < widget.items.length - 1;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.t('media.lightbox_title'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (widget.items.length > 1)
                    Text(
                      '${_index + 1}/${widget.items.length}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  IconButton(
                    tooltip: l10n.t('common.close'),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Flexible(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  InteractiveViewer(
                    minScale: 1,
                    maxScale: 4,
                    child: Container(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                        minHeight: 280,
                      ),
                      color: Colors.black,
                      alignment: Alignment.center,
                      child: AppMediaImage(
                        url: item.url,
                        fit: BoxFit.contain,
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                  ),
                  if (hasPrevious)
                    Positioned(
                      left: 8,
                      child: IconButton.filledTonal(
                        tooltip: l10n.t('common.previous'),
                        onPressed: () => _move(-1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                    ),
                  if (hasNext)
                    Positioned(
                      right: 8,
                      child: IconButton.filledTonal(
                        tooltip: l10n.t('common.next'),
                        onPressed: () => _move(1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ),
                ],
              ),
            ),
            if ((item.description ?? item.altText ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(item.description ?? item.altText ?? ''),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
