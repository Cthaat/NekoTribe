import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/token_store.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../core/utils/auth_input.dart';
import '../../../core/utils/group_invite.dart';
import '../../../core/utils/group_post_link.dart';
import '../domain/auth_models.dart';
import 'github_oauth_dialog.dart';
import 'passkey_feedback.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.inviteCode, this.groupPostLink});

  final String? inviteCode;
  final GroupPostLink? groupPostLink;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

enum _LoginMethod { password, passkey, gitHub }

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  bool _rememberMe = false;
  _LoginMethod? _pending;
  bool get _busy => _pending != null;
  String? _error;

  @override
  void dispose() {
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() => _submitLogin(_LoginMethod.password);

  Future<void> _loginWithPasskey() => _submitLogin(_LoginMethod.passkey);

  Future<void> _loginWithGitHub() => _submitLogin(_LoginMethod.gitHub);

  Future<void> _submitLogin(_LoginMethod method) async {
    if (_busy) return;
    final account = trimAuthInput(_account.text),
        password = trimAuthInput(_password.text);
    if (method == _LoginMethod.password &&
        (account.isEmpty || password.isEmpty)) {
      return;
    }
    final repo = ref.read(authRepositoryProvider);
    final store = ref.read(tokenStoreProvider);
    final endpoint = store.endpointRevision;
    final startingRevision = repo.sessionRevision;
    final rememberMe = _rememberMe;
    int? submittedRevision = method == _LoginMethod.passkey
        ? startingRevision + 1
        : null;
    bool isActive() =>
        mounted &&
        identical(ref.read(authRepositoryProvider), repo) &&
        identical(ref.read(tokenStoreProvider), store) &&
        store.endpointRevision == endpoint;
    bool isCurrentGitHubFlow() =>
        isActive() &&
        repo.sessionRevision == startingRevision &&
        !repo.isSessionChanging;
    setState(() {
      _pending = method;
      _error = null;
    });
    try {
      V2LoginResult result;
      switch (method) {
        case _LoginMethod.password:
          result = await repo.login(
            account: account,
            password: password,
            rememberMe: rememberMe,
          );
        case _LoginMethod.passkey:
          result = await repo.loginWithPasskey(
            authenticate: ref.read(passkeyClientProvider).authenticate,
            rememberMe: rememberMe,
            isActive: isActive,
          );
        case _LoginMethod.gitHub:
          if (!isCurrentGitHubFlow()) return;
          final receipt = await showGitHubOAuth<V2LoginResult>(
            context: context,
            repository: repo,
            isCurrent: isCurrentGitHubFlow,
            signIn: true,
            poll: (flow, cancel) => repo.pollGitHubLogin(
              flow,
              rememberMe: rememberMe,
              cancelToken: cancel,
            ),
          );
          if (receipt == null || !isCurrentGitHubFlow()) return;
          submittedRevision = startingRevision + 1;
          result = await repo.finishGitHubLogin(receipt, startingRevision);
      }
      if (!isActive() ||
          (submittedRevision != null &&
              repo.sessionRevision != submittedRevision)) {
        return;
      }
      if (result is V2LoginSuccess) {
        ref.read(authSessionProvider.notifier).markLoggedIn();
        unawaited(ref.read(realtimeServiceProvider).connect());
        final link = widget.groupPostLink;
        context.go(
          groupInviteLocation(widget.inviteCode) ??
              (link == null ? '/feed' : groupPostLocation(link)),
        );
      } else if (result is V2TwoFactorRequired) {
        final invite = normalizeGroupInviteCode(widget.inviteCode);
        final link = widget.groupPostLink;
        context.go(
          Uri(
            path: '/auth/2fa',
            queryParameters: invite != null
                ? {'code': invite}
                : link == null
                ? null
                : groupPostLinkQuery(link),
          ).toString(),
          extra: {'challengeId': result.challengeId, 'account': result.account},
        );
      }
    } catch (e) {
      if (!isActive() ||
          (submittedRevision != null &&
              repo.sessionRevision != submittedRevision)) {
        return;
      }
      setState(() {
        _error = switch (method) {
          _LoginMethod.passkey => passkeyError(context, e),
          _LoginMethod.gitHub => gitHubOAuthError(context, e),
          _LoginMethod.password => ErrorView.describe(context, e),
        };
      });
    } finally {
      if (mounted) setState(() => _pending = null);
    }
  }

  Future<void> _openEndpointSettings() async {
    if (_busy) return;
    final store = ref.read(tokenStoreProvider);
    final revision = store.endpointRevision;
    await context.push('/settings/endpoint');
    if (!mounted) return;
    final current = ref.read(tokenStoreProvider);
    if (!identical(store, current) || current.endpointRevision != revision) {
      _password.clear();
      setState(() => _error = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final appBar = AppBar(
      title: Text(l10n.t('auth.login')),
      actions: [
        IconButton(
          tooltip: l10n.t('endpoint.title'),
          onPressed: _busy ? null : _openEndpointSettings,
          icon: const Icon(Icons.dns_outlined),
        ),
      ],
    );
    if (!ref.watch(tokenStoreProvider).supportsSessionStorage) {
      return Scaffold(
        appBar: appBar,
        body: const ErrorView(error: SessionStorageUnavailable()),
      );
    }
    final theme = Theme.of(context);
    final supportsPasskeys = ref.watch(passkeyClientProvider).isSupported;
    return Scaffold(
      appBar: appBar,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth < 420.0
              ? constraints.maxWidth
              : 420.0;
          return Center(
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.12,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          Icons.pets,
                          size: 36,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        l10n.t('app.title'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.t('auth.login'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextField(
                        controller: _account,
                        decoration: InputDecoration(
                          labelText: l10n.t('auth.account'),
                          prefixIcon: const Icon(
                            Icons.person_outline,
                            size: 20,
                          ),
                        ),
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: l10n.t('auth.password'),
                          prefixIcon: const Icon(Icons.lock_outline, size: 20),
                        ),
                        onSubmitted: (_) => _login(),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Checkbox(
                            value: _rememberMe,
                            onChanged: (v) =>
                                setState(() => _rememberMe = v ?? false),
                          ),
                          Expanded(
                            child: Text(
                              l10n.t('auth.remember_me'),
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          TextButton(
                            onPressed: () => context.push('/auth/forgot'),
                            child: Text(l10n.t('auth.forgot_password')),
                          ),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.errorContainer.withValues(
                              alpha: 0.5,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 18,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ? null : _login,
                        child: _busy && _pending != _LoginMethod.gitHub
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(l10n.t('auth.login')),
                      ),
                      if (supportsPasskeys) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _loginWithPasskey,
                          icon: const Icon(Icons.key_outlined),
                          label: Text(l10n.t('passkeys.sign_in')),
                        ),
                      ],
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _loginWithGitHub,
                        icon: const Icon(Icons.open_in_new_outlined),
                        label: Text(l10n.t('github_oauth.sign_in')),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            l10n.t('auth.no_account'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          TextButton(
                            onPressed: () => context.push('/auth/register'),
                            child: Text(l10n.t('auth.register')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
