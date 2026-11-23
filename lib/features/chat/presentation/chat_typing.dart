import 'dart:async';

import '../../realtime/data/realtime_service.dart' show chatTypingInterval;

enum ChatTypingScope {
  direct('conversation_id'),
  channel('channel_id');

  const ChatTypingScope(this.idField);
  final String idField;
}

class ChatTyping {
  ChatTyping({
    required this.scope,
    required this.scopeId,
    required this.ownId,
    required this.send,
    required this.onChange,
  });

  static const _ttl = Duration(milliseconds: 5000);
  static const _start = 'typing_start', _stop = 'typing_stop';
  final ChatTypingScope scope;
  final int Function() scopeId;
  final int? Function() ownId;
  final bool Function(Map<String, dynamic>) send;
  final void Function() onChange;

  final _latest = <int, ({int timestamp, bool started})>{};
  final _remote = <int, Timer>{};
  Timer? _startCooldown, _stopCooldown, _idle;
  bool _visible = false, _announced = false;
  bool _startPending = false, _stopPending = false;

  bool get hasRemoteTyping => _remote.isNotEmpty;

  bool receive(Map<String, dynamic> event) {
    final type = event['type'];
    if (type != _start && type != _stop) return false;
    final data = event['data'];
    final timestamp = event['timestamp'];
    if (data is! Map ||
        timestamp is! int ||
        timestamp < 0 ||
        data[scope.idField] is! int ||
        data[scope.idField] != scopeId() ||
        !data.keys.every(
          (key) =>
              key == scope.idField || key == 'user_id' || key == 'server_id',
        )) {
      return true;
    }
    final user = data['user_id'];
    final self = ownId();
    if (self == null ||
        user is! int ||
        user <= 0 ||
        user > 9007199254740991 ||
        user == self) {
      return true;
    }
    final started = type == _start;
    final previous = _latest[user];
    if (previous != null &&
        (timestamp < previous.timestamp ||
            (timestamp == previous.timestamp &&
                (started || !previous.started)))) {
      return true;
    }
    _latest[user] = (timestamp: timestamp, started: started);
    if (!_visible) return true;
    if (started) {
      final wasEmpty = _remote.isEmpty;
      _remote.remove(user)?.cancel();
      _remote[user] = Timer(_ttl, () => _remove(user));
      if (wasEmpty) onChange();
    } else {
      _remove(user);
    }
    return true;
  }

  void _remove(int user) {
    final timer = _remote.remove(user);
    timer?.cancel();
    if (timer != null && _remote.isEmpty) onChange();
  }

  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    if (!visible) {
      stop();
      _clearRemote();
    }
  }

  void input(bool hasText) {
    if (!_visible) return;
    if (!hasText) {
      stop();
      return;
    }
    _stopPending = false;
    _startPending = true;
    _idle?.cancel();
    _idle = Timer(_ttl, stop);
    _sendStart();
  }

  void stop() {
    _idle?.cancel();
    _idle = null;
    _startPending = false;
    if (!_announced) return;
    _stopPending = true;
    _sendStop();
  }

  bool _send(String type) => send({
    'type': type,
    'data': {scope.idField: scopeId()},
  });

  void _sendStart() {
    if (!_visible || !_startPending || _startCooldown != null) return;
    _startPending = false;
    if (!_send(_start)) return;
    _announced = true;
    _startCooldown = Timer(chatTypingInterval, () {
      _startCooldown = null;
      _sendStart();
    });
  }

  void _sendStop() {
    if (!_stopPending || _stopCooldown != null) return;
    _stopPending = _announced = false;
    if (!_send(_stop)) return;
    _stopCooldown = Timer(chatTypingInterval, () {
      _stopCooldown = null;
      _sendStop();
    });
  }

  void _clearRemote({bool notify = true}) {
    if (_remote.isEmpty) return;
    for (final timer in _remote.values) {
      timer.cancel();
    }
    _remote.clear();
    if (notify) onChange();
  }

  void reset({bool notify = true}) {
    _startCooldown?.cancel();
    _stopCooldown?.cancel();
    _idle?.cancel();
    _startCooldown = _stopCooldown = _idle = null;
    _announced = _startPending = _stopPending = false;
    _latest.clear();
    _clearRemote(notify: notify);
  }
}
