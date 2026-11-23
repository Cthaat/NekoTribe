import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:passkeys/exceptions.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/i18n/app_localizations.dart';
import '../../../shared/widgets/status_views.dart';

String? passkeyError(BuildContext context, Object error) {
  final l10n = AppLocalizations.of(context);
  if (error is PasskeyAuthCancelledException) return null;
  if (error is ApiException && error.statusCode == 503) {
    return l10n.t('passkeys.server_unavailable');
  }
  if (error is DomainNotAssociatedException) {
    return l10n.t('passkeys.domain_unavailable');
  }
  if (error is DeviceNotSupportedException ||
      error is PasskeyUnsupportedException ||
      error is MissingPluginException ||
      error is UnsupportedError ||
      error is UnimplementedError) {
    return l10n.t('passkeys.device_unavailable');
  }
  if (error is NoCredentialsAvailableException) {
    return l10n.t('passkeys.no_available_credentials');
  }
  return ErrorView.describe(context, error);
}
