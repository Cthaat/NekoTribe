import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _account = TextEditingController();
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _otp = TextEditingController();
  final _inviteCode = TextEditingController();
  bool _busy = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _account.dispose();
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    _otp.dispose();
    _inviteCode.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    if (_account.text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      await ref
          .read(authRepositoryProvider)
          .requestOtp(account: _account.text.trim(), purpose: 'register');
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('auth.otp_sent'))));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = ErrorView.describe(context, e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _register() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .register(
            account: _account.text.trim(),
            username: _username.text.trim(),
            displayName: _displayName.text.trim(),
            password: _password.text,
            otpCode: _otp.text.trim(),
            inviteCode: _inviteCode.text.trim().isEmpty
                ? null
                : _inviteCode.text.trim(),
          );
      if (!mounted) return;
      ref.read(authSessionProvider.notifier).markLoggedIn();
      context.go('/feed');
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
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('auth.register'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _account,
                  decoration: InputDecoration(
                    labelText: l10n.t('auth.account'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _otp,
                        decoration: InputDecoration(
                          labelText: l10n.t('auth.otp'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: _sending ? null : _sendOtp,
                      child: _sending
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(l10n.t('auth.send_otp')),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _username,
                  decoration: InputDecoration(
                    labelText: l10n.t('auth.username'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _displayName,
                  decoration: InputDecoration(
                    labelText: l10n.t('auth.display_name'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.t('auth.password'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _inviteCode,
                  decoration: InputDecoration(
                    labelText: l10n.t('auth.invite_code_optional'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _register,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.t('auth.register')),
                ),
                TextButton(
                  onPressed: () => context.go('/auth/login'),
                  child: Text(l10n.t('auth.login')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
