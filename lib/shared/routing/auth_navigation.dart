import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/app_localizations.dart';
import '../providers/providers.dart';

bool requireAuthenticatedAction(
  BuildContext context,
  WidgetRef ref, {
  String? message,
}) {
  final session = ref.read(authSessionProvider);
  if (session.isAuthenticated) return true;
  final l10n = AppLocalizations.of(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message ?? l10n.t('auth.sign_in_required'))),
  );
  context.push('/auth/login');
  return false;
}
