import '../../../core/network/api_exception.dart';
import '../../../shared/i18n/app_localizations.dart';

int? aiQuotaRetry(Object error) {
  if (error is! ApiException || error.statusCode != 429) return null;
  final seconds = error.retryAfterSeconds;
  return seconds != null && seconds >= 1 && seconds <= 60 ? seconds : 0;
}

String aiQuotaNotice(AppLocalizations l10n, int seconds) => l10n
    .t(seconds == 0 ? 'ai.groupDraft.quota' : 'ai.groupDraft.quotaRetry')
    .replaceAll('{seconds}', '$seconds');
