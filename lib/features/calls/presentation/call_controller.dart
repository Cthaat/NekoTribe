import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';

import '../../../core/auth/token_store.dart';
import '../../realtime/data/realtime_service.dart';
import '../data/call_media.dart';
import '../data/call_signaling.dart';

enum CallPhase { incoming, preparing, ringing, connecting, connected }

enum CallOutcome {
  rejected,
  timeout,
  busy,
  unavailable,
  disconnected,
  ended,
  answeredElsewhere,
  failed,
}

class CallController extends ChangeNotifier {
  CallController({
    required RealtimeService realtime,
    required TokenStore tokenStore,
    required Future<List<Map<String, Object>>> Function({
      CancelToken? cancelToken,
    })
    iceServers,
    required Future<String?> Function(int conversationId, int peerId) peerName,
    OpenCallMedia openMedia = openWebRtcMedia,
  }) : _realtime = realtime,
       _tokens = tokenStore,
       _iceServers = iceServers,
       _peerName = peerName,
       _openMedia = openMedia {
    _revision = _tokens.revision;
    _realtime.addListener(_onRealtime);
    _connection = _realtime.connection.listen((connected) {
      if (connected) return;
      _pendingInvitation = null;
      if (_call != null) _finish(CallOutcome.disconnected);
    });
    _stopSession = _tokens.listenSessionChanges(_onSessionChanged);
  }

  final RealtimeService _realtime;
  final TokenStore _tokens;
  final Future<List<Map<String, Object>>> Function({CancelToken? cancelToken})
  _iceServers;
  final Future<String?> Function(int conversationId, int peerId) _peerName;
  final OpenCallMedia _openMedia;
  final _clientId = const Uuid().v4();
  late final StreamSubscription<bool> _connection;
  late final VoidCallback _stopSession;
  late int _revision;
  bool _disposed = false;
  Future<int?>? _actor;
  CallSignal? _pendingInvitation;
  _ActiveCall? _call;
  CallOutcome? _outcome;
  CallMediaError? _mediaError;

  CallPhase? get phase => _call?.phase;
  CallMode? get mode => _call?.mode;
  String? get peerName => _call?.peerName;
  CallOutcome? get outcome => _outcome;
  CallMediaError? get mediaError => _mediaError;
  RTCVideoRenderer? get localVideo => _call?.media?.localVideo;
  RTCVideoRenderer? get remoteVideo => _call?.media?.remoteVideo;

  bool _sessionIs(int revision) =>
      !_disposed && _tokens.revision == revision && !_tokens.isSessionChanging;

  bool _owns(_ActiveCall call) =>
      identical(_call, call) && _sessionIs(call.revision);

  Future<int?> _readActor() => _actor ??= _tokens.read().then((token) {
    return token == null
        ? null
        : realtimeUserIdFromAccessToken(token.accessToken);
  }, onError: (Object _) => null);

  void _onSessionChanged() {
    if (_revision == _tokens.revision) return;
    _revision = _tokens.revision;
    _actor = null;
    _pendingInvitation = null;
    _finish();
  }

  Future<void> start({
    required int conversationId,
    required CallMode mode,
    int? peerId,
    String? peerName,
    bool Function()? current,
  }) async {
    if (_call != null ||
        !validCallParticipant(conversationId) ||
        (peerId != null && !validCallParticipant(peerId))) {
      return;
    }
    final revision = _tokens.revision;
    if (!_sessionIs(revision)) return;
    final actor = await _readActor();
    if (!_sessionIs(revision) || current?.call() == false || _call != null) {
      return;
    }
    if (actor == null || peerId == actor || !_realtime.isConnected) {
      _finish(CallOutcome.unavailable);
      return;
    }
    final call = _ActiveCall(
      id: const Uuid().v4(),
      conversationId: conversationId,
      revision: revision,
      mode: mode,
      actor: actor,
      callerClient: _clientId,
      incoming: false,
      peerId: peerId,
      peerName: peerName,
      phase: CallPhase.preparing,
    );
    _setCall(call);
    if (!await _prepare(call) || !_owns(call)) return;
    if (!_send(call, CallAction.invite, {'mode': mode.name})) {
      _finish(CallOutcome.unavailable);
      return;
    }
    call.invited = true;
    call.phase = CallPhase.ringing;
    _scheduleTimeout(call, callRingTimeout);
    notifyListeners();
  }

  Future<void> accept() async {
    final call = _call;
    if (call == null || !_owns(call) || call.phase != CallPhase.incoming) {
      return;
    }
    call.phase = CallPhase.preparing;
    notifyListeners();
    if (!await _prepare(call) || !_owns(call)) return;
    if (!_send(call, CallAction.accept)) {
      _finish(CallOutcome.unavailable);
      return;
    }
    call.acceptSent = true;
  }

  void end() {
    final call = _call;
    if (call == null) return;
    _sendEnd(call);
    _finish();
  }

  void clearOutcome() {
    if (_outcome == null && _mediaError == null) return;
    _outcome = null;
    _mediaError = null;
    notifyListeners();
  }

  void _setCall(_ActiveCall call) {
    _call = call;
    _outcome = null;
    _mediaError = null;
    _scheduleTimeout(call, callRingTimeout);
    notifyListeners();
  }

  Future<void> _showSender(_ActiveCall call) async {
    final peer = call.peerId;
    if (peer == null) return;
    try {
      final name = await _peerName(call.conversationId, peer);
      if (_owns(call) && name != null && name.isNotEmpty) {
        call.peerName = name;
        notifyListeners();
      }
    } catch (_) {
      // The call is still addressable by its authenticated conversation ID.
    }
  }

  Future<bool> _prepare(_ActiveCall call) async {
    try {
      final iceServers = await _iceServers(cancelToken: call.cancel);
      if (!_owns(call)) return false;
      final media = await _openMedia(
        mode: call.mode,
        iceServers: iceServers,
        onCandidate: (candidate) => _localCandidate(call, candidate),
        onStatus: (status) => _mediaStatus(call, status),
        current: () => _owns(call),
      );
      if (!_owns(call)) {
        await media.dispose();
        return false;
      }
      call.media = media;
      return true;
    } catch (error) {
      if (_owns(call)) {
        _sendEnd(call);
        if (error is CallMediaError) {
          _close(null, error);
        } else {
          _finish(CallOutcome.unavailable);
        }
      }
      return false;
    }
  }

  void _onRealtime(Map<String, dynamic> raw) {
    final call = _call;
    final data = raw['data'];
    if (raw['type'] == 'error' &&
        call != null &&
        _owns(call) &&
        data is Map<String, dynamic> &&
        data['call_id'] == call.id) {
      if (call.calleeClient != null) _sendEnd(call);
      _finish(CallOutcome.unavailable);
      return;
    }
    final signal = CallSignal.decode(raw);
    if (signal == null) return;
    if (signal.action == CallAction.invite && (call == null || !call.invited)) {
      _pendingInvitation = signal;
      unawaited(_receiveInvitation(signal));
    } else if (call != null && _owns(call) && call.matches(signal)) {
      _receiveSignal(call, signal);
    } else {
      final pending = _pendingInvitation;
      if (pending != null &&
          signal.id == pending.id &&
          signal.conversationId == pending.conversationId &&
          signal.callerClient == pending.callerClient &&
          (signal.action == CallAction.cancel ||
              signal.action == CallAction.accept ||
              signal.action == CallAction.reject ||
              signal.action == CallAction.timeout)) {
        _pendingInvitation = null;
      }
    }
  }

  Future<void> _receiveInvitation(CallSignal signal) async {
    final revision = _tokens.revision;
    if (!_sessionIs(revision)) return;
    final actor = await _readActor();
    if (!_sessionIs(revision) || !identical(_pendingInvitation, signal)) return;
    _pendingInvitation = null;
    if (actor == null || actor != signal.calleeId) return;
    final previous = _call;
    if (previous != null) {
      if (previous.invited) return;
      _finish();
    }
    final call = _ActiveCall(
      id: signal.id,
      conversationId: signal.conversationId,
      revision: revision,
      mode: signal.mode,
      actor: actor,
      callerClient: signal.callerClient,
      incoming: true,
      peerId: signal.callerId,
      phase: CallPhase.incoming,
    )..invited = true;
    _setCall(call);
    unawaited(_showSender(call));
  }

  void _receiveSignal(_ActiveCall call, CallSignal signal) {
    switch (signal.action) {
      case CallAction.invite:
        return;
      case CallAction.accept:
        if (call.incoming && signal.calleeClient != _clientId) {
          _finish(CallOutcome.answeredElsewhere);
          return;
        }
        if (call.calleeClient != null ||
            call.media == null ||
            (call.incoming
                ? !call.acceptSent
                : call.phase != CallPhase.ringing)) {
          return;
        }
        call.calleeClient = signal.calleeClient;
        call.phase = CallPhase.connecting;
        _scheduleTimeout(call, callRingTimeout);
        notifyListeners();
        if (!call.incoming) _enqueue(call, () => _sendSdp(call, offer: true));
        for (final early in call.earlySignals) {
          if (call.matches(early)) _receiveSignal(call, early);
        }
        call.earlySignals.clear();
      case CallAction.offer:
      case CallAction.answer:
        if ((signal.action == CallAction.offer) != call.incoming) return;
        _mediaSignal(call, signal, () => _applyRemoteSdp(call, signal));
      case CallAction.ice:
        _mediaSignal(
          call,
          signal,
          () => _remoteCandidates(call, signal.candidates),
        );
      case CallAction.reject:
        _finish(CallOutcome.rejected);
      case CallAction.cancel:
      case CallAction.hangup:
        _finish(CallOutcome.ended);
      case CallAction.timeout:
        _finish(CallOutcome.timeout);
      case CallAction.busy:
        _finish(CallOutcome.busy);
      case CallAction.unavailable:
        _finish(CallOutcome.unavailable);
    }
  }

  void _mediaSignal(
    _ActiveCall call,
    CallSignal signal,
    Future<void> Function() operation,
  ) {
    if (call.calleeClient != null) {
      _enqueue(call, operation);
    } else if (call.earlySignals.length < callIceBatchSize &&
        (call.incoming
            ? call.acceptSent && signal.calleeClient == _clientId
            : call.invited)) {
      call.earlySignals.add(signal);
    }
  }

  void _enqueue(_ActiveCall call, Future<void> Function() operation) {
    call.signaling = call.signaling
        .then((_) async {
          if (_owns(call)) await operation();
        })
        .catchError((Object _) {
          if (_owns(call)) {
            _sendEnd(call);
            _finish(CallOutcome.failed);
          }
        });
  }

  Future<void> _sendSdp(_ActiveCall call, {required bool offer}) async {
    final sdp = await call.media!.localDescription(offer: offer);
    if (!_owns(call)) return;
    if (!_send(call, offer ? CallAction.offer : CallAction.answer, {
      'sdp': sdp,
    })) {
      throw CallMediaError.failed;
    }
    call.localDescription = true;
    _scheduleIce(call);
  }

  Future<void> _applyRemoteSdp(_ActiveCall call, CallSignal signal) async {
    if (call.remoteDescription || (!call.incoming && !call.localDescription)) {
      return;
    }
    await call.media!.remoteDescription(signal.sdp!, offer: call.incoming);
    if (!_owns(call)) return;
    call.remoteDescription = true;
    final waiting = List.of(call.remoteIce);
    call.remoteIce.clear();
    await _remoteCandidates(call, waiting);
    if (call.incoming && _owns(call)) await _sendSdp(call, offer: false);
  }

  Future<void> _remoteCandidates(
    _ActiveCall call,
    List<CallCandidate> candidates,
  ) async {
    if (!call.remoteDescription) {
      call.remoteIce.addAll(candidates.take(256 - call.remoteIce.length));
      return;
    }
    for (final candidate in candidates) {
      if (!_owns(call)) return;
      try {
        await call.media!.addCandidate(candidate);
      } catch (_) {
        // A rejected ICE candidate does not prevent trying the others.
      }
    }
  }

  void _localCandidate(_ActiveCall call, CallCandidate candidate) {
    if (!_owns(call) || !candidate.valid || call.localIce.length >= 256) return;
    call.localIce.add(candidate);
    _scheduleIce(call);
  }

  void _scheduleIce(_ActiveCall call) {
    if (!call.localDescription ||
        call.localIce.isEmpty ||
        call.iceTimer != null) {
      return;
    }
    call.iceTimer = Timer(const Duration(milliseconds: 75), () {
      call.iceTimer = null;
      while (_owns(call) && call.localIce.isNotEmpty) {
        final batch = call.localIce
            .take(callIceBatchSize)
            .map((candidate) => candidate.toJson())
            .toList();
        call.localIce.removeRange(0, batch.length);
        if (!_send(call, CallAction.ice, {'candidates': batch})) {
          _sendEnd(call);
          _finish(CallOutcome.disconnected);
          return;
        }
      }
    });
  }

  void _mediaStatus(_ActiveCall call, CallMediaStatus status) {
    if (!_owns(call) || call.calleeClient == null) return;
    switch (status) {
      case CallMediaStatus.connected:
        if (call.phase == CallPhase.connected) return;
        call.phase = CallPhase.connected;
        _scheduleTimeout(call, callMaximumDuration);
        notifyListeners();
      case CallMediaStatus.failed:
        _sendEnd(call);
        _finish(CallOutcome.failed);
    }
  }

  bool _send(
    _ActiveCall call,
    CallAction action, [
    Map<String, Object> fields = const {},
  ]) =>
      _owns(call) &&
      _realtime.send({
        'type': action.wire,
        'data': {
          'call_id': call.id,
          'conversation_id': call.conversationId,
          'client_id': _clientId,
          ...fields,
        },
      });

  void _sendEnd(_ActiveCall call) {
    if (!call.invited) return;
    if (call.calleeClient != null || call.acceptSent) {
      _send(call, CallAction.hangup);
    } else {
      _send(call, call.incoming ? CallAction.reject : CallAction.cancel);
    }
  }

  void _scheduleTimeout(_ActiveCall call, Duration length) {
    call.timeout?.cancel();
    call.timeout = Timer(length, () {
      if (!_owns(call)) return;
      _sendEnd(call);
      _finish(CallOutcome.timeout);
    });
  }

  void _finish([CallOutcome? outcome]) => _close(outcome, null);

  void _close(CallOutcome? outcome, CallMediaError? mediaError) {
    final call = _call;
    _call = null;
    _outcome = outcome;
    _mediaError = mediaError;
    if (call != null) {
      call.timeout?.cancel();
      call.iceTimer?.cancel();
      call.cancel.cancel();
      call.localIce.clear();
      call.remoteIce.clear();
      call.earlySignals.clear();
      final media = call.media;
      if (media != null) unawaited(media.dispose());
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    final call = _call;
    if (call != null) _sendEnd(call);
    _disposed = true;
    _pendingInvitation = null;
    _stopSession();
    _realtime.removeListener(_onRealtime);
    unawaited(_connection.cancel());
    _finish();
    super.dispose();
  }
}

class _ActiveCall {
  _ActiveCall({
    required this.id,
    required this.conversationId,
    required this.revision,
    required this.mode,
    required this.actor,
    required this.callerClient,
    required this.incoming,
    required this.phase,
    this.peerId,
    this.peerName,
  });

  final String id, callerClient;
  final int conversationId, revision, actor;
  final int? peerId;
  final CallMode mode;
  final bool incoming;
  final cancel = CancelToken();
  String? calleeClient, peerName;
  CallPhase phase;
  CallMediaSession? media;
  bool invited = false, acceptSent = false;
  bool localDescription = false, remoteDescription = false;
  final localIce = <CallCandidate>[], remoteIce = <CallCandidate>[];
  final earlySignals = <CallSignal>[];
  Timer? timeout, iceTimer;
  Future<void> signaling = Future.value();

  bool matches(CallSignal signal) =>
      signal.id == id &&
      signal.conversationId == conversationId &&
      signal.mode == mode &&
      signal.callerClient == callerClient &&
      (incoming
          ? signal.calleeId == actor && signal.callerId == peerId
          : signal.callerId == actor &&
                (peerId == null || signal.calleeId == peerId)) &&
      (calleeClient == null || signal.calleeClient == calleeClient);
}
