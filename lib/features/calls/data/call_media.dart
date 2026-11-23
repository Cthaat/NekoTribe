import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call_environment.dart'
    if (dart.library.js_interop) 'call_environment_web.dart';
import 'call_signaling.dart';

enum CallMediaError implements Exception {
  unsupported,
  insecure,
  permissionDenied,
  deviceUnavailable,
  failed,
}

enum CallMediaStatus { connected, failed }

abstract interface class CallMediaSession {
  RTCVideoRenderer? get localVideo;
  RTCVideoRenderer? get remoteVideo;
  Future<String> localDescription({required bool offer});
  Future<void> remoteDescription(String sdp, {required bool offer});
  Future<void> addCandidate(CallCandidate candidate);
  Future<void> dispose();
}

typedef OpenCallMedia =
    Future<CallMediaSession> Function({
      required CallMode mode,
      required List<Map<String, Object>> iceServers,
      required ValueChanged<CallCandidate> onCandidate,
      required ValueChanged<CallMediaStatus> onStatus,
      required bool Function() current,
    });

Future<CallMediaSession> openWebRtcMedia({
  required CallMode mode,
  required List<Map<String, Object>> iceServers,
  required ValueChanged<CallCandidate> onCandidate,
  required ValueChanged<CallMediaStatus> onStatus,
  required bool Function() current,
}) async {
  if (!callSecureContext) throw CallMediaError.insecure;
  if (!callBrowserSupported ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.fuchsia)) {
    throw CallMediaError.unsupported;
  }
  final video = mode == CallMode.video;
  final session = _WebRtcMediaSession();
  try {
    session._local = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video,
    });
  } catch (error) {
    if (error is MissingPluginException) throw CallMediaError.unsupported;
    final message = error.toString().toLowerCase();
    if (message.contains('denied') ||
        message.contains('notallowed') ||
        message.contains('permission') ||
        message.contains('securityerror')) {
      throw CallMediaError.permissionDenied;
    }
    throw CallMediaError.deviceUnavailable;
  }
  try {
    if (!current()) throw CallMediaError.failed;
    final local = session._local!;
    if (local.getAudioTracks().isEmpty ||
        (video && local.getVideoTracks().isEmpty)) {
      throw CallMediaError.deviceUnavailable;
    }
    if (video) {
      final renderer = session.localVideo = RTCVideoRenderer();
      await renderer.initialize();
      if (kIsWeb) renderer.muted = true;
      renderer.srcObject = local;
    }
    if (video || kIsWeb) {
      final renderer = session.remoteVideo = RTCVideoRenderer();
      await renderer.initialize();
    }
    if (!current()) throw CallMediaError.failed;
    final peer = session._connection = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    if (!current()) throw CallMediaError.failed;
    peer.onIceCandidate = (candidate) {
      if (!current() || candidate.candidate == null) return;
      onCandidate(
        CallCandidate(
          candidate.candidate!,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        ),
      );
    };
    peer.onConnectionState = (state) {
      if (!current()) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onStatus(CallMediaStatus.connected);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        onStatus(CallMediaStatus.failed);
      }
    };
    peer.onTrack = (event) {
      if (!current()) return;
      final stream = event.streams.firstOrNull;
      if (stream != null) {
        session._remote = stream;
        session.remoteVideo?.srcObject = stream;
      }
    };
    for (final track in local.getTracks()) {
      if (!current()) throw CallMediaError.failed;
      await peer.addTrack(track, local);
    }
    return session;
  } catch (error) {
    await session.dispose();
    if (error is CallMediaError) rethrow;
    if (error is MissingPluginException) throw CallMediaError.unsupported;
    throw CallMediaError.failed;
  }
}

class _WebRtcMediaSession implements CallMediaSession {
  RTCPeerConnection? _connection;
  MediaStream? _local, _remote;
  @override
  RTCVideoRenderer? localVideo;
  @override
  RTCVideoRenderer? remoteVideo;

  @override
  Future<String> localDescription({required bool offer}) async {
    final peer = _connection!;
    final description = offer
        ? await peer.createOffer()
        : await peer.createAnswer();
    await peer.setLocalDescription(description);
    final sdp = description.sdp;
    if (!validCallSdp(sdp)) throw CallMediaError.failed;
    return sdp!;
  }

  @override
  Future<void> remoteDescription(String sdp, {required bool offer}) =>
      _connection!.setRemoteDescription(
        RTCSessionDescription(sdp, offer ? 'offer' : 'answer'),
      );

  @override
  Future<void> addCandidate(CallCandidate candidate) =>
      _connection!.addCandidate(
        RTCIceCandidate(candidate.candidate, candidate.mid, candidate.line),
      );

  @override
  Future<void> dispose() async {
    final local = _local;
    final remote = _remote;
    final peer = _connection;
    final localRenderer = localVideo;
    final remoteRenderer = remoteVideo;
    _local = _remote = null;
    _connection = null;
    localVideo = remoteVideo = null;
    if (peer != null) {
      peer.onIceCandidate = null;
      peer.onTrack = null;
      peer.onConnectionState = null;
    }
    await Future.wait([
      for (final stream in [local, remote])
        if (stream != null) _disposeStream(stream),
      if (peer != null) _ignoreCleanup(peer.dispose),
      for (final renderer in [localRenderer, remoteRenderer])
        if (renderer != null) _ignoreCleanup(renderer.dispose),
    ]);
  }

  Future<void> _disposeStream(MediaStream stream) async {
    await Future.wait(
      stream.getTracks().map((track) => _ignoreCleanup(track.stop)),
    );
    await _ignoreCleanup(stream.dispose);
  }

  Future<void> _ignoreCleanup(Future<void> Function() dispose) async {
    try {
      await dispose();
    } catch (_) {
      // Cleanup of other tracks and the peer connection must still proceed.
    }
  }
}
