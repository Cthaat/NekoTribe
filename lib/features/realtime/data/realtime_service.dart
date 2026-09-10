import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/auth/token_store.dart';
import '../../../core/config/app_config.dart';

typedef RealtimeListener = void Function(Map<String, dynamic> event);

class RealtimeService {
  RealtimeService({required this.config, required this.tokenStore});

  final AppConfig config;
  final TokenStore tokenStore;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _shouldReconnect = false;
  int _reconnectAttempts = 0;
  final Set<RealtimeListener> _listeners = {};
  final StreamController<bool> _connectedCtl =
      StreamController<bool>.broadcast();

  Stream<bool> get connection => _connectedCtl.stream;

  bool get isConnected => _channel != null;

  Future<void> connect() async {
    _shouldReconnect = true;
    if (_channel != null && _sub != null) {
      if (!_connectedCtl.isClosed) _connectedCtl.add(true);
      return;
    }
    await _open();
  }

  Future<void> disconnect() async {
    _shouldReconnect = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    if (!_connectedCtl.isClosed) {
      _connectedCtl.add(false);
    }
  }

  void addListener(RealtimeListener listener) {
    _listeners.add(listener);
  }

  void removeListener(RealtimeListener listener) {
    _listeners.remove(listener);
  }

  void send(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(payload));
  }

  Future<void> _open() async {
    final pair = await tokenStore.read();
    if (pair == null || pair.accessToken.isEmpty) {
      _connectedCtl.add(false);
      return;
    }
    // Close any prior channel/subscription before opening a new one.
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    final base = config.wsBaseUrl;
    final separator = base.endsWith('/') ? '' : '/';
    final url =
        '$base${separator}_ws?token=${Uri.encodeQueryComponent(pair.accessToken)}';
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      _reconnectAttempts = 0;
      if (!_connectedCtl.isClosed) {
        _connectedCtl.add(true);
      }
      _sub = channel.stream.listen(
        _onMessage,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
        send({'type': 'ping', 'timestamp': DateTime.now().toIso8601String()});
      });
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) {
        if (data['type'] == 'pong') return;
        for (final listener in List.of(_listeners)) {
          try {
            listener(data);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _scheduleReconnect() {
    if (!_shouldReconnect) return;
    if (!_connectedCtl.isClosed) {
      _connectedCtl.add(false);
    }
    _sub?.cancel();
    _sub = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _channel = null;
    _reconnectAttempts += 1;
    final delay = Duration(
      milliseconds: (500 * (1 << (_reconnectAttempts.clamp(0, 6)))).clamp(
        500,
        30000,
      ),
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (_shouldReconnect) _open();
    });
  }
}
