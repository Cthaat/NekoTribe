import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/providers.dart';

bool requireAuthenticatedAction(
  BuildContext context,
  WidgetRef ref, {
  String message = 'Please sign in to continue.',
}) {
  final session = ref.read(authSessionProvider);
  if (session.isAuthenticated) return true;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
  context.push('/auth/login');
  return false;
}
