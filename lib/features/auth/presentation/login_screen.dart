import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/token_store.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/theme/tokens.dart';
import '../../../shared/widgets/status_views.dart';
import '../../../shared/widgets/ui/subtle_grid_box.dart';
import '../../../shared/widgets/ui/surface_card.dart';
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
    final isWide = MediaQuery.sizeOf(context).width >= 900;
    final supportsSessionStorage = ref
        .watch(tokenStoreProvider)
        .supportsSessionStorage;
    final endpointButton = IconButton(
      tooltip: l10n.t('endpoint.title'),
      onPressed: _busy ? null : _openEndpointSettings,
      icon: const Icon(Icons.dns_outlined),
    );
    final appBar = AppBar(
      title: isWide ? null : Text(l10n.t('auth.login')),
      actions: [endpointButton],
    );
    if (!supportsSessionStorage) {
      return Scaffold(
        appBar: appBar,
        body: const ErrorView(error: SessionStorageUnavailable()),
      );
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final supportsPasskeys = ref.watch(passkeyClientProvider).isSupported;
    return Scaffold(
      appBar: isWide ? null : appBar,
      body: Builder(
        builder: (context) {
          final formCard = SurfaceCard(
            padding: const EdgeInsets.all(AppGap.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isWide) ...[
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(AppRadius.tile),
                      ),
                      child: Icon(
                        Icons.pets,
                        size: 32,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppGap.lg),
                  Text(
                    l10n.t('app.title'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppGap.xs),
                  Text(
                    l10n.t('auth.login'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.t('auth.login'),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppGap.sm),
                      endpointButton,
                    ],
                  ),
                const SizedBox(height: AppGap.xl),
                TextField(
                  controller: _account,
                  decoration: InputDecoration(
                    labelText: l10n.t('auth.account'),
                    prefixIcon: const Icon(Icons.person_outline, size: 20),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: AppGap.md),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.t('auth.password'),
                    prefixIcon: const Icon(Icons.lock_outline, size: 20),
                  ),
                  onSubmitted: (_) => _login(),
                ),
                const SizedBox(height: AppGap.xs),
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
                  const SizedBox(height: AppGap.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppGap.md,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 18,
                          color: scheme.onErrorContainer,
                        ),
                        const SizedBox(width: AppGap.sm),
                        Expanded(
                          child: Text(
                            _error!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppGap.lg),
                FilledButton(
                  onPressed: _busy ? null : _login,
                  child: _busy && _pending != _LoginMethod.gitHub
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.t('auth.login')),
                ),
                if (supportsPasskeys) ...[
                  const SizedBox(height: AppGap.sm),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _loginWithPasskey,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      shape: const StadiumBorder(),
                    ),
                    icon: const Icon(Icons.key_outlined),
                    label: Text(l10n.t('passkeys.sign_in')),
                  ),
                ],
                const SizedBox(height: AppGap.sm),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _loginWithGitHub,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    shape: const StadiumBorder(),
                  ),
                  icon: const Icon(Icons.open_in_new_outlined),
                  label: Text(l10n.t('github_oauth.sign_in')),
                ),
                const SizedBox(height: AppGap.md),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      l10n.t('auth.no_account'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
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
          );

          if (isWide) {
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppGap.xl),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 440),
                          child: SubtleGridBox(
                            backgroundColor: SocialColors.of(
                              context,
                            ).surfaceSubtle,
                            borderRadius: BorderRadius.circular(
                              AppRadius.canvas,
                            ),
                            padding: const EdgeInsets.all(AppGap.xl),
                            child: Center(
                              child: SurfaceCard(
                                radius: AppRadius.canvas,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 32,
                                  vertical: 28,
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 68,
                                      height: 68,
                                        decoration: BoxDecoration(
                                          color: SocialColors.of(
                                            context,
                                          ).primarySoft,
                                          borderRadius: BorderRadius.circular(
                                            AppRadius.tile,
                                          ),
                                        ),
                                      alignment: Alignment.center,
                                      child: Icon(
                                        Icons.pets_rounded,
                                        size: 36,
                                        color: scheme.primary,
                                      ),
                                    ),
                                    const SizedBox(height: AppGap.lg),
                                    Text(
                                      l10n.t('app.title'),
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.headlineSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                            color: scheme.onSurface,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppGap.xl),
                      SizedBox(width: 420, child: formCard),
                    ],
                  ),
                ),
              ),
            );
          }

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppGap.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: formCard,
              ),
            ),
          );
        },
      ),
    );
  }
}
