import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/token_store.dart';
import '../../core/network/api_exception.dart';
import '../i18n/app_localizations.dart';
import '../motion/skeleton.dart';
import '../theme/tokens.dart';
import 'responsive.dart';
import 'ui/surface_card.dart';

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  static String describe(BuildContext context, Object error) {
    final l10n = AppLocalizations.of(context);
    if (error is SessionStorageUnavailable) {
      return l10n.t('auth.secure_browser_required');
    }
    if (error is ApiException) {
      if (error.isUnauthorized) return l10n.t('error.unauthorized');
      if (error.isForbidden) return l10n.t('error.forbidden');
      if (error.isNotFound) return l10n.t('error.not_found');
      if (error.isValidation || error.isBadRequest) {
        final msg = error.message.trim();
        if (msg.isNotEmpty && msg.length <= 120 && !msg.startsWith('HTTP')) {
          return msg;
        }
        return l10n.t('error.validation');
      }
      final msg = error.message.trim();
      if (msg.isNotEmpty &&
          msg.length <= 160 &&
          !RegExp(r'^HTTP \d+').hasMatch(msg)) {
        return msg;
      }
      return l10n.t('error.generic');
    }
    final raw = error.toString();
    if (_isConnectionError(raw)) return l10n.t('error.connection');
    if (raw.toLowerCase().contains('timeout')) {
      return l10n.t('error.timeout');
    }
    return l10n.t('error.generic');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final isAuthError =
        error is ApiException && (error as ApiException).isUnauthorized;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: colorScheme.error.withValues(alpha: 0.9),
            ),
            const SizedBox(height: 12),
            Text(
              describe(context, error),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: Text(l10n.t('common.retry')),
              ),
            ],
            if (isAuthError) ...[
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => context.push('/auth/login'),
                child: Text(l10n.t('auth.login')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

bool _isConnectionError(String value) {
  final lower = value.toLowerCase();
  return lower.contains('dioexception [connection error]') ||
      lower.contains('xmlhttprequest onerror') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection refused') ||
      lower.contains('connection error');
}

class MinimalCatMark extends StatelessWidget {
  const MinimalCatMark({super.key, this.size = 56, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final social = SocialColors.of(context);
    final effectiveColor = color ?? social.inkTertiary;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _MinimalCatPainter(color: effectiveColor),
      ),
    );
  }
}

class _MinimalCatPainter extends CustomPainter {
  const _MinimalCatPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Minimalist monochrome geometric cat ears + calm oval silhouette.
    final outline = Path()
      ..moveTo(w * 0.23, h * 0.44)
      ..lineTo(w * 0.26, h * 0.20)
      ..lineTo(w * 0.39, h * 0.33)
      ..quadraticBezierTo(w * 0.50, h * 0.30, w * 0.61, h * 0.33)
      ..lineTo(w * 0.74, h * 0.20)
      ..lineTo(w * 0.77, h * 0.44)
      ..cubicTo(w * 0.83, h * 0.56, w * 0.79, h * 0.74, w * 0.65, h * 0.79)
      ..quadraticBezierTo(w * 0.50, h * 0.83, w * 0.35, h * 0.79)
      ..cubicTo(w * 0.21, h * 0.74, w * 0.17, h * 0.56, w * 0.23, h * 0.44);
    canvas.drawPath(outline, paint);

    // Subtle closed-eye calm arcs and nose/whisker marks.
    final leftEye = Path()
      ..moveTo(w * 0.36, h * 0.54)
      ..quadraticBezierTo(w * 0.40, h * 0.51, w * 0.44, h * 0.54);
    final rightEye = Path()
      ..moveTo(w * 0.56, h * 0.54)
      ..quadraticBezierTo(w * 0.60, h * 0.51, w * 0.64, h * 0.54);
    canvas.drawPath(leftEye, paint);
    canvas.drawPath(rightEye, paint);

    // Tiny nose & whiskers.
    canvas.drawLine(
      Offset(w * 0.48, h * 0.61),
      Offset(w * 0.52, h * 0.61),
      paint,
    );
    canvas.drawLine(
      Offset(w * 0.16, h * 0.58),
      Offset(w * 0.27, h * 0.59),
      paint,
    );
    canvas.drawLine(
      Offset(w * 0.17, h * 0.65),
      Offset(w * 0.27, h * 0.64),
      paint,
    );
    canvas.drawLine(
      Offset(w * 0.84, h * 0.58),
      Offset(w * 0.73, h * 0.59),
      paint,
    );
    canvas.drawLine(
      Offset(w * 0.83, h * 0.65),
      Offset(w * 0.73, h * 0.64),
      paint,
    );
  }

  @override
  bool shouldRepaint(_MinimalCatPainter oldDelegate) =>
      oldDelegate.color != color;
}

class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.message,
    this.icon,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final social = SocialColors.of(context);
    final showAction =
        actionLabel != null && actionLabel!.isNotEmpty && onAction != null;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: social.surfaceSubtle.withValues(alpha: 0.85),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: icon == null
                    ? const MinimalCatMark(size: 52)
                    : Icon(icon, size: 28, color: colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            if (showAction) ...[
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                ),
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum SkeletonLayout { rows, profile, account, conversation, groups }

class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.layout = SkeletonLayout.rows, this.top = 8, this.bottom = 12, this.singleColumn = false});
  final SkeletonLayout layout;
  final double top;
  final double bottom;
  final bool singleColumn;
  @override
  Widget build(BuildContext context) {
    final inset = EdgeInsets.fromLTRB(16, top, 16, bottom);
    if (layout == SkeletonLayout.conversation) {
      return ListView.builder(
        padding: inset, reverse: true, physics: const NeverScrollableScrollPhysics(),
        itemCount: 7, itemBuilder: (context, i) => Align(
          alignment: i.isEven ? Alignment.centerLeft : Alignment.centerRight,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460),
            child: FractionallySizedBox(widthFactor: i.isEven ? .72 : .58,
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 6),
                child: ShimmerBox(height: i.isEven ? 64 : 48)))),
        ),
      );
    }
    if (layout == SkeletonLayout.groups) {
      return LayoutBuilder(builder: (_, constraints) => GridView.builder(
        padding: inset,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: singleColumn ? 1 : (constraints.maxWidth / 340).floor().clamp(1, 3),
          mainAxisExtent: 204, mainAxisSpacing: 12, crossAxisSpacing: 12,
        ),
        itemCount: 6,
        itemBuilder: (_, _) => const SurfaceCard(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [ShimmerBox(height: 68), ListTileSkeleton(), ShimmerBox(height: 12, width: 120)],
        )),
      ));
    }
    final header = layout == SkeletonLayout.account || layout == SkeletonLayout.profile;
    return Align(alignment: Alignment.topCenter, child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: AppBreakpoints.contentMaxWidth),
      child: SingleChildScrollView(
        padding: inset, physics: const NeverScrollableScrollPhysics(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (header) const SurfaceCard(child: Column(children: [
            ShimmerBox(height: 80), ListTileSkeleton(), ShimmerBox(height: 16),
          ])),
          if (layout == SkeletonLayout.account)
            for (var i = 0; i < 2; i++) const Padding(
              padding: EdgeInsets.only(top: 12), child: Row(children: [
                Expanded(child: ShimmerBox(height: 84)), SizedBox(width: 12),
                Expanded(child: ShimmerBox(height: 84)),
              ]),
            ),
          for (var i = 0; i < 5; i++)
            if (layout == SkeletonLayout.profile) const PostSkeleton()
            else const ListTileSkeleton(),
        ]),
      ),
    ));
  }
}
