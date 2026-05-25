import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../i18n/app_localizations.dart';

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  static String describe(BuildContext context, Object error) {
    if (error is ApiException) {
      return '[${error.code}] ${error.message}';
    }
    final raw = error.toString();
    if (_isConnectionError(raw)) {
      return AppLocalizations.of(context).t('error.connection');
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isAuthError =
        error is ApiException &&
        ((error as ApiException).code == 40101 ||
            (error as ApiException).statusCode == 401);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 56,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              describe(context, error),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
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
  const EmptyView({super.key, required this.message, this.icon});

  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon ?? Icons.inbox_outlined,
            size: 64,
            color: Theme.of(context).disabledColor,
          ),
          const SizedBox(height: 8),
          Text(message, style: Theme.of(context).textTheme.bodyMedium),
        ],
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
