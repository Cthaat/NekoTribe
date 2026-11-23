import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/auth/token_store.dart';
import '../../../core/config/app_config.dart';

typedef RealtimeListener = void Function(Map<String, dynamic> event);

enum RemoteEvents { unknown, connecting, connected, unavailable }

const _maxSafeInteger = 9007199254740991;
const chatTypingInterval = Duration(milliseconds: 1200);

int? realtimeUserIdFromAccessToken(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final claims = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final userId = claims is Map<String, dynamic> ? claims['userId'] : null;
    return userId is int && userId > 0 && userId <= _maxSafeInteger
        ? userId
        : null;
  } on FormatException {
    return null;
  }
}

class RealtimeService {
  RealtimeService({
    required this.config,
    required this.tokenStore,
    WebSocketChannel Function(Uri)? channelFactory,
  }) : _channelFactory = channelFactory ?? WebSocketChannel.connect {
    _stopSessionListener = tokenStore.listenSessionChanges(_onSessionChange);
  }

  final AppConfig config;
  final TokenStore tokenStore;
  final WebSocketChannel Function(Uri) _channelFactory;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  final _typingCooldowns = <String, Timer>{};
  bool _shouldReconnect = false;
  int _generation = 0;
  int? _channelRevision;
  int _reconnectAttempts = 0;
  bool _ready = false;
  bool _disposed = false;
  bool _needsRecovery = false;
  bool _connectedBefore = false;
  late final void Function() _stopSessionListener;
  Future<void>? _opening;
  int? _openingRevision;
  int _sessionRevision = -1;
  bool _resumeAfterSessionChange = false;
  RemoteEvents _remoteEvents = RemoteEvents.unknown;
  final _statusCtl = StreamController<RemoteEvents>.broadcast();
  final _recoveryCtl = StreamController<int>.broadcast();
  int _recoveryRevision = 0;
  final Set<RealtimeListener> _listeners = {};
  final StreamController<bool> _connectedCtl =
      StreamController<bool>.broadcast();

  Stream<bool> get connection => _connectedCtl.stream;
  Stream<RemoteEvents> get remoteStatus => _statusCtl.stream;
  Stream<int> get recovery => _recoveryCtl.stream;
  RemoteEvents get remoteEvents =>
      isConnected ? _remoteEvents : RemoteEvents.unknown;

  bool get isConnected =>
      _ready &&
      _channel != null &&
      _channelRevision == tokenStore.revision &&
      !tokenStore.isSessionChanging &&
      _shouldReconnect;

  Future<void> connect() async {
    if (_disposed || tokenStore.isSessionChanging) return;
    _shouldReconnect = true;
    if (isConnected) return;
    if (_openingRevision == tokenStore.revision && _opening != null) {
      await _opening;
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final opening = _open(++_generation);
    _opening = opening;
    _openingRevision = tokenStore.revision;
    _sessionRevision = tokenStore.revision;
    try {
      await opening;
    } finally {
      if (identical(_opening, opening)) {
        _opening = null;
        _openingRevision = null;
      }
    }
  }

  void _onSessionChange() {
    if (_shouldReconnect && _sessionRevision != tokenStore.revision) {
      final resume = tokenStore.isSessionChanging;
      unawaited(disconnect());
      _resumeAfterSessionChange = resume;
    }
    if (_resumeAfterSessionChange && !tokenStore.isSessionChanging) {
      _resumeAfterSessionChange = false;
      unawaited(connect());
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopSessionListener();
    _listeners.clear();
    await disconnect();
    await Future.wait([
      _connectedCtl.close(),
      _statusCtl.close(),
      _recoveryCtl.close(),
    ]);
  }

  Future<void> disconnect() {
    _shouldReconnect = false;
    _resumeAfterSessionChange = false;
    ++_generation;
    _opening = null;
    _openingRevision = null;
    _needsRecovery = false;
    _connectedBefore = false;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    return _releaseChannel();
  }

  Future<void> _releaseChannel() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    for (final cooldown in _typingCooldowns.values) {
      cooldown.cancel();
    }
    _typingCooldowns.clear();
    final subscription = _sub, channel = _channel;
    final wasReady = _ready;
    _sub = null;
    _channel = null;
    _channelRevision = null;
    _ready = false;
    _setRemoteEvents(RemoteEvents.unknown);
    if (wasReady) _connectedCtl.add(false);
    try {
      await subscription?.cancel();
    } catch (_) {
      // The transport may already have failed.
    }
    try {
      await channel?.sink.close();
    } catch (_) {}
  }

  void addListener(RealtimeListener listener) {
    _listeners.add(listener);
  }

  void removeListener(RealtimeListener listener) {
    _listeners.remove(listener);
  }

  bool send(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null || !isConnected) return false;
    final frame = jsonEncode(payload);
    try {
      channel.sink.add(frame);
      return true;
    } catch (_) {
      _scheduleReconnect(_generation, tokenStore.revision, channel);
      return false;
    }
  }

  bool sendTyping(Map<String, dynamic> payload) {
    final type = payload['type'];
    if (type is! String ||
        (type != 'typing_start' && type != 'typing_stop') ||
        _typingCooldowns.containsKey(type) ||
        !send(payload)) {
      return false;
    }
    if (isConnected) {
      _typingCooldowns[type] = Timer(
        chatTypingInterval,
        () => _typingCooldowns.remove(type),
      );
    }
    return true;
  }

  bool _isCurrent(int generation, int revision) =>
      _shouldReconnect &&
      !tokenStore.isSessionChanging &&
      generation == _generation &&
      revision == tokenStore.revision;

  Future<void> _open(int generation) async {
    final revision = tokenStore.revision;
    WebSocketChannel? openingChannel;
    try {
      final pair = await tokenStore.read();
      if (!_isCurrent(generation, revision) ||
          pair == null ||
          pair.accessToken.isEmpty) {
        return;
      }
      final userId = realtimeUserIdFromAccessToken(pair.accessToken);
      final base = config.wsBaseUrl;
      final separator = base.endsWith('/') ? '' : '/';
      final url =
          '$base${separator}_ws?token=${Uri.encodeQueryComponent(pair.accessToken)}';
      final channel = _channelFactory(Uri.parse(url));
      openingChannel = channel;
      _channel = channel;
      _channelRevision = revision;
      bool active() =>
          _isCurrent(generation, revision) && identical(_channel, channel);
      final ready = channel.ready.timeout(const Duration(seconds: 10));
      final subscription = channel.stream.listen(
        (raw) {
          if (active() && _ready) _onMessage(raw, userId, active);
        },
        onError: (_) => _scheduleReconnect(generation, revision, channel),
        onDone: () => _scheduleReconnect(generation, revision, channel),
        cancelOnError: true,
      );
      _sub = subscription;
      subscription.pause();
      await ready;
      if (!active()) return;
      _ready = true;
      _connectedBefore = true;
      _reconnectAttempts = 0;
      _connectedCtl.add(true);
      subscription.resume();
      _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
        if (_isCurrent(generation, revision) && identical(_channel, channel)) {
          send({'type': 'ping', 'timestamp': DateTime.now().toIso8601String()});
        }
      });
    } catch (_) {
      _scheduleReconnect(generation, revision, openingChannel);
    }
  }

  void _setRemoteEvents(RemoteEvents value) {
    if (_remoteEvents == value) return;
    _remoteEvents = value;
    _statusCtl.add(value);
  }

  void _onMessage(dynamic raw, int? userId, bool Function() active) {
    if (raw is! String) return;
    try {
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic>) {
        final payload = data['data'];
        if (payload is Map<String, dynamic> &&
            payload['code'] == 'realtime_status') {
          final timestamp = data['timestamp'];
          final server = payload['server_id'];
          if (data.length != 3 ||
              data['type'] != 'system_notification' ||
              timestamp is! int ||
              timestamp < 0 ||
              timestamp > _maxSafeInteger ||
              payload.length != 5 ||
              userId == null ||
              payload['user_id'] is! int ||
              payload['user_id'] != userId ||
              payload['local_presence'] != true ||
              server is! String ||
              server.trim().isEmpty) {
            return;
          }
          final state = switch (payload['remote_events']) {
            'connecting' => RemoteEvents.connecting,
            'connected' => RemoteEvents.connected,
            'unavailable' => RemoteEvents.unavailable,
            _ => null,
          };
          if (state == null) return;
          if (state == RemoteEvents.unavailable ||
              (state == RemoteEvents.connecting &&
                  _remoteEvents == RemoteEvents.connected)) {
            _needsRecovery = true;
          }
          _setRemoteEvents(state);
          if (state == RemoteEvents.connected && _needsRecovery) {
            _needsRecovery = false;
            _recoveryCtl.add(++_recoveryRevision);
          }
          return;
        }
        if (data['type'] == 'pong') return;
        for (final listener in List.of(_listeners)) {
          if (!active()) return;
          try {
            listener(data);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _scheduleReconnect(
    int generation,
    int revision, [
    WebSocketChannel? channel,
  ]) {
    if (!_isCurrent(generation, revision) ||
        (channel != null && !identical(_channel, channel))) {
      return;
    }
    _needsRecovery |= _connectedBefore;
    unawaited(_releaseChannel());
    _reconnectAttempts += 1;
    final delay = Duration(
      milliseconds: (500 * (1 << (_reconnectAttempts.clamp(0, 6)))).clamp(
        500,
        30000,
      ),
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_isCurrent(generation, revision)) {
        _opening = null;
        _openingRevision = null;
        unawaited(connect());
      }
    });
  }
}
