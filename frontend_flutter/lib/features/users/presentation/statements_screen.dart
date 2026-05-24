import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_response.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../domain/user_models.dart';

class StatementsScreen extends ConsumerStatefulWidget {
  const StatementsScreen({super.key});

  @override
  ConsumerState<StatementsScreen> createState() => _StatementsScreenState();
}

class _StatementsScreenState extends ConsumerState<StatementsScreen> {
  List<V2AccountStatement> _items = [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final PagedResult<V2AccountStatement> page = await ref
          .read(usersRepositoryProvider)
          .statements();
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _appeal(V2AccountStatement statement) async {
    final controller = TextEditingController();
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.t('account.statements.submit_appeal')),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: l10n.t('account.statements.appeal_hint'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l10n.t('common.submit')),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    try {
      await ref
          .read(moderationApiProvider)
          .submitAppeal(statementId: statement.statementId, message: result);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('account.statements.appeal_submitted'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat.yMd().add_Hm().format(dt.toLocal());
  }

  Color _statusColor(BuildContext ctx, String status) {
    final cs = Theme.of(ctx).colorScheme;
    switch (status) {
      case 'active':
        return cs.error;
      case 'rescinded':
        return cs.tertiary;
      case 'expired':
        return cs.outline;
      default:
        return cs.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('account.statements.title'))),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : _items.isEmpty
          ? EmptyView(message: l10n.t('account.statements.empty'))
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _items.length,
                    itemBuilder: (_, i) {
                      final s = _items[i];
                      final color = _statusColor(context, s.status);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: theme.cardTheme.color,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: theme.dividerColor),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.gavel,
                                    size: 18,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      s.title.isEmpty ? s.type : s.title,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: color.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      s.status,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: color,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                s.message,
                                style: theme.textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Icon(
                                    Icons.schedule,
                                    size: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _formatDate(s.createdAt),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (s.status == 'active')
                                    TextButton.icon(
                                      onPressed: () => _appeal(s),
                                      icon: const Icon(
                                        Icons.forum_outlined,
                                        size: 16,
                                      ),
                                      label: Text(
                                        l10n.t('account.statements.appeal'),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }
}
