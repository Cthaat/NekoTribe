import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/motion/skeleton.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../media/presentation/save_attachment_native.dart'
    if (dart.library.js_interop) '../../media/presentation/save_attachment_web.dart';
import '../domain/account_usage.dart';

final _usageProvider = FutureProvider.autoDispose<AccountUsage?>((ref) {
  final session = ref.watch(authSessionProvider);
  final repository = ref.watch(usersRepositoryProvider);
  return session.isAuthenticated ? repository.accountUsage() : null;
});

class AccountResourcesScreen extends ConsumerStatefulWidget {
  const AccountResourcesScreen({super.key, this.quotaFirst = false});

  final bool quotaFirst;

  @override
  ConsumerState<AccountResourcesScreen> createState() =>
      _AccountResourcesScreenState();
}

class _AccountResourcesScreenState
    extends ConsumerState<AccountResourcesScreen> {
  CancelToken? _download;
  late final VoidCallback _stopSessionListener;

  @override
  void initState() {
    super.initState();
    _stopSessionListener = ref.read(tokenStoreProvider).listenSessionChanges(
      () {
        _download?.cancel();
        ref.invalidate(_usageProvider);
      },
    );
  }

  @override
  void dispose() {
    _stopSessionListener();
    _download?.cancel();
    super.dispose();
  }

  Future<void> _save(AccountExportFormat format) async {
    if (_download != null) return;
    final repository = ref.read(usersRepositoryProvider);
    final tokens = ref.read(tokenStoreProvider);
    if (tokens.isSessionChanging) return;
    final cancel = CancelToken();
    setState(() => _download = cancel);
    bool isCurrent() =>
        mounted &&
        !cancel.isCancelled &&
        identical(ref.read(usersRepositoryProvider), repository);
    try {
      await saveAttachment(
        'nekotribe-account.${format.extension}',
        readBytes: () => repository.exportAccount(format, cancelToken: cancel),
        readParts: () async* {
          yield await repository.exportAccount(format, cancelToken: cancel);
        },
        isCurrent: isCurrent,
      );
    } catch (_) {
      if (isCurrent()) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.t('account.resources.export_failed'))),
        );
      }
    } finally {
      if (mounted) setState(() => _download = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final usage = ref.watch(_usageProvider);
    final authenticated = ref.watch(authSessionProvider).isAuthenticated;
    final title = l10n.t(
      widget.quotaFirst
          ? 'account.resources.ai_title'
          : 'account.resources.title',
    );
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppBreakpoints.contentMaxWidth,
          ),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              SkeletonCrossFade(loading: usage.isLoading, child: usage.when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                loading: () => const ListTileSkeleton(),
                error: (error, _) => ErrorView(
                  error: error,
                  onRetry: () => ref.invalidate(_usageProvider),
                ),
                data: (data) =>
                    data == null ? const SizedBox.shrink() : _UsageCard(data),
              )),
              if (authenticated) ...[
                const SizedBox(height: 16),
                Text(
                  l10n.t('account.resources.export'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(l10n.t('account.resources.export_description')),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final format in AccountExportFormat.values)
                      OutlinedButton.icon(
                        onPressed: _download == null
                            ? () => _save(format)
                            : null,
                        icon: const Icon(Icons.download_outlined),
                        label: Text(
                          format == AccountExportFormat.json
                              ? 'JSON'
                              : 'Markdown',
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard(this.usage);
  final AccountUsage usage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final quota = usage.usedUnits == null || usage.limitUnits == null
        ? l10n.t('account.resources.unavailable')
        : l10n
              .t('account.resources.quota_value')
              .replaceAll('{used}', '${usage.usedUnits}')
              .replaceAll('{limit}', '${usage.limitUnits}')
              .replaceAll('{seconds}', '${usage.windowSeconds}');
    final media = l10n
        .t('account.resources.media_value')
        .replaceAll('{files}', '${usage.mediaFiles}')
        .replaceAll('{bytes}', '${usage.mediaBytes}');
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.speed),
            title: Text(l10n.t('account.resources.quota')),
            subtitle: Text(quota),
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: Text(l10n.t('account.resources.media')),
            subtitle: Text(media),
          ),
          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: Text(l10n.t('account.resources.history')),
            subtitle: Text('${usage.conversations}'),
          ),
        ],
      ),
    );
  }
}
