import 'package:flutter/material.dart';
import '../../../core/utils/auth_input.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/responsive.dart';
import '../../../shared/widgets/status_views.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/otp_send_cooldown.dart';
import 'github_account_card.dart';
import 'passkey_management_card.dart';

class SecurityScreen extends ConsumerStatefulWidget {
  const SecurityScreen({super.key});

  @override
  ConsumerState<SecurityScreen> createState() => _SecuritySessionGateState();
}

class _SecuritySessionGateState extends ConsumerState<SecurityScreen> {
  late AuthRepository _owner;
  late int _ownerRevision;
  AuthRepository? _observed;
  VoidCallback? _stopObserving;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _owner = ref.read(authRepositoryProvider);
    _ownerRevision = _owner.sessionRevision;
    _expired = _owner.isSessionChanging;
    _observe(_owner);
  }

  void _observe(AuthRepository auth) {
    if (identical(_observed, auth)) return;
    _stopObserving?.call();
    _observed = auth;
    _stopObserving = auth.listenSessionChanges(() {
      if (!mounted) return;
      setState(() {
        if (!identical(auth, _owner) ||
            auth.sessionRevision != _ownerRevision ||
            auth.isSessionChanging) {
          _expired = true;
        }
      });
    });
  }

  void _reopen() {
    final auth = ref.read(authRepositoryProvider);
    if (auth.isSessionChanging) return;
    setState(() {
      _owner = auth;
      _ownerRevision = auth.sessionRevision;
      _expired = false;
    });
  }

  @override
  void dispose() {
    _stopObserving?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authRepositoryProvider);
    _observe(auth);
    if (!identical(auth, _owner) ||
        auth.sessionRevision != _ownerRevision ||
        auth.isSessionChanging) {
      _expired = true;
    }
    if (!_expired) {
      return _SecurityScreenBody(onSessionCleared: _finishSessionClear);
    }
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('account.security.title'))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.t('account.security.session_changed')),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: auth.isSessionChanging ? null : _reopen,
              child: Text(l10n.t('account.security.reopen')),
            ),
          ],
        ),
      ),
    );
  }

  void _finishSessionClear(AuthRepository auth, SessionClearReceipt receipt) {
    if (!mounted ||
        !identical(ref.read(authRepositoryProvider), auth) ||
        !auth.isCurrentReceipt(receipt)) {
      return;
    }
    context.go('/auth/login');
  }
}

class _SecurityScreenBody extends ConsumerStatefulWidget {
  const _SecurityScreenBody({required this.onSessionCleared});
  final void Function(AuthRepository auth, SessionClearReceipt receipt)
  onSessionCleared;
  @override
  ConsumerState<_SecurityScreenBody> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends ConsumerState<_SecurityScreenBody> {
  late AuthRepository _owner;
  late int _ownerRevision;
  final _setupPassword = TextEditingController();
  final _setupCode = TextEditingController();
  final _disablePassword = TextEditingController();
  final _disableCode = TextEditingController();
  final _email = TextEditingController();
  final _emailCode = TextEditingController();
  final _deletePassword = TextEditingController();
  final _deleteConfirmation = TextEditingController();

  bool _loading = false;
  bool _busy = false;
  bool? _twoFactorEnabled;
  String? _error;
  String? _twoFactorSecret;
  String? _qrUri;
  String? _emailVerificationId;
  String? _emailVerificationAccount;
  int? _emailVerificationRevision;
  int _emailOtpVersion = 0;
  final _emailOtpCooldown = OtpSendCooldown();
  int? _emailOtpPendingVersion;
  String _emailAccount = '';
  List<String> _recoveryCodes = const [];

  @override
  void initState() {
    super.initState();
    _owner = ref.read(authRepositoryProvider);
    _ownerRevision = _owner.sessionRevision;
    _email.addListener(_emailChanged);
    _loadStatus();
  }

  @override
  void dispose() {
    _emailOtpVersion++;
    _emailOtpCooldown.cancel();
    _email.removeListener(_emailChanged);
    _twoFactorSecret = null;
    _qrUri = null;
    _recoveryCodes = const [];
    _emailVerificationId = null;
    _emailVerificationAccount = null;
    _emailVerificationRevision = null;
    for (final controller in [
      _setupPassword,
      _setupCode,
      _disablePassword,
      _disableCode,
      _email,
      _emailCode,
      _deletePassword,
      _deleteConfirmation,
    ]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadStatus() async {
    if (_loading || _busy || !_isSecurityCurrent(_owner, _ownerRevision)) {
      return;
    }
    final auth = ref.read(authRepositoryProvider),
        revision = ref.read(authRepositoryProvider).sessionRevision;
    setState(() {
      _loading = true;
      _error = null;
      _twoFactorEnabled = null;
      _twoFactorSecret = null;
      _qrUri = null;
      _recoveryCodes = const [];
    });
    try {
      final settings = await ref.read(usersRepositoryProvider).getSettings();
      if (!_isSecurityCurrent(auth, revision)) return;
      setState(() {
        _twoFactorEnabled = settings.twoFactorEnabled;
        _loading = false;
      });
    } catch (e) {
      if (!_isSecurityCurrent(auth, revision)) return;
      setState(() {
        _error = ErrorView.describe(context, e);
        _loading = false;
      });
    }
  }

  Future<void> _startSetup() async {
    if (_twoFactorEnabled != false ||
        _busy ||
        !_isSecurityCurrent(_owner, _ownerRevision)) {
      return;
    }
    final auth = ref.read(authRepositoryProvider),
        revision = ref.read(authRepositoryProvider).sessionRevision;
    final l10n = AppLocalizations.of(context);
    final password = trimAuthInput(_setupPassword.text);
    if (password.isEmpty) {
      setState(() => _error = l10n.t('account.security.password_required'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _twoFactorSecret = null;
      _qrUri = null;
      _setupCode.clear();
      _recoveryCodes = const [];
    });
    try {
      final data = await ref
          .read(usersRepositoryProvider)
          .setupTwoFactor(password: password);
      if (!_isSecurityCurrent(auth, revision)) return;
      setState(() {
        _twoFactorSecret = data.secret;
        _qrUri = data.otpauthUrl;
      });
    } catch (e) {
      if (!_isSecurityCurrent(auth, revision)) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (_isSecurityCurrent(auth, revision)) setState(() => _busy = false);
    }
  }

  Future<void> _confirmSetup() async {
    if (_twoFactorEnabled != false ||
        _twoFactorSecret == null ||
        _busy ||
        !_isSecurityCurrent(_owner, _ownerRevision)) {
      return;
    }
    final auth = ref.read(authRepositoryProvider),
        revision = ref.read(authRepositoryProvider).sessionRevision;
    final code = trimAuthInput(_setupCode.text);
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await ref
          .read(usersRepositoryProvider)
          .confirmTwoFactor(code: code);
      if (!_isSecurityCurrent(auth, revision)) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('account.security.enabled'))),
      );
      setState(() {
        _twoFactorEnabled = data.enabled;
        _twoFactorSecret = null;
        _qrUri = null;
        _setupPassword.clear();
        _setupCode.clear();
        _recoveryCodes = data.recoveryCodes;
      });
    } catch (e) {
      if (!_isSecurityCurrent(auth, revision)) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (_isSecurityCurrent(auth, revision)) setState(() => _busy = false);
    }
  }

  Future<void> _disable2fa() async {
    if (_twoFactorEnabled != true ||
        _busy ||
        !_isSecurityCurrent(_owner, _ownerRevision)) {
      return;
    }
    final auth = ref.read(authRepositoryProvider),
        revision = ref.read(authRepositoryProvider).sessionRevision;
    final l10n = AppLocalizations.of(context);
    final password = trimAuthInput(_disablePassword.text);
    final code = trimAuthInput(_disableCode.text);
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
      if (!_isSecurityCurrent(auth, revision)) return;
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
      if (!_isSecurityCurrent(auth, revision)) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (_isSecurityCurrent(auth, revision)) setState(() => _busy = false);
    }
  }

  bool _isSecurityCurrent(AuthRepository auth, int revision) =>
      mounted &&
      identical(_owner, auth) &&
      _ownerRevision == revision &&
      !auth.isSessionChanging &&
      identical(ref.read(authRepositoryProvider), auth) &&
      auth.sessionRevision == revision;

  void _emailChanged() {
    final account = trimAuthInput(_email.text);
    if (account == _emailAccount) return;
    _emailAccount = account;
    _invalidateEmailVerification();
  }

  void _invalidateEmailVerification() {
    _emailOtpVersion++;
    _emailOtpCooldown.cancel();
    _emailCode.clear();
    setState(() {
      _emailVerificationId = null;
      _emailVerificationAccount = null;
      _emailVerificationRevision = null;
      if (_emailOtpPendingVersion != null) _busy = false;
      _emailOtpPendingVersion = null;
    });
  }

  bool _isEmailOtpCurrent(
    int version,
    String account,
    AuthRepository auth,
    int revision,
  ) {
    return _isSecurityCurrent(auth, revision) &&
        version == _emailOtpVersion &&
        trimAuthInput(_email.text) == account &&
        identical(ref.read(authRepositoryProvider), auth) &&
        auth.sessionRevision == revision;
  }

  Future<void> _sendEmailOtp() async {
    if (_busy ||
        _emailOtpCooldown.remaining > 0 ||
        !_isSecurityCurrent(_owner, _ownerRevision)) {
      return;
    }
    final auth = ref.read(authRepositoryProvider),
        revision = ref.read(authRepositoryProvider).sessionRevision;
    final l10n = AppLocalizations.of(context);
    final email = trimAuthInput(_email.text);
    if (email.isEmpty) {
      setState(() => _error = l10n.t('account.security.email_required'));
      return;
    }
    if (!validNewEmail(email)) {
      setState(() => _error = l10n.t('auth.email_invalid'));
      return;
    }
    final previousId =
        _emailVerificationAccount == email &&
            _emailVerificationRevision == revision
        ? _emailVerificationId
        : null;
    final version = ++_emailOtpVersion;
    setState(() {
      _emailOtpPendingVersion = version;
      _busy = true;
      _error = null;
      _emailVerificationId = null;
      _emailVerificationAccount = null;
      _emailVerificationRevision = null;
    });
    try {
      final otp = await auth.requestOtp(
        account: email,
        purpose: 'change_email',
      );
      if (!_isEmailOtpCurrent(version, email, auth, revision)) return;
      if (otp.account != email || otp.verificationId.trim().isEmpty) {
        throw const FormatException('Invalid OTP response');
      }
      _emailCode.clear();
      setState(() {
        _emailOtpCooldown.start(
          otpSendCooldownSeconds,
          _refreshEmailOtpCooldown,
        );
        _emailVerificationId = otp.verificationId;
        _emailVerificationAccount = email;
        _emailVerificationRevision = revision;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('auth.otp_sent'))));
    } catch (e) {
      if (!_isEmailOtpCurrent(version, email, auth, revision)) return;
      final retry = otpRetryDelay(e);
      if (retry == null) _emailCode.clear();
      setState(() {
        if (retry != null) {
          _emailOtpCooldown.start(retry, _refreshEmailOtpCooldown);
          _emailVerificationId = previousId;
          _emailVerificationAccount = previousId == null ? null : email;
          _emailVerificationRevision = previousId == null ? null : revision;
        }
        _error = ErrorView.describe(context, e);
      });
    } finally {
      if (mounted && _emailOtpPendingVersion == version) {
        setState(() {
          _emailOtpPendingVersion = null;
          _busy = false;
        });
      }
    }
  }

  void _refreshEmailOtpCooldown() {
    if (mounted) setState(() {});
  }

  Future<void> _changeEmail() async {
    if (_busy || !_isSecurityCurrent(_owner, _ownerRevision)) return;
    final auth = ref.read(authRepositoryProvider),
        sessionRevision = ref.read(authRepositoryProvider).sessionRevision;
    final l10n = AppLocalizations.of(context);
    final email = trimAuthInput(_email.text);
    final code = trimAuthInput(_emailCode.text);
    final verificationId = _emailVerificationId;
    final otpVersion = _emailOtpVersion;
    if (!validNewEmail(email)) {
      setState(() => _error = l10n.t('auth.email_invalid'));
      return;
    }
    if (email.isEmpty || code.isEmpty) {
      setState(() => _error = l10n.t('account.security.email_change_required'));
      return;
    }
    if (verificationId == null ||
        verificationId.isEmpty ||
        _emailVerificationAccount != email ||
        _emailVerificationRevision != sessionRevision ||
        !_isEmailOtpCurrent(otpVersion, email, auth, sessionRevision)) {
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
      if (!_isEmailOtpCurrent(otpVersion, email, auth, sessionRevision)) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('account.security.email_changed'))),
      );
      await _logoutAndReturnToLogin(auth, sessionRevision);
    } catch (e) {
      if (!_isEmailOtpCurrent(otpVersion, email, auth, sessionRevision)) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    if (_busy || !_isSecurityCurrent(_owner, _ownerRevision)) return;
    final auth = ref.read(authRepositoryProvider),
        sessionRevision = ref.read(authRepositoryProvider).sessionRevision;
    final l10n = AppLocalizations.of(context);
    final password = trimAuthInput(_deletePassword.text);
    final confirmation = trimAuthInput(_deleteConfirmation.text);
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
      if (!_isSecurityCurrent(auth, sessionRevision)) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.t('account.security.account_deleted'))),
      );
      final finish = widget.onSessionCleared;
      final receipt = await auth.clearAfterCredentialMutation(sessionRevision);
      if (receipt != null) finish(auth, receipt);
    } catch (e) {
      if (!_isSecurityCurrent(auth, sessionRevision)) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logoutAndReturnToLogin(
    AuthRepository repository,
    int expectedRevision,
  ) async {
    if (repository.sessionRevision != expectedRevision) return;
    final finish = widget.onSessionCleared;
    final receipt = await repository.logout();
    if (receipt != null) finish(repository, receipt);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final displayedRecoveryCodes = _recoveryCodes;
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
                    _TwoFactorStatusCard(
                      enabled: _twoFactorEnabled,
                      onReload: _busy ? null : _loadStatus,
                    ),
                    const SizedBox(height: 16),
                    if (_twoFactorEnabled == true)
                      _DisableTwoFactorForm(
                        password: _disablePassword,
                        code: _disableCode,
                        busy: _busy,
                        onSubmit: _disable2fa,
                      )
                    else if (_twoFactorEnabled == false)
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
                      _RecoveryCodesCard(
                        codes: displayedRecoveryCodes,
                        isCurrent: () =>
                            _isSecurityCurrent(_owner, _ownerRevision) &&
                            !_loading &&
                            !_busy &&
                            _twoFactorEnabled == true &&
                            identical(_recoveryCodes, displayedRecoveryCodes),
                      ),
                    ],
                    const SizedBox(height: 24),
                    PasskeyManagementCard(
                      repository: _owner,
                      isCurrent: () =>
                          _isSecurityCurrent(_owner, _ownerRevision),
                    ),
                    const SizedBox(height: 8),
                    GitHubAccountCard(
                      repository: _owner,
                      isCurrent: () =>
                          _isSecurityCurrent(_owner, _ownerRevision),
                    ),
                    const SizedBox(height: 24),
                    _SectionLabel(
                      text: l10n.t('account.security.change_email_title'),
                    ),
                    const SizedBox(height: 8),
                    _EmailChangeForm(
                      email: _email,
                      code: _emailCode,
                      busy: _busy,
                      sendCooldown: _emailOtpCooldown.remaining,
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
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
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
  const _TwoFactorStatusCard({required this.enabled, required this.onReload});
  final bool? enabled;
  final VoidCallback? onReload;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tint = enabled == true
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;
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
              enabled == true ? Icons.verified_user : Icons.shield_outlined,
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
                  enabled == null
                      ? l10n.t('account.security.status_unknown')
                      : enabled == true
                      ? l10n.t('account.security.two_factor_enabled')
                      : l10n.t('account.security.two_factor_disabled'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('security-reload-status'),
            onPressed: onReload,
            tooltip: l10n.t('account.security.reload_status'),
            icon: const Icon(Icons.refresh),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              enabled == null
                  ? l10n.t('account.security.status_unknown_short')
                  : enabled == true
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
  const _RecoveryCodesCard({required this.codes, required this.isCurrent});
  final List<String> codes;
  final bool Function() isCurrent;

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
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: () async {
                if (!context.mounted || !isCurrent()) return;
                await Clipboard.setData(ClipboardData(text: codes.join('\n')));
                if (!context.mounted || !isCurrent()) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      l10n.t('account.security.recovery_codes_copied'),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.copy_all_outlined, size: 16),
              label: Text(l10n.t('account.security.recovery_codes_copy_all')),
            ),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
    required this.sendCooldown,
    required this.hasVerificationId,
    required this.onSendCode,
    required this.onSubmit,
  });

  final TextEditingController email;
  final TextEditingController code;
  final bool busy;
  final int sendCooldown;
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
                  onPressed: busy || sendCooldown > 0 ? null : onSendCode,
                  icon: const Icon(Icons.mark_email_read_outlined),
                  label: Text(
                    sendCooldown > 0
                        ? l10n
                              .t('auth.otp_retry_seconds')
                              .replaceAll('{seconds}', sendCooldown.toString())
                        : l10n.t('auth.send_otp'),
                  ),
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
