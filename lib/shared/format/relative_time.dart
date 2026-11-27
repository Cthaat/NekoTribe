import 'dart:ui';

const _enMonths = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Formats an ISO timestamp as concise social relative time ("刚刚", "3小时", "11月21日")
/// without requiring `intl` locale data initialization in bare widget tests.
String formatRelativeTime(String iso, {required Locale locale, DateTime? now}) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final local = parsed.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  final diff = current.difference(local);
  final isZh = locale.languageCode.toLowerCase().startsWith('zh');

  if (diff.isNegative || diff.inSeconds < 60) {
    return isZh ? '刚刚' : 'now';
  }
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return isZh ? '$m分钟' : '${m}m';
  }
  if (diff.inHours < 24) {
    final h = diff.inHours;
    return isZh ? '$h小时' : '${h}h';
  }
  if (diff.inDays < 7) {
    final d = diff.inDays;
    return isZh ? '$d天' : '${d}d';
  }
  if (local.year == current.year) {
    return isZh
        ? '${local.month}月${local.day}日'
        : '${_enMonths[local.month - 1]} ${local.day}';
  }
  return isZh
      ? '${local.year}年${local.month}月${local.day}日'
      : '${_enMonths[local.month - 1]} ${local.day}, ${local.year}';
}

/// Full date and time for hover tooltips and detail focus headers.
String formatFullTimestamp(String iso, {required Locale locale}) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final local = parsed.toLocal();
  final isZh = locale.languageCode.toLowerCase().startsWith('zh');
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  if (isZh) {
    return '${local.year}年${local.month}月${local.day}日 $hh:$mm';
  }
  final period = local.hour >= 12 ? 'PM' : 'AM';
  final h12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
  return '$h12:$mm $period · ${_enMonths[local.month - 1]} ${local.day}, ${local.year}';
}
