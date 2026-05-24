import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/providers.dart';
import '../../../shared/widgets/status_views.dart';

class SecurityScreen extends ConsumerStatefulWidget {
  const SecurityScreen({super.key});

  @override
  ConsumerState<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends ConsumerState<SecurityScreen> {
  bool _busy = false;
  String? _error;
  String? _twoFactorSecret;
  String? _qrUri;

  Future<void> _setup2fa() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await ref.read(usersRepositoryProvider).setupTwoFactor();
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

  Future<void> _confirm2fa(String code) async {
    if (_twoFactorSecret == null) return;
    try {
      await ref
          .read(usersRepositoryProvider)
          .confirmTwoFactor(secret: _twoFactorSecret!, code: code);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('2FA enabled')));
      setState(() {
        _twoFactorSecret = null;
        _qrUri = null;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(ErrorView.describe(context, e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: ListView(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ListTile(
            title: const Text('Setup Two-Factor Authentication'),
            subtitle: const Text(
              'Use an authenticator app like Google Authenticator',
            ),
            trailing: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _busy ? null : _setup2fa,
          ),
          if (_twoFactorSecret != null) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Setup secret:'),
                  SelectableText(_twoFactorSecret!),
                  if (_qrUri != null) SelectableText('URI: $_qrUri'),
                  const SizedBox(height: 12),
                  _ConfirmField(onSubmit: _confirm2fa),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConfirmField extends StatefulWidget {
  const _ConfirmField({required this.onSubmit});
  final Future<void> Function(String code) onSubmit;

  @override
  State<_ConfirmField> createState() => _ConfirmFieldState();
}

class _ConfirmFieldState extends State<_ConfirmField> {
  final _ctl = TextEditingController();
  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctl,
            decoration: const InputDecoration(
              labelText: 'Enter code',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: () => widget.onSubmit(_ctl.text.trim()),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
