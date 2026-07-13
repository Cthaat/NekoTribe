import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';

class SecurityScreen extends ConsumerStatefulWidget {
  const SecurityScreen({super.key});

  @override
  ConsumerState<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends ConsumerState<SecurityScreen> {
  final _setupPassword = TextEditingController();
  final _setupCode = TextEditingController();
  final _disablePassword = TextEditingController();
  final _disableCode = TextEditingController();
  final _email = TextEditingController();
  final _emailCode = TextEditingController();
  final _deletePassword = TextEditingController();
  final _deleteConfirmation = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  bool _twoFactorEnabled = false;
  String? _error;
  String? _twoFactorSecret;
  String? _qrUri;
  String? _emailVerificationId;
  List<String> _recoveryCodes = const [];

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _setupPassword.dispose();
    _setupCode.dispose();
    _disablePassword.dispose();
    _disableCode.dispose();
    _email.dispose();
    _emailCode.dispose();
    _deletePassword.dispose();
    _deleteConfirmation.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await ref.read(usersRepositoryProvider).getSettings();
      if (!mounted) return;
      setState(() {
        _twoFactorEnabled = settings.twoFactorEnabled ?? false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ErrorView.describe(context, e);
        _loading = false;
      });
    }
  }

  Future<void> _startSetup() async {
    final l10n = AppLocalizations.of(context);
    final password = _setupPassword.text.trim();
    if (password.isEmpty) {
      setState(() => _error = l10n.t('account.security.password_required'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _recoveryCodes = const [];
    });
    try {
      final data = await ref
          .read(usersRepositoryProvider)
          .setupTwoFactor(password: password);
      if (!mounted) return;
      setState(() {
        _twoFactorSecret = (data['secret'] as String?) ?? '';
        _qrUri = data['otpauth_url'] as String?;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmSetup() async {
    final code = _setupCode.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await ref
          .read(usersRepositoryProvider)
          .confirmTwoFactor(code: code);
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('account.security.enabled'))),
      );
      setState(() {
        _twoFactorEnabled = data['enabled'] == true;
        _twoFactorSecret = null;
        _qrUri = null;
        _setupPassword.clear();
        _setupCode.clear();
        _recoveryCodes = (data['recovery_codes'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable2fa() async {
    final l10n = AppLocalizations.of(context);
    final password = _disablePassword.text.trim();
    final code = _disableCode.text.trim();
    if (password.isEmpty || code.isEmpty) {
      setState(() => _error = l10n.t('account.security.disable_required'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(usersRepositoryProvider)
          .disableTwoFactor(password: password, code: code);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('account.security.disabled'))),
      );
      setState(() {
        _twoFactorEnabled = false;
        _disablePassword.clear();
        _disableCode.clear();
        _recoveryCodes = const [];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendEmailOtp() async {
    final l10n = AppLocalizations.of(context);
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = l10n.t('account.security.email_required'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final otp = await ref
          .read(authRepositoryProvider)
          .requestOtp(account: email, purpose: 'change_email');
      if (!mounted) return;
      setState(() => _emailVerificationId = otp.verificationId);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('auth.otp_sent'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeEmail() async {
    final l10n = AppLocalizations.of(context);
    final email = _email.text.trim();
    final code = _emailCode.text.trim();
    final verificationId = _emailVerificationId;
    if (email.isEmpty || code.isEmpty) {
      setState(() => _error = l10n.t('account.security.email_change_required'));
      return;
    }
    if (verificationId == null || verificationId.isEmpty) {
      setState(() => _error = l10n.t('auth.otp_required'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(usersRepositoryProvider)
          .changeEmail(
            newEmail: email,
            verificationId: verificationId,
            code: code,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('account.security.email_changed'))),
      );
      await _logoutAndReturnToLogin();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final l10n = AppLocalizations.of(context);
    final password = _deletePassword.text.trim();
    final confirmation = _deleteConfirmation.text.trim();
    if (password.isEmpty || confirmation.isEmpty) {
      setState(() => _error = l10n.t('account.security.delete_required'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(usersRepositoryProvider)
          .deleteAccount(password: password, confirmation: confirmation);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('account.security.account_deleted'))),
      );
      await _logoutAndReturnToLogin();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logoutAndReturnToLogin() async {
    await ref.read(authRepositoryProvider).logout();
    if (!mounted) return;
    try {
      await ref.read(realtimeServiceProvider).disconnect();
    } catch (_) {}
    ref.read(notificationsUnreadProvider.notifier).set(0);
    ref.read(authSessionProvider.notifier).markLoggedOut();
    context.go('/auth/login');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('account.security.title'))),
      body: _loading
          ? const LoadingView()
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppBreakpoints.contentMaxWidth,
                ),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_error != null) ...[
                      _ErrorBanner(message: _error!),
                      const SizedBox(height: 12),
                    ],
                    _TwoFactorStatusCard(enabled: _twoFactorEnabled),
                    const SizedBox(height: 16),
                    if (_twoFactorEnabled)
                      _DisableTwoFactorForm(
                        password: _disablePassword,
                        code: _disableCode,
                        busy: _busy,
                        onSubmit: _disable2fa,
                      )
                    else
                      _SetupTwoFactorForm(
                        password: _setupPassword,
                        code: _setupCode,
                        busy: _busy,
                        secret: _twoFactorSecret,
                        qrUri: _qrUri,
                        onStart: _startSetup,
                        onConfirm: _confirmSetup,
                      ),
                    if (_recoveryCodes.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      _RecoveryCodesCard(codes: _recoveryCodes),
                    ],
                    const SizedBox(height: 24),
                    _SectionLabel(text: l10n.t('account.security.change_email_title')),
                    const SizedBox(height: 8),
                    _EmailChangeForm(
                      email: _email,
                      code: _emailCode,
                      busy: _busy,
                      hasVerificationId: _emailVerificationId != null,
                      onSendCode: _sendEmailOtp,
                      onSubmit: _changeEmail,
                    ),
                    const SizedBox(height: 24),
                    _SectionLabel(
                      text: l10n.t('account.security.delete_account_title'),
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 8),
                    _DeleteAccountForm(
                      password: _deletePassword,
                      confirmation: _deleteConfirmation,
                      busy: _busy,
                      onSubmit: _deleteAccount,
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(
        color: color ?? theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
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
              message,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }
}

class _TwoFactorStatusCard extends StatelessWidget {
  const _TwoFactorStatusCard({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tint = enabled ? theme.colorScheme.primary : theme.colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tint.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              enabled ? Icons.verified_user : Icons.shield_outlined,
              color: tint,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.t('account.security.setup_2fa'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  enabled
                      ? l10n.t('account.security.two_factor_enabled')
                      : l10n.t('account.security.two_factor_disabled'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              enabled
                  ? l10n.t('account.security.status_on')
                  : l10n.t('account.security.status_off'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: tint,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecoveryCodesCard extends StatelessWidget {
  const _RecoveryCodesCard({required this.codes});
  final List<String> codes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
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
                Icons.vpn_key_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.t('account.security.recovery_codes'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.t('account.security.recovery_codes_hint'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: codes
                .map(
                  (code) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.2),
                      ),
                    ),
                    child: SelectableText(
                      code,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        ],
      ),
    );
  }
}

class _FormCard extends StatelessWidget {
  const _FormCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.dividerColor),
      ),
      child: child,
    );
  }
}

class _SetupTwoFactorForm extends StatelessWidget {
  const _SetupTwoFactorForm({
    required this.password,
    required this.code,
    required this.busy,
    required this.secret,
    required this.qrUri,
    required this.onStart,
    required this.onConfirm,
  });

  final TextEditingController password;
  final TextEditingController code;
  final bool busy;
  final String? secret;
  final String? qrUri;
  final VoidCallback onStart;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return _FormCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.t('account.security.current_password'),
              prefixIcon: const Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : onStart,
              icon: const Icon(Icons.key_outlined),
              label: Text(l10n.t('account.security.start_2fa')),
            ),
          ),
          if (secret != null) ...[
            const SizedBox(height: 20),
            Divider(height: 1, color: theme.dividerColor),
            const SizedBox(height: 16),
            Text(
              l10n.t('account.security.setup_secret'),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                secret!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (qrUri != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                'URI: $qrUri',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: code,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l10n.t('account.security.enter_code'),
                prefixIcon: const Icon(Icons.pin_outlined),
              ),
              onSubmitted: (_) => onConfirm(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy ? null : onConfirm,
                icon: const Icon(Icons.check_circle_outline),
                label: Text(l10n.t('common.confirm')),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DisableTwoFactorForm extends StatelessWidget {
  const _DisableTwoFactorForm({
    required this.password,
    required this.code,
    required this.busy,
    required this.onSubmit,
  });

  final TextEditingController password;
  final TextEditingController code;
  final bool busy;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _FormCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.t('account.security.current_password'),
              prefixIcon: const Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: code,
            decoration: InputDecoration(
              labelText: l10n.t('account.security.code_or_recovery'),
              prefixIcon: const Icon(Icons.pin_outlined),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : onSubmit,
              icon: const Icon(Icons.shield_outlined),
              label: Text(l10n.t('account.security.disable_2fa')),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmailChangeForm extends StatelessWidget {
  const _EmailChangeForm({
    required this.email,
    required this.code,
    required this.busy,
    required this.hasVerificationId,
    required this.onSendCode,
    required this.onSubmit,
  });

  final TextEditingController email;
  final TextEditingController code;
  final bool busy;
  final bool hasVerificationId;
  final VoidCallback onSendCode;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return _FormCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.t('account.security.change_email_hint'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('security-email-field'),
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: l10n.t('account.security.new_email'),
              prefixIcon: const Icon(Icons.alternate_email),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('security-email-code'),
            controller: code,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l10n.t('auth.otp'),
              prefixIcon: const Icon(Icons.pin_outlined),
              helperText: hasVerificationId
                  ? l10n.t('account.security.email_code_sent')
                  : null,
            ),
            onSubmitted: (_) => onSubmit(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : onSendCode,
                  icon: const Icon(Icons.mark_email_read_outlined),
                  label: Text(l10n.t('auth.send_otp')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : onSubmit,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(l10n.t('account.security.change_email')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.t('account.security.email_relogin_hint'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeleteAccountForm extends StatelessWidget {
  const _DeleteAccountForm({
    required this.password,
    required this.confirmation,
    required this.busy,
    required this.onSubmit,
  });

  final TextEditingController password;
  final TextEditingController confirmation;
  final bool busy;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.error.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.t('account.security.delete_account_hint'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('security-delete-password'),
            controller: password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.t('account.security.current_password'),
              prefixIcon: const Icon(Icons.lock_outline),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('security-delete-confirmation'),
            controller: confirmation,
            decoration: InputDecoration(
              labelText: l10n.t('account.security.delete_confirmation'),
              prefixIcon: const Icon(Icons.text_fields),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : onSubmit,
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.error,
                foregroundColor: colorScheme.onError,
              ),
              icon: const Icon(Icons.delete_forever_outlined),
              label: Text(l10n.t('account.security.delete_account')),
            ),
          ),
        ],
      ),
    );
  }
}
