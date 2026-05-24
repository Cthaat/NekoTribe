import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _account = TextEditingController();
  final _otp = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  String? _verificationId;
  bool _busy = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _account.dispose();
    _otp.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    if (_account.text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      final otp = await ref
          .read(authRepositoryProvider)
          .requestOtp(account: _account.text.trim(), purpose: 'password_reset');
      if (!mounted) return;
      setState(() => _verificationId = otp.verificationId);
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

  Future<void> _reset() async {
    final l10n = AppLocalizations.of(context);
    final verificationId = _verificationId;
    if (verificationId == null || verificationId.isEmpty) {
      setState(() => _error = l10n.t('auth.otp_required'));
      return;
    }
    if (_password.text != _confirmPassword.text) {
      setState(() => _error = l10n.t('auth.password_mismatch'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authRepositoryProvider)
          .requestPasswordReset(
            email: _account.text.trim(),
            verificationId: verificationId,
            code: _otp.text.trim(),
            newPassword: _password.text,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.t('auth.password_reset'))));
      context.go('/auth/login');
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
      appBar: AppBar(title: Text(l10n.t('auth.forgot_password'))),
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
                  controller: _password,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.t('auth.password'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirmPassword,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.t('auth.confirm_password'),
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
                  onPressed: _busy ? null : _reset,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.t('auth.submit')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
