import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
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

  bool _loading = true;
  bool _busy = false;
  bool _twoFactorEnabled = false;
  String? _error;
  String? _twoFactorSecret;
  String? _qrUri;
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('account.security.title'))),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 12),
                ],
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.verified_user_outlined),
                  title: Text(l10n.t('account.security.setup_2fa')),
                  subtitle: Text(
                    _twoFactorEnabled
                        ? l10n.t('account.security.two_factor_enabled')
                        : l10n.t('account.security.two_factor_disabled'),
                  ),
                ),
                const Divider(),
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
                  Text(
                    l10n.t('account.security.recovery_codes'),
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _recoveryCodes
                        .map(
                          (code) => Chip(
                            label: Text(
                              code,
                              style: const TextStyle(
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
              ],
            ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: password,
          obscureText: true,
          decoration: InputDecoration(
            labelText: l10n.t('account.security.current_password'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy ? null : onStart,
          icon: const Icon(Icons.key_outlined),
          label: Text(l10n.t('account.security.start_2fa')),
        ),
        if (secret != null) ...[
          const SizedBox(height: 24),
          Text(l10n.t('account.security.setup_secret')),
          SelectableText(secret!),
          if (qrUri != null) SelectableText('URI: $qrUri'),
          const SizedBox(height: 12),
          TextField(
            controller: code,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l10n.t('account.security.enter_code'),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => onConfirm(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : onConfirm,
            child: Text(l10n.t('common.confirm')),
          ),
        ],
      ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: password,
          obscureText: true,
          decoration: InputDecoration(
            labelText: l10n.t('account.security.current_password'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: code,
          decoration: InputDecoration(
            labelText: l10n.t('account.security.code_or_recovery'),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: busy ? null : onSubmit,
          icon: const Icon(Icons.shield_outlined),
          label: Text(l10n.t('account.security.disable_2fa')),
        ),
      ],
    );
  }
}
