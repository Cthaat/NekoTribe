import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/ai_operations_summary.dart';

final _overview = FutureProvider.autoDispose<AiOpsSummary?>((ref) {
  final session = ref.watch(authSessionProvider);
  final api = ref.watch(moderationApiProvider);
  final stop = ref
      .watch(tokenStoreProvider)
      .listenSessionChanges(ref.invalidateSelf);
  ref.onDispose(stop);
  return session.isAuthenticated ? api.aiOperations() : null;
});

class AiOperationsTab extends ConsumerWidget {
  const AiOperationsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(_overview);
    final l10n = AppLocalizations.of(context);
    String label(String key) => l10n.t('moderation.aiOps.$key');
    void reload() => ref.invalidate(_overview);
    return result.when(
      skipLoadingOnRefresh: false,
      skipLoadingOnReload: false,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorView(error: error, onRetry: reload),
      data: (summary) {
        if (summary == null) return const SizedBox.shrink();
        final quota = summary.quotaUsed == null || summary.quotaLimit == null
            ? label('unavailable')
            : '${summary.quotaUsed} / ${summary.quotaLimit} · ${summary.windowSeconds} s';
        return RefreshIndicator(
          onRefresh: () async => ref.refresh(_overview.future),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                leading: const Icon(Icons.monitor_heart_outlined),
                title: Text('${label('backend')} ${summary.backend}'),
                subtitle: Text(
                  '${label('revision')} ${summary.revision ?? label('unavailable')}',
                ),
                trailing: IconButton(
                  onPressed: reload,
                  tooltip: l10n.t('common.refresh'),
                  icon: const Icon(Icons.refresh),
                ),
              ),
              Card(
                child: Column(
                  children: [
                    for (final model in summary.models)
                      ListTile(
                        title: Text(label(model.purpose)),
                        subtitle: model.model == null
                            ? null
                            : Text(
                                [
                                  model.model!,
                                  if (model.version != null) model.version!,
                                ].join(' · '),
                              ),
                        trailing: Text(label(model.state)),
                      ),
                  ],
                ),
              ),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      title: Text(label('quota')),
                      subtitle: Text(quota),
                    ),
                    ListTile(
                      title: Text(label('index')),
                      subtitle: Text(
                        summary.indexPoints == null
                            ? label('unavailable')
                            : '${label('points')} ${summary.indexPoints} · ${label(summary.indexPhase ?? 'unavailable')}',
                      ),
                    ),
                    ListTile(
                      title: Text(label('feedback')),
                      subtitle: Text(
                        '${label('helpful')} ${summary.helpful} · ${label('incorrect')} ${summary.incorrect} · ${label('insufficient')} ${summary.insufficient}',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
