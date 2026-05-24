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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.t('auth.forgot_password'))),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth < 440.0
              ? constraints.maxWidth
              : 440.0;
          return Center(
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.12,
                        ),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(
                        Icons.lock_reset_outlined,
                        size: 36,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.t('auth.forgot_password'),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _account,
                      decoration: InputDecoration(
                        labelText: l10n.t('auth.account'),
                        prefixIcon: const Icon(Icons.alternate_email),
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final otpField = TextField(
                          controller: _otp,
                          decoration: InputDecoration(
                            labelText: l10n.t('auth.otp'),
                            prefixIcon: const Icon(Icons.pin_outlined),
                          ),
                        );
                        final sendButton = SizedBox(
                          height: 48,
                          child: OutlinedButton(
                            onPressed: _sending ? null : _sendOtp,
                            child: _sending
                                ? const SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(l10n.t('auth.send_otp')),
                          ),
                        );
                        if (constraints.maxWidth < 360) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              otpField,
                              const SizedBox(height: 12),
                              sendButton,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: otpField),
                            const SizedBox(width: 12),
                            sendButton,
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: l10n.t('auth.password'),
                        prefixIcon: const Icon(Icons.lock_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirmPassword,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: l10n.t('auth.confirm_password'),
                        prefixIcon: const Icon(Icons.lock_reset_outlined),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
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
                                _error!,
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 48,
                      child: FilledButton(
                        onPressed: _busy ? null : _reset,
                        child: _busy
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(l10n.t('auth.submit')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
