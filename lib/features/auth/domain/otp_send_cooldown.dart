import 'dart:async';

import '../../../core/network/api_exception.dart';

const otpSendCooldownSeconds = 60;

int? otpRetryDelay(Object error) {
  if (error is! ApiException || error.statusCode != 429) return null;
  final seconds = error.retryAfterSeconds;
  return seconds != null && seconds >= 1 && seconds <= 3600
      ? seconds
      : otpSendCooldownSeconds;
}

class OtpSendCooldown {
  Timer? _timer;
  int remaining = 0;

  void start(int seconds, void Function() onChanged) {
    cancel();
    remaining = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      remaining = seconds > timer.tick ? seconds - timer.tick : 0;
      if (remaining == 0) cancel();
      onChanged();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    remaining = 0;
  }
}
