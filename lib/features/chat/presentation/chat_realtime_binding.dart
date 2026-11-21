import 'dart:async';

import '../../../core/auth/token_store.dart';
import '../../realtime/data/realtime_service.dart';

/// Binds an active chat route to its current endpoint and token revision.
class ChatRealtimeBinding {
  ChatRealtimeBinding({
    required this.tokenStore,
    required this.onEvent,
    required this.onReset,
    required this.onReload,
    this.channelId,
  }) : _sessionRevision = tokenStore.revision {
    _stopSessionListener = tokenStore.listenSessionChanges(_onSessionChange);
  }

  final TokenStore tokenStore;
  final RealtimeListener onEvent;
  final void Function() onReset;
  final void Function() onReload;
  int? channelId;
  int _sessionRevision;
  late final void Function() _stopSessionListener;
  RealtimeService? _service;
  RealtimeListener? _listener;
  StreamSubscription<RemoteEvents>? _status;
  StreamSubscription<int>? _recovery;
  bool _joined = false;
  bool _waitingForSession = false;
  int _generation = 0;

  bool Function() capture() {
    final generation = _generation;
    final revision = tokenStore.revision;
    return () =>
        _service != null &&
        _generation == generation &&
        tokenStore.revision == revision &&
        !tokenStore.isSessionChanging;
  }

  void bind(RealtimeService service) {
    final replacing = _service != null;
    _detach();
    if (replacing) onReset();
    _service = service;
    final current = capture();
    void syncChannel() {
      if (!current()) return;
      if (service.remoteEvents == RemoteEvents.unknown) {
        _joined = false;
      } else if (!_joined && channelId != null) {
        _joined = _sendChannel(service, 'chat_join_channel');
      }
    }

    _listener = (event) {
      if (!current()) return;
      final data = event['data'];
      if (event['type'] == 'system_notification' &&
          data is Map &&
          data['code'] == 'chat_channel_ready') {
        final channel = channelId;
        if (_joined &&
            channel != null &&
            data['channel_id'] == channel &&
            data['room'] == 'chat:channel:$channel') {
          onReload();
        }
        return;
      }
      onEvent(event);
    };
    service.addListener(_listener!);
    _status = service.remoteStatus.listen((state) {
      if (!current()) return;
      if (state == RemoteEvents.unknown) _joined = false;
      syncChannel();
    });
    _recovery = service.recovery.listen((_) {
      if (current() && service.remoteEvents == RemoteEvents.connected) {
        onReload();
      }
    });
    unawaited(service.connect().then((_) => syncChannel()));
    if (replacing && current()) onReload();
  }

  void changeRoute({int? nextChannelId}) {
    final service = _service;
    if (service == null) return;
    _detach();
    channelId = nextChannelId;
    onReset();
    bind(service);
    if (capture()()) onReload();
  }

  bool _sendChannel(RealtimeService service, String type) {
    return service.send({
      'type': type,
      'data': {'channelId': channelId},
    });
  }

  void _onSessionChange() {
    final service = _service;
    if (service == null) return;
    if (_sessionRevision != tokenStore.revision) {
      _sessionRevision = tokenStore.revision;
      _waitingForSession = true;
      _detach();
      _service = service;
      onReset();
    }
    if (_waitingForSession && !tokenStore.isSessionChanging) {
      _waitingForSession = false;
      final current = capture();
      scheduleMicrotask(() {
        if (current()) bind(service);
      });
    }
  }

  void _detach() {
    _generation++;
    final service = _service;
    final listener = _listener;
    if (service != null && listener != null) {
      if (_joined) _sendChannel(service, 'chat_leave_channel');
      service.removeListener(listener);
    }
    _joined = false;
    _listener = null;
    _service = null;
    unawaited(_status?.cancel());
    unawaited(_recovery?.cancel());
    _status = null;
    _recovery = null;
  }

  void dispose() {
    _stopSessionListener();
    _detach();
  }
}
