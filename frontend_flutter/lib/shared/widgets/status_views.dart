import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../i18n/app_localizations.dart';

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  static String describe(BuildContext context, Object error) {
    final l10n = AppLocalizations.of(context);
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
    final colorScheme = Theme.of(context).colorScheme;
    final showAction =
        actionLabel != null && actionLabel!.isNotEmpty && onAction != null;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? Icons.inbox_outlined,
              size: 64,
              color: colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (showAction) ...[
              const SizedBox(height: 16),
              FilledButton(
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

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});
  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}
