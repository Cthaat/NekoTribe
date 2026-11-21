import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/features/media/data/media_api.dart';
import 'package:nekotribe/features/posts/domain/post_models.dart';

void main() {
  test(
    'desktop download validates metadata and requests bounded ranges in order',
    () async {
      const limit = 4 * 1024 * 1024;
      const size = limit + 3;
      final requests = <String>[];
      var invalidRange = false;
      final api = _createApi((options) {
        expect(options.path, '/api/v2/media/7/content');
        expect(options.headers['Authorization'], 'Bearer current-access');
        expect(options.followRedirects, isFalse);
        final range = options.headers['range'] ?? options.headers['Range'];
        requests.add('${options.method} $range');
        final binary = <String, List<String>>{
          Headers.contentTypeHeader: ['application/octet-stream'],
        };
        if (options.method == 'HEAD') {
          return ResponseBody.fromBytes(
            [],
            200,
            headers: {
              ...binary,
              Headers.contentLengthHeader: ['$size'],
            },
          );
        }
        final first = range == 'bytes=0-${limit - 1}';
        final contentRange = first
            ? 'bytes 0-${limit - 1}/$size'
            : 'bytes $limit-${size - 1}/$size';
        return ResponseBody.fromBytes(
          Uint8List(first ? limit : 3),
          206,
          headers: {
            ...binary,
            'content-range': [invalidRange ? 'bytes 1-3/$size' : contentRange],
          },
        );
      });
      final asset = V2MediaAsset.fromJson({
        'media_id': 7,
        'public_url': '/api/v2/media/7/content',
      });
      final parts = api.downloadPrivateParts(asset, cancelToken: CancelToken());
      await expectLater(
        parts.map((part) => part.length),
        emitsInOrder([limit, 3, emitsDone]),
      );
      expect(requests, [
        'HEAD null',
        'GET bytes=0-${limit - 1}',
        'GET bytes=$limit-${size - 1}',
      ]);
      invalidRange = true;
      await expectLater(
        api
            .downloadPrivateParts(asset, cancelToken: CancelToken())
            .drain<void>(),
        throwsFormatException,
      );
    },
  );

  test(
    'a chunked private video refreshes an expired session without replay',
    () async {
      final store = _TokenStore();
      final calls = <String>[];
      final uploads = <String>[];
      final api = _createApi(
        (options) {
          calls.add(options.path);
          if (options.path == '/api/v2/auth/tokens/current') {
            return _jsonResponse(200, {
              'code': 200,
              'data': {
                'access_token': 'fresh-access',
                'refresh_token': 'fresh-refresh',
                'session_id': 'current-session',
                'access_token_expires_at': '2027-01-01T00:00:00.000Z',
                'refresh_token_expires_at': '2027-02-01T00:00:00.000Z',
              },
            });
          }
          expect(options.path, '/api/v2/media/private');
          expect(options.followRedirects, isFalse);
          final auth = options.headers['Authorization'];
          return auth == 'Bearer current-access'
              ? _jsonResponse(401, {'code': 40101})
              : _jsonResponse(200, _uploadReceipt('/api/v2/media/7/content'));
        },
        store: store,
        onBody: (bytes) => uploads.add(utf8.decode(bytes)),
      );
      Future<V2MediaAsset> send() => api.uploadStream(
        chunks: Stream.fromIterable([
          utf8.encode('test-video '),
          utf8.encode('with two chunks'),
        ]),
        length: 26,
        fileName: 'clip.mp4',
        mediaType: 'video',
        accessScope: 'post',
      );
      await expectLater(
        send(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
      );
      expect(calls, ['/api/v2/media/private', '/api/v2/auth/tokens/current']);
      expect((await store.read())?.accessToken, 'fresh-access');
      expect((await send()).privateContentPath, '/api/v2/media/7/content');
      final parts = uploads.where(
        (body) => body.contains('filename="clip.mp4"'),
      );
      expect(parts, hasLength(2));
      for (final body in parts) {
        expect(body, contains('content-type: video/mp4'));
        expect(body, contains('test-video with two chunks'));
        expect(body, contains('name="media_type"\r\n\r\nvideo'));
        expect(body, contains('name="access_scope"\r\n\r\npost'));
      }
    },
  );

  test(
    'private upload binds only a matching canonical returned path',
    () async {
      var path = '/api/v2/media/7/content';
      final api = _createApi((options) {
        expect(options.path, '/api/v2/media/private');
        expect(options.followRedirects, isFalse);
        expect(
          Map.fromEntries((options.data as FormData).fields)['access_scope'],
          'chat',
        );
        return _jsonResponse(200, _uploadReceipt(path));
      });
      Future<V2MediaAsset> upload() => api.uploadBytes(
        bytes: Uint8List.fromList([1, 2, 3]),
        fileName: 'example.bin',
        mediaType: 'file',
        accessScope: 'chat',
      );

      expect((await upload()).privateContentPath, path);
      for (path in [
        '/api/v2/media/8/content',
        '/api/v2/media/07/content',
        '/api/v2/media/7/content?anything=1',
        'https://example.test/api/v2/media/7/content',
        '/storage/example.bin',
      ]) {
        await expectLater(upload(), throwsFormatException);
      }
    },
  );

  test('public uploads keep the original route', () async {
    final paths = <(String, String?)>[];
    var receipt = _uploadReceipt('/storage/example.bin');
    final api = _createApi((options) {
      paths.add((
        options.path,
        Map.fromEntries((options.data as FormData).fields)['access_scope'],
      ));
      return _jsonResponse(200, receipt);
    });
    for (final scope in [null, 'public']) {
      await api.uploadBytes(
        bytes: Uint8List(1),
        fileName: 'example.bin',
        accessScope: scope,
      );
    }
    expect(paths, [('/api/v2/media', null), ('/api/v2/media', 'public')]);
    final valid = receipt;
    for (final invalid in [
      {...valid, 'message': 'success'},
      {...valid}..remove('meta'),
      _uploadReceipt('/api/v2/media/7/content'),
      _uploadReceipt(' '),
    ]) {
      receipt = invalid;
      await expectLater(
        api.uploadBytes(bytes: Uint8List(1), fileName: 'example.bin'),
        throwsFormatException,
      );
    }
  });

  test(
    'private uploads reject an unavailable route or redirect without fallback',
    () async {
      final requests = <(String, String?)>[];
      var status = 404;
      final api = _createApi((options) {
        expect(options.followRedirects, isFalse);
        requests.add((
          options.path,
          Map.fromEntries((options.data as FormData).fields)['access_scope'],
        ));
        return ResponseBody.fromString(
          '{"code":404,"message":"unavailable"}',
          status,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
            if (status == 307) 'location': ['/api/v2/media'],
          },
        );
      });
      Future<V2MediaAsset> upload(String scope) => api.uploadBytes(
        bytes: Uint8List(1),
        fileName: 'example.bin',
        accessScope: scope,
      );
      await expectLater(upload('post'), throwsException);
      status = 307;
      await expectLater(upload('chat'), throwsException);
      await expectLater(upload('invalid'), throwsArgumentError);
      expect(requests, [
        ('/api/v2/media/private', 'post'),
        ('/api/v2/media/private', 'chat'),
      ]);
    },
  );

  test(
    'private download uses current API auth and accepts binary only',
    () async {
      final requested = <Uri>[];
      var type = 'application/octet-stream';
      final api = _createApi((options) {
        requested.add(options.uri);
        expect(options.followRedirects, isFalse);
        expect(options.headers['Authorization'], 'Bearer current-access');
        return ResponseBody.fromBytes(
          [1, 2, 3],
          200,
          headers: {
            Headers.contentTypeHeader: [type],
            'cache-control': ['private, no-store'],
          },
        );
      });
      V2MediaAsset asset(int id, String url) =>
          V2MediaAsset.fromJson({'media_id': id, 'public_url': url});
      Future<Uint8List> download(V2MediaAsset asset) =>
          api.downloadPrivate(asset, cancelToken: CancelToken());

      await expectLater(
        download(asset(8, '/api/v2/media/7/content')),
        throwsFormatException,
      );
      await expectLater(
        download(
          asset(9007199254740992, '/api/v2/media/9007199254740992/content'),
        ),
        throwsFormatException,
      );
      expect(requested, isEmpty);
      final canonical = asset(7, '/api/v2/media/7/content');
      expect(await download(canonical), [1, 2, 3]);
      expect(
        requested.single.toString(),
        'https://example.test/api/v2/media/7/content',
      );
      type = 'text/html';
      await expectLater(download(canonical), throwsA(isA<ApiException>()));
    },
  );
}

Map<String, Object?> _uploadReceipt(String url) => {
  'code': 200,
  'message': 'media uploaded',
  'meta': null,
  'data': {
    'media_id': 7,
    'public_url': url,
    'status': 'ready',
    'thumbnail_url': null,
  },
};

ResponseBody _jsonResponse(int status, Map<String, Object?> data) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

MediaApi _createApi(
  ResponseBody Function(RequestOptions) response, {
  _TokenStore? store,
  void Function(List<int>)? onBody,
}) {
  final dio = Dio()..httpClientAdapter = _MediaAdapter(response, onBody);
  final client = ApiClient(
    config: const AppConfig(
      apiBaseUrl: 'https://example.test',
      wsBaseUrl: 'wss://example.test',
      storageBaseUrl: 'https://assets.example.test',
    ),
    tokenStore: store ?? _TokenStore(),
    dio: dio,
  );
  addTearDown(client.dispose);
  return MediaApi(client);
}

class _MediaAdapter implements HttpClientAdapter {
  _MediaAdapter(this.response, this.onBody);

  final ResponseBody Function(RequestOptions) response;
  final void Function(List<int>)? onBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (onBody != null && requestStream != null) {
      final bytes = await requestStream.expand((chunk) => chunk).toList();
      onBody!(bytes);
    }
    return response(options);
  }

  @override
  void close({bool force = false}) {}
}

class _TokenStore extends TokenStore {
  TokenPair _pair = const TokenPair(
    accessToken: 'current-access',
    refreshToken: 'current-refresh',
    sessionId: 'current-session',
  );

  @override
  Future<TokenPair?> read() async => _pair;

  @override
  Future<bool> writeIfCurrent(TokenPair pair, int expectedRevision) async {
    if (revision != expectedRevision) return false;
    _pair = pair;
    return true;
  }

  @override
  Future<String> deviceFingerprint() async => 'fingerprint';
}
