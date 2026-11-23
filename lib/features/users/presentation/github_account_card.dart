import 'package:flutter/material.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/github_oauth_models.dart';
import '../../auth/presentation/github_oauth_dialog.dart';

class GitHubAccountCard extends StatefulWidget {
  const GitHubAccountCard({
    super.key,
    required this.repository,
    required this.isCurrent,
  });

  final AuthRepository repository;
  final bool Function() isCurrent;

  @override
  State<GitHubAccountCard> createState() => _GitHubAccountCardState();
}

class _GitHubAccountCardState extends State<GitHubAccountCard> {
  GitHubLink? _link;
  bool _loaded = false;
  bool _busy = false;
  String? _error;

  bool _isCurrent() => mounted && widget.isCurrent();

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_isCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (_isCurrent()) {
        setState(() => _error = gitHubOAuthError(context, error));
      }
    } finally {
      if (_isCurrent()) setState(() => _busy = false);
    }
  }

  void _apply(GitHubLink? link) {
    if (!_isCurrent()) return;
    setState(() {
      _loaded = true;
      _link = link;
    });
  }

  Future<void> _readLink() => _run(() async {
    _apply(await widget.repository.readGitHubLink());
  });

  Future<void> _linkAccount() => _run(() async {
    final result = await showGitHubOAuth<GitHubLink>(
      context: context,
      repository: widget.repository,
      isCurrent: _isCurrent,
      signIn: false,
      poll: (flow, cancel) =>
          widget.repository.pollGitHubLink(flow, cancelToken: cancel),
    );
    if (result != null) _apply(result);
  });

  Future<void> _unlinkAccount() async {
    if (_busy || !_isCurrent()) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.t('github_oauth.unlink')),
        content: Text(l10n.t('github_oauth.unlink_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.t('github_oauth.unlink')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await widget.repository.removeGitHubLink();
      _apply(null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final link = _link;
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.link_outlined),
        title: Text(l10n.t('github_oauth.title')),
        onExpansionChanged: (open) {
          if (open) _readLink();
        },
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          if (_busy && !_loaded) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (!_loaded && _error != null)
            TextButton(
              onPressed: _busy ? null : _readLink,
              child: Text(l10n.t('common.retry')),
            ),
          if (_loaded && link == null) ...[
            Text(l10n.t('github_oauth.unlinked')),
            OutlinedButton(
              onPressed: _busy ? null : _linkAccount,
              child: Text(l10n.t('github_oauth.link')),
            ),
          ],
          if (_loaded && link != null) ...[
            Text('@${link.login}'),
            OutlinedButton(
              onPressed: _busy ? null : _unlinkAccount,
              child: Text(l10n.t('github_oauth.unlink')),
            ),
          ],
        ],
      ),
    );
  }
}
