import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/features/chat/presentation/chat_realtime_binding.dart';
import 'package:nekotribe/features/realtime/data/realtime_service.dart';

const config = AppConfig(
  apiBaseUrl: 'http://example.test',
  wsBaseUrl: 'ws://example.test',
  storageBaseUrl: 'http://example.test',
);

class Store extends TokenStore {
  Completer<TokenPair?>? pending;
  @override
  Future<TokenPair?> read() async =>
      pending?.future ??
      const TokenPair(
        accessToken: 'e30.eyJ1c2VySWQiOjQyfQ.synthetic',
        refreshToken: 'r',
        sessionId: 's',
      );
}

class Sink implements WebSocketSink {
  int closes = 0;
  int sends = 0;
  bool failWrites = false;
  final frames = <Object?>[];
  @override
  void add(dynamic data) {
    if (failWrites) throw StateError('fixture transport failure');
    sends++;
    frames.add(jsonDecode(data as String));
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    closes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Channel implements WebSocketChannel {
  Channel({Completer<void>? cancellation, Future<void>? readiness})
    : ready = readiness ?? Future<void>.value(),
      controller = StreamController<dynamic>(
        onCancel: () => cancellation?.future,
      );
  final StreamController<dynamic> controller;
  @override
  final Future<void> ready;
  @override
  final Sink sink = Sink();
  @override
  Stream<dynamic> get stream => controller.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  String status(String state, {int userId = 42, Object timestamp = 1}) =>
      jsonEncode({
        'type': 'system_notification',
        'timestamp': timestamp,
        'data': {
          'code': 'realtime_status',
          'user_id': userId,
          'server_id': 'fixture',
          'local_presence': true,
          'remote_events': state,
        },
      });

  test('connection and sends wait for a successful handshake', () async {
    final gate = Completer<void>();
    final channel = Channel(readiness: gate.future);
    final service = RealtimeService(
      config: config,
      tokenStore: Store(),
      channelFactory: (_) => channel,
    );
    final opening = service.connect();
    await Future<void>.delayed(Duration.zero);
    try {
      expect(service.isConnected, false);
      service.send({'type': 'synthetic'});
      expect(channel.sink.sends, 0);
    } finally {
      gate.complete();
      await opening;
      await service.disconnect();
    }
  });

  test('channel join is sent again after a socket write failure', () async {
    final store = Store();
    final channels = <Channel>[];
    final reconnecting = Completer<Channel>();
    final service = RealtimeService(
      config: config,
      tokenStore: store,
      channelFactory: (_) {
        final channel = Channel();
        channels.add(channel);
        if (channels.length == 2) reconnecting.complete(channel);
        return channel;
      },
    );
    final binding = ChatRealtimeBinding(
      tokenStore: store,
      channelId: 12,
      onEvent: (_) {},
      onReset: () {},
      onReload: () {},
    )..bind(service);
    try {
      await service.connect();
      final first = channels.single;
      first.sink.failWrites = true;
      first.controller.add(status('connected'));
      await Future<void>.delayed(Duration.zero);
      expect(first.sink.closes, 1);
      expect(service.remoteEvents, RemoteEvents.unknown);
      expect(first.sink.frames, isEmpty);

      final second = await reconnecting.future.timeout(
        const Duration(seconds: 3),
      );
      expect(second, isNot(same(first)));
      expect(second.sink.frames, isEmpty);
      second.controller.add(status('connected'));
      await Future<void>.delayed(Duration.zero);
      expect(second.sink.frames, [
        {
          'type': 'chat_join_channel',
          'data': {'channelId': 12},
        },
      ]);
    } finally {
      binding.dispose();
      await service.dispose();
    }
  });

  test(
    'valid status is owner-bound and remote recovery is emitted once',
    () async {
      final store = Store(), channel = Channel();
      final service = RealtimeService(
        config: config,
        tokenStore: store,
        channelFactory: (_) => channel,
      );
      await service.connect();
      try {
        expect(service.remoteEvents.name, 'unknown');
        var recovered = 0;
        final sub = service.recovery.listen((_) => recovered++);
        try {
          for (final frame in [
            status('unavailable'),
            status('connected', userId: 43),
            status('connected', timestamp: 1.5),
          ]) {
            channel.controller.add(frame);
          }
          await Future<void>.delayed(Duration.zero);
          expect(service.remoteEvents.name, 'unavailable');
          expect(recovered, 0);
          channel.controller.add(status('connected'));
          channel.controller.add(status('connected'));
          await Future<void>.delayed(Duration.zero);
          expect(service.remoteEvents.name, 'connected');
          expect(recovered, 1);
          store.beginSessionChange();
          expect(service.remoteEvents.name, 'unknown');
        } finally {
          await sub.cancel();
        }
      } finally {
        await service.disconnect();
      }
    },
  );

  test(
    'failed handshake never reports connected and releases its transport',
    () async {
      final gate = Completer<void>();
      final channel = Channel(readiness: gate.future);
      final service = RealtimeService(
        config: config,
        tokenStore: Store(),
        channelFactory: (_) => channel,
      );
      final changes = <bool>[];
      final subscription = service.connection.listen(changes.add);
      try {
        final opening = service.connect();
        await Future<void>.delayed(Duration.zero);
        gate.completeError(StateError('synthetic handshake failure'));
        await opening;
        await Future<void>.delayed(Duration.zero);
        expect(changes, isEmpty);
        expect(service.isConnected, false);
        expect(channel.sink.closes, 1);
      } finally {
        await subscription.cancel();
        await service.dispose();
      }
    },
  );

  test(
    'same account login reconnects only after the token transition settles',
    () async {
      final store = Store(), channels = <Channel>[];
      final gate = Completer<void>();
      final service = RealtimeService(
        config: config,
        tokenStore: store,
        channelFactory: (_) {
          final channel = Channel();
          channels.add(channel);
          return channel;
        },
      );
      try {
        await service.connect();
        final transition = store.runSessionChange((_) => gate.future);
        expect(service.isConnected, false);
        await service.connect();
        expect(channels.length, 1);
        gate.complete();
        await transition;
        await service.connect();
        expect(channels.length, 2);
        expect(channels.first.sink.closes, 1);
        expect(service.isConnected, true);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await service.dispose();
      }
    },
  );
  test(
    'replaced session cannot receive or send through the old channel',
    () async {
      final store = Store(), channels = <Channel>[];
      var messages = 0;
      final service = RealtimeService(
        config: config,
        tokenStore: store,
        channelFactory: (uri) {
          final channel = Channel();
          channels.add(channel);
          return channel;
        },
      );
      service.addListener((event) {
        messages++;
      });
      await service.connect();
      service.send({'type': 'synthetic'});
      expect(channels.single.sink.sends, 1);
      store.beginSessionChange();
      channels.single.controller.add('{"type":"synthetic"}');
      service.send({'type': 'synthetic'});
      await Future<void>.delayed(Duration.zero);
      expect(messages, 0);
      expect(channels.single.sink.sends, 1);
      expect(service.isConnected, false);
      await service.connect();
      expect(channels.length, 2);
      service.send({'type': 'synthetic'});
      expect(channels.last.sink.sends, 1);
      await service.disconnect();
    },
  );
  test(
    'old disconnect closes only old resources while a new connection opens',
    () async {
      final store = Store(),
          cancellation = Completer<void>(),
          channels = <Channel>[];
      final service = RealtimeService(
        config: config,
        tokenStore: store,
        channelFactory: (uri) {
          final channel = Channel(
            cancellation: channels.isEmpty ? cancellation : null,
          );
          channels.add(channel);
          return channel;
        },
      );
      await service.connect();
      final closing = service.disconnect();
      await service.connect();
      try {
        expect(channels.length, 2);
        cancellation.complete();
        await closing;
        expect(service.isConnected, true);
        expect(channels[0].sink.closes, 1);
        expect(channels[1].sink.closes, 0);
      } finally {
        if (!cancellation.isCompleted) cancellation.complete();
        await closing;
        await service.disconnect();
      }
    },
  );
  test(
    'a pending open cannot revive after disconnect or session replacement',
    () async {
      for (final disconnect in [true, false]) {
        final store = Store()..pending = Completer<TokenPair?>();
        var connections = 0;
        final service = RealtimeService(
          config: config,
          tokenStore: store,
          channelFactory: (uri) {
            connections++;
            return Channel();
          },
        );
        final opening = service.connect();
        if (disconnect) {
          await service.disconnect();
        } else {
          store.beginSessionChange();
        }
        store.pending!.complete(
          const TokenPair(
            accessToken: 'old',
            refreshToken: 'r',
            sessionId: 's',
          ),
        );
        await opening;
        try {
          expect(connections, 0);
          expect(service.isConnected, false);
        } finally {
          await service.disconnect();
        }
      }
    },
  );
}
