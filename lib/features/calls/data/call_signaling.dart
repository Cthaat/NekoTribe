import 'dart:convert';

enum CallMode { voice, video }

enum CallAction {
  invite('call_invite'),
  accept('call_accept'),
  reject('call_reject'),
  cancel('call_cancel'),
  offer('call_sdp_offer'),
  answer('call_sdp_answer'),
  ice('call_ice'),
  hangup('call_hangup'),
  timeout('call_timeout'),
  busy('call_busy'),
  unavailable('call_unavailable');

  const CallAction(this.wire);
  final String wire;
}

const callRingTimeout = Duration(seconds: 30);
const callMaximumDuration = Duration(hours: 4);
const callIceBatchSize = 16;
final _uuid = RegExp(r'^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$');

bool validCallParticipant(Object? id) =>
    id is int && id > 0 && id <= 9007199254740991;

bool _deviceId(Object? value) => value is String && _uuid.hasMatch(value);
bool _boundedString(Object? value, int bytes) =>
    value is String && value.isNotEmpty && utf8.encode(value).length <= bytes;

class CallCandidate {
  const CallCandidate(this.candidate, this.mid, this.line);

  final String candidate;
  final String? mid;
  final int? line;

  bool get valid =>
      _boundedString(candidate, 2048) &&
      (mid == null || mid!.length <= 128) &&
      (line == null || (line! >= 0 && line! <= 65535));

  Map<String, Object> toJson() => {
    'candidate': candidate,
    if (mid != null) 'sdp_mid': mid!,
    if (line != null) 'sdp_mline_index': line!,
  };

  static CallCandidate? decode(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final value = raw['candidate'];
    final mid = raw['sdp_mid'];
    final line = raw['sdp_mline_index'];
    if (value is! String ||
        (mid != null && mid is! String) ||
        (line != null && line is! int)) {
      return null;
    }
    final candidate = CallCandidate(value, mid as String?, line as int?);
    return candidate.valid ? candidate : null;
  }
}

bool validCallSdp(Object? sdp) => _boundedString(sdp, 32768);

class CallSignal {
  const CallSignal({
    required this.action,
    required this.id,
    required this.conversationId,
    required this.callerId,
    required this.calleeId,
    required this.callerClient,
    required this.calleeClient,
    required this.mode,
    this.sdp,
    this.candidates = const [],
  });

  final CallAction action;
  final String id, callerClient;
  final String? calleeClient, sdp;
  final int conversationId, callerId, calleeId;
  final CallMode mode;
  final List<CallCandidate> candidates;

  static CallSignal? decode(Map<String, dynamic> event) {
    final action = CallAction.values
        .where((item) => item.wire == event['type'])
        .firstOrNull;
    final data = event['data'];
    if (action == null || data is! Map<String, dynamic>) return null;
    final id = data['call_id'];
    final conversation = data['conversation_id'];
    final caller = data['caller_id'];
    final callee = data['callee_id'];
    final callerClient = data['caller_client_id'];
    final calleeClient = data['callee_client_id'];
    final mode = switch (data['mode']) {
      'voice' => CallMode.voice,
      'video' => CallMode.video,
      _ => null,
    };
    if (!_deviceId(id) ||
        !validCallParticipant(conversation) ||
        !validCallParticipant(caller) ||
        !validCallParticipant(callee) ||
        caller == callee ||
        !_deviceId(callerClient) ||
        (calleeClient != null && !_deviceId(calleeClient)) ||
        mode == null) {
      return null;
    }
    final requiresCallee = switch (action) {
      CallAction.accept ||
      CallAction.offer ||
      CallAction.answer ||
      CallAction.ice ||
      CallAction.hangup => true,
      _ => false,
    };
    if (requiresCallee && calleeClient == null) return null;
    String? sdp;
    var candidates = <CallCandidate>[];
    if (action == CallAction.offer || action == CallAction.answer) {
      final raw = data['sdp'];
      if (!validCallSdp(raw)) return null;
      sdp = raw as String;
    } else if (action == CallAction.ice) {
      final raw = data['candidates'];
      if (raw is! List || raw.isEmpty || raw.length > callIceBatchSize) {
        return null;
      }
      for (final value in raw) {
        final candidate = CallCandidate.decode(value);
        if (candidate == null) return null;
        candidates.add(candidate);
      }
    }
    return CallSignal(
      action: action,
      id: id as String,
      conversationId: conversation as int,
      callerId: caller as int,
      calleeId: callee as int,
      callerClient: callerClient as String,
      calleeClient: calleeClient as String?,
      mode: mode,
      sdp: sdp,
      candidates: candidates,
    );
  }
}
