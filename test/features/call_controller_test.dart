import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/features/calls/data/call_media.dart';
import 'package:nekotribe/features/calls/data/call_signaling.dart';
import 'package:nekotribe/features/calls/presentation/call_controller.dart';
import 'package:nekotribe/features/calls/presentation/call_widgets.dart';
import 'package:nekotribe/features/realtime/data/realtime_service.dart';
import 'package:nekotribe/shared/i18n/app_localizations.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets(
    'caller targets the accepted device and applies candidates after SDP',
    (tester) async {
      final session = _Harness(1);
      addTearDown(session.dispose);

      await session.call.start(
        conversationId: 8,
        peerId: 2,
        mode: CallMode.video,
      );
      expect(session.call.phase, CallPhase.ringing);
      expect(session.openedModes, [CallMode.video]);
      expect(session.openedIceServers.single.single['urls'], [
        'stun:local.example',
      ]);
      final invite = session.socket.payload('call_invite');
      expect(invite['conversation_id'], 8);
      final id = invite['call_id'] as String;
      final caller = invite['client_id'] as String;
      final event = _Event(id: id, callerClient: caller);
      session.socket.emit(
        event.wire(
          'call_accept',
          callerClient: _otherClient,
          calleeClient: _peerClient,
        ),
      );
      await tester.pump();
      expect(session.socket.actions, ['call_invite']);

      session.media.onLocalDescription = () {
        for (var i = 0; i < 20; i++) {
          session.candidate(CallCandidate('local$i', '0', 0));
        }
      };
      session.socket.emit(event.wire('call_accept', calleeClient: _peerClient));
      await tester.pump();
      expect(session.socket.actions, ['call_invite', 'call_sdp_offer']);
      expect(session.media.operations, ['local offer']);
      expect(session.call.phase, CallPhase.connecting);
      session.socket.emit(
        event.wire(
          'call_ice',
          calleeClient: _otherClient,
          more: {
            'candidates': [
              {'candidate': 'unrelated candidate'},
            ],
          },
        ),
      );
      session.socket.emit(
        event.wire(
          'call_ice',
          calleeClient: _peerClient,
          more: {
            'candidates': [
              {
                'candidate': 'waiting candidate',
                'sdp_mid': '0',
                'sdp_mline_index': 0,
              },
            ],
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        session.socket.sent
            .where((item) => item['type'] == 'call_ice')
            .map((item) => (item['data']['candidates'] as List).length),
        [16, 4],
      );
      expect(session.media.operations, ['local offer']);
      session.socket.emit(
        event.wire(
          'call_sdp_answer',
          calleeClient: _peerClient,
          more: {'sdp': 'remote answer'},
        ),
      );
      await tester.pump();
      expect(session.media.operations, [
        'local offer',
        'remote answer',
        'candidate waiting candidate',
      ]);
      session.status(CallMediaStatus.connected);
      expect(session.call.phase, CallPhase.connected);
      session.call.end();
      expect(session.socket.actions.last, 'call_hangup');
      expect(session.call.phase, isNull);
      expect(session.media.disposals, 1);
    },
  );

  testWidgets(
    'incoming invite is shown globally and capture waits for acceptance',
    (tester) async {
      final session = _Harness(2);
      addTearDown(session.socket.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [callControllerProvider.overrideWith((_) => session.call)],
          child: const MaterialApp(
            localizationsDelegates: [AppLocalizationsDelegate()],
            home: CallOverlay(child: Scaffold(body: TextField())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CallOverlay), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'draft on another page');
      const event = _Event();
      session.socket.emit(event.wire('call_invite'));
      await tester.pumpAndSettle();
      expect(find.text('Incoming video call'), findsOneWidget);
      expect(find.text('Private peer'), findsOneWidget);
      expect(session.openedModes, isEmpty);
      expect(find.text('draft on another page'), findsOneWidget);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(session.openedModes, [CallMode.video]);
      final client =
          session.socket.payload('call_accept')['client_id'] as String;
      session.socket.emit(
        event.wire(
          'call_sdp_offer',
          calleeClient: client,
          more: {'sdp': 'remote offer'},
        ),
      );
      await tester.pump();
      expect(session.media.operations, isEmpty);
      session.socket.emit(event.wire('call_accept', calleeClient: client));
      await tester.pumpAndSettle();
      expect(session.media.operations, ['remote offer', 'local answer']);
      expect(session.socket.actions, ['call_accept', 'call_sdp_answer']);
      session.socket.emit(event.wire('call_hangup', calleeClient: client));
      await tester.pumpAndSettle();
      expect(find.text('Call ended'), findsOneWidget);
      expect(find.text('draft on another page'), findsOneWidget);
      expect(session.media.disposals, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('busy, ring timeout and another device release resources', (
    tester,
  ) async {
    final caller = _Harness(1);
    final callee = _Harness(2);
    addTearDown(caller.dispose);
    addTearDown(callee.dispose);
    await caller.call.start(conversationId: 8, mode: CallMode.video);
    final invite = caller.socket.payload('call_invite');
    final event = _Event(
      id: invite['call_id'] as String,
      callerClient: invite['client_id'] as String,
    );
    caller.socket.emit(event.wire('call_busy'));
    expect(caller.call.outcome, CallOutcome.busy);
    expect(caller.media.disposals, 1);
    await caller.call.start(conversationId: 8, mode: CallMode.voice);
    await tester.pump(callRingTimeout);
    expect(caller.call.outcome, CallOutcome.timeout);
    expect(caller.socket.actions.last, 'call_cancel');

    await caller.call.start(conversationId: 8, mode: CallMode.voice);
    final finalInvite = caller.socket.payload('call_invite');
    caller.socket.emit({
      'type': 'error',
      'data': <String, dynamic>{'call_id': _callId},
    });
    expect(caller.call.phase, CallPhase.ringing);
    caller.socket.emit({
      'type': 'error',
      'data': <String, dynamic>{'call_id': finalInvite['call_id']},
    });
    expect(caller.call.outcome, CallOutcome.unavailable);

    final lateMedia = Completer<CallMediaSession>();
    callee.mediaWait = lateMedia.future;
    callee.socket.emit(const _Event().wire('call_invite'));
    await tester.pump();
    expect(callee.call.phase, CallPhase.incoming);
    final accepting = callee.call.accept();
    await tester.pump();
    expect(callee.call.phase, CallPhase.preparing);
    callee.socket.emit(
      const _Event().wire('call_accept', calleeClient: _otherClient),
    );
    expect(callee.call.outcome, CallOutcome.answeredElsewhere);
    lateMedia.complete(callee.media);
    await accepting;
    expect(callee.media.disposals, 1);
    expect(callee.socket.sent, isEmpty);
  });

  testWidgets('permission errors and session changes close the private call', (
    tester,
  ) async {
    final session = _Harness(2);
    addTearDown(session.dispose);
    session.mediaError = CallMediaError.permissionDenied;
    session.socket.emit(const _Event().wire('call_invite'));
    await tester.pump();
    await session.call.accept();
    expect(session.call.mediaError, CallMediaError.permissionDenied);
    expect(session.socket.actions, ['call_reject']);

    session.mediaError = null;
    await session.call.start(conversationId: 8, mode: CallMode.voice);
    session.tokens.beginSessionChange();
    expect(session.call.phase, isNull);
    expect(session.call.mediaError, isNull);
    expect(session.media.disposals, 1);
    expect(session.socket.actions, ['call_reject', 'call_invite']);
  });
}

const _callId = '00000000-0000-0000-0000-000000000001';
const _peerClient = '00000000-0000-0000-0000-000000000002';
const _otherClient = '00000000-0000-0000-0000-000000000003';

class _Event {
  const _Event({this.id = _callId, this.callerClient = _peerClient});

  final String id, callerClient;

  Map<String, dynamic> wire(
    String type, {
    String? callerClient,
    String? calleeClient,
    Map<String, Object> more = const {},
  }) => {
    'type': type,
    'data': <String, dynamic>{
      'call_id': id,
      'conversation_id': 8,
      'caller_id': 1,
      'callee_id': 2,
      'mode': 'video',
      'caller_client_id': callerClient ?? this.callerClient,
      if (calleeClient != null) 'callee_client_id': calleeClient,
      ...more,
    },
    'timestamp': 1,
  };
}

class _Harness {
  _Harness(int user) : tokens = _TestTokens(user) {
    socket = _Socket(tokens);
    call = CallController(
      realtime: socket,
      tokenStore: tokens,
      iceServers: ({CancelToken? cancelToken}) async => [
        {
          'urls': ['stun:local.example'],
        },
      ],
      peerName: (_, _) async => 'Private peer',
      openMedia:
          ({
            required mode,
            required iceServers,
            required onCandidate,
            required onStatus,
            required current,
          }) async {
            openedModes.add(mode);
            openedIceServers.add(iceServers);
            candidate = onCandidate;
            status = onStatus;
            if (mediaError case final error?) throw error;
            return await mediaWait ?? media;
          },
    );
  }

  final _TestTokens tokens;
  final media = _Media();
  final openedModes = <CallMode>[];
  final openedIceServers = <List<Map<String, Object>>>[];
  late final _Socket socket;
  late final CallController call;
  late void Function(CallCandidate) candidate;
  late void Function(CallMediaStatus) status;
  CallMediaError? mediaError;
  Future<CallMediaSession>? mediaWait;

  Future<void> dispose() async {
    call.dispose();
    await socket.dispose();
  }
}

class _Socket extends RealtimeService {
  _Socket(TokenStore tokens) : super(config: _config, tokenStore: tokens);

  final _listeners = <RealtimeListener>{};
  final sent = <Map<String, dynamic>>[];
  Iterable<String> get actions => sent.map((item) => item['type'] as String);

  @override
  bool get isConnected => true;

  @override
  void addListener(RealtimeListener listener) => _listeners.add(listener);

  @override
  void removeListener(RealtimeListener listener) => _listeners.remove(listener);

  @override
  bool send(Map<String, dynamic> payload) {
    sent.add(payload);
    return true;
  }

  Map<String, Object> payload(String type) =>
      sent.lastWhere((item) => item['type'] == type)['data']
          as Map<String, Object>;

  void emit(Map<String, dynamic> event) {
    for (final listener in _listeners) {
      listener(event);
    }
  }
}

class _TestTokens extends TokenStore {
  _TestTokens(this.user);
  final int user;

  @override
  Future<TokenPair?> read() async {
    final claims = base64Url.encode(utf8.encode(jsonEncode({'userId': user})));
    return TokenPair(
      accessToken: 'x.$claims.x',
      refreshToken: 'refresh',
      sessionId: 'session',
    );
  }
}

class _Media implements CallMediaSession {
  final operations = <String>[];
  void Function()? onLocalDescription;
  int disposals = 0;

  @override
  RTCVideoRenderer? get localVideo => null;

  @override
  RTCVideoRenderer? get remoteVideo => null;

  @override
  Future<void> addCandidate(CallCandidate candidate) async {
    operations.add('candidate ${candidate.candidate}');
  }

  @override
  Future<String> localDescription({required bool offer}) async {
    final sdp = offer ? 'local offer' : 'local answer';
    operations.add(sdp);
    onLocalDescription?.call();
    return sdp;
  }

  @override
  Future<void> remoteDescription(String sdp, {required bool offer}) async {
    operations.add(sdp);
  }

  @override
  Future<void> dispose() async => disposals++;
}

const _config = AppConfig(
  apiBaseUrl: 'https://example.test',
  wsBaseUrl: 'wss://example.test',
  storageBaseUrl: 'https://example.test',
);
