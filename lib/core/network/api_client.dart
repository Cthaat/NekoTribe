import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../auth/token_store.dart';
import '../config/app_config.dart';
import '../constants/api_paths.dart';
import 'api_exception.dart';
import 'api_response.dart';
import 'strict_redirect_native.dart'
    if (dart.library.js_interop) 'strict_redirect_web.dart';

typedef LogoutCallback = Future<void> Function();

class ApiClient {
  ApiClient({
    required this.config,
    required this.tokenStore,
    this.onLogout,
    Dio? dio,
  }) : _dio = dio ?? createApiDio(),
       _endpointRevision = tokenStore.endpointRevision {
    _dio.options
      ..baseUrl = config.apiBaseUrl
      ..connectTimeout = const Duration(seconds: 20)
      ..receiveTimeout = const Duration(seconds: 30)
      ..sendTimeout = const Duration(seconds: 60)
      ..responseType = ResponseType.json
      ..validateStatus = (_) => true;
    _dio.options.extra['withCredentials'] = true;
    _dio.interceptors.add(_buildInterceptor());
  }

  final AppConfig config;
  final TokenStore tokenStore;
  final LogoutCallback? onLogout;
  final Dio _dio;
  final int _endpointRevision;
  final _uuid = const Uuid();
  bool _disposed = false;
  bool get _inactive =>
      _disposed || _endpointRevision != tokenStore.endpointRevision;

  Future<void>? _refreshFuture;
  int? _refreshRevision;
  static const _authRevision = 'nekotribe.auth.revision';
  static const _authRetried = 'nekotribe.auth.retried';
  static const trustedDeviceCookie = 'nekotribe_trusted_device';

  Dio get raw => _dio;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _dio.close(force: true);
  }

  DioException _endpointChanged(RequestOptions options) => DioException(
    requestOptions: options,
    type: DioExceptionType.cancel,
    error: StateError('Endpoint changed'),
  );

  Future<ApiResponse<T>> request<T>(
    String path, {
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    T Function(dynamic data)? decode,
    bool sendAuth = true,
    void Function(Object? envelope)? validateSuccessEnvelope,
    void Function(String proof)? onTrustedDeviceProof,
    CancelToken? cancelToken,
  }) async {
    if (_inactive) {
      throw _endpointChanged(RequestOptions(path: path, method: method));
    }
    final interactiveAuth = ApiPaths.isInteractiveAuthPath(path);
    final options = Options(
      method: method,
      headers: headers,
      extra: interactiveAuth ? {_authRevision: tokenStore.revision} : null,
      followRedirects:
          path == ApiPaths.authTokens ||
              interactiveAuth ||
              onTrustedDeviceProof != null
          ? false
          : null,
    );
    final response = await _dio.request<dynamic>(
      path,
      data: data,
      queryParameters: _sanitizeQuery(query),
      options: options,
      cancelToken: cancelToken,
    );
    if (_inactive) throw _endpointChanged(response.requestOptions);
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300) {
      validateSuccessEnvelope?.call(response.data);
    }
    final result = await _processResponse<T>(
      path: path,
      method: method,
      data: data,
      query: query,
      headers: headers,
      response: response,
      decode: decode,
      sendAuth: sendAuth,
    );
    if (!_inactive &&
        !kIsWeb &&
        onTrustedDeviceProof != null &&
        status >= 200 &&
        status < 300) {
      for (final header in _setCookieHeaderValues(response)) {
        final proof = _cookieValue(header, trustedDeviceCookie);
        final secure = header
            .split(';')
            .skip(1)
            .any((part) => part.trim().toLowerCase() == 'secure');
        if (proof != null &&
            isTrustedDeviceProof(proof) &&
            (!secure || response.requestOptions.uri.scheme == 'https')) {
          onTrustedDeviceProof(proof);
          break;
        }
      }
    }
    return result;
  }

  Future<T> requestData<T>(
    String path, {
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    T Function(dynamic data)? decode,
    bool sendAuth = true,
    void Function(Object? envelope)? validateSuccessEnvelope,
    CancelToken? cancelToken,
  }) async {
    final res = await request<T>(
      path,
      method: method,
      data: data,
      query: query,
      headers: headers,
      decode: decode,
      sendAuth: sendAuth,
      validateSuccessEnvelope: validateSuccessEnvelope,
      cancelToken: cancelToken,
    );
    return res.data;
  }

  Future<PagedResult<T>> requestPaged<T>(
    String path, {
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    required T Function(dynamic item) decodeItem,
    bool sendAuth = true,
    CancelToken? cancelToken,
  }) async {
    final res = await request<dynamic>(
      path,
      method: method,
      data: data,
      query: query,
      headers: headers,
      sendAuth: sendAuth,
      cancelToken: cancelToken,
    );
    return PagedResult<T>(
      items: _decodePagedItems(res.data, decodeItem),
      meta: res.meta ?? _decodePagedMeta(res.data),
    );
  }

  Future<List<T>> requestList<T>(
    String path, {
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    required T Function(dynamic item) decodeItem,
    bool sendAuth = true,
  }) async {
    final page = await requestPaged<T>(
      path,
      method: method,
      data: data,
      query: query,
      headers: headers,
      decodeItem: decodeItem,
      sendAuth: sendAuth,
    );
    return page.items;
  }

  List<T> _decodePagedItems<T>(
    dynamic raw,
    T Function(dynamic item) decodeItem,
  ) {
    if (raw is List) {
      return raw.map(decodeItem).toList();
    }
    if (raw is Map) {
      final items = raw['items'];
      if (items is List) {
        return items.map(decodeItem).toList();
      }
    }
    return <T>[];
  }

  ApiMeta? _decodePagedMeta(dynamic raw) {
    if (raw is Map) {
      final meta = raw['meta'];
      if (meta is Map<String, dynamic>) {
        return ApiMeta.fromJson(meta);
      }
      if (meta is Map) {
        return ApiMeta.fromJson(Map<String, dynamic>.from(meta));
      }
    }
    return null;
  }

  Map<String, dynamic>? _sanitizeQuery(Map<String, dynamic>? query) {
    if (query == null) return null;
    final result = <String, dynamic>{};
    query.forEach((key, value) {
      if (value == null) return;
      if (value is bool) {
        result[key] = value ? 'true' : 'false';
      } else {
        result[key] = value;
      }
    });
    return result.isEmpty ? null : result;
  }

  Future<ApiResponse<T>> _processResponse<T>({
    required String path,
    required String method,
    required Object? data,
    required Map<String, dynamic>? query,
    required Map<String, String>? headers,
    required Response<dynamic> response,
    required T Function(dynamic data)? decode,
    required bool sendAuth,
  }) async {
    final status = response.statusCode ?? 0;
    final body = response.data;
    final retryAfterValues = status == 429
        ? response.headers['retry-after']
        : null;
    final retryAfter = retryAfterValues?.length == 1
        ? retryAfterValues!.single
        : null;
    final retryAfterSeconds =
        retryAfter != null && RegExp(r'^\d+$').hasMatch(retryAfter)
        ? int.tryParse(retryAfter)
        : null;

    // 401 自动刷新逻辑：通过 interceptor 实现，这里只处理统一响应
    if (body is Map<String, dynamic>) {
      final envelope = _v2Envelope(body);
      if (!_isV2Envelope(envelope)) {
        if (status >= 200 && status < 300) {
          return ApiResponse<T>(
            code: status,
            message: 'OK',
            data: decode == null ? body as T : decode(body),
          );
        }
        throw ApiException(
          code: status,
          statusCode: status,
          retryAfterSeconds: retryAfterSeconds,
          message: 'HTTP $status',
          data: body,
        );
      }
      final code = (envelope['code'] is num)
          ? (envelope['code'] as num).toInt()
          : status;
      final message = (envelope['message'] is String)
          ? envelope['message'] as String
          : 'request failed';
      final raw = envelope['data'];
      final metaJson = envelope['meta'];
      final meta = metaJson is Map<String, dynamic>
          ? ApiMeta.fromJson(metaJson)
          : null;
      if (status >= 200 && status < 300 && code < 30000) {
        final effectiveRaw = _mergeAuthCookiesIntoData(
          path: path,
          data: raw,
          response: response,
        );
        return ApiResponse<T>(
          code: code,
          message: message,
          data: decode == null ? effectiveRaw as T : decode(effectiveRaw),
          meta: meta,
        );
      }
      throw ApiException(
        code: code,
        statusCode: status,
        retryAfterSeconds: retryAfterSeconds,
        message: message,
        data: raw,
      );
    }

    if (status >= 200 && status < 300) {
      final decoded = decode == null ? body as T : decode(body);
      return ApiResponse<T>(code: status, message: 'OK', data: decoded);
    }

    throw ApiException(
      code: status,
      statusCode: status,
      retryAfterSeconds: retryAfterSeconds,
      message: 'HTTP $status',
      data: body,
    );
  }

  Map<String, dynamic> _v2Envelope(Map<String, dynamic> body) {
    if (body['code'] is num || body.containsKey('meta')) return body;
    final nested = body['data'];
    if (nested is Map<String, dynamic> &&
        (nested['code'] is num || nested.containsKey('meta'))) {
      return nested;
    }
    return body;
  }

  bool _isV2Envelope(Map<String, dynamic> body) {
    if (body['code'] is num || body.containsKey('meta')) return true;
    return body.containsKey('data') && body['message'] is String;
  }

  Interceptor _buildInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (_inactive) {
          handler.reject(_endpointChanged(options));
          return;
        }
        final sendBearer =
            !ApiPaths.isAuthEntryPath(options.path) ||
            ApiPaths.isRefreshPath(options.path);
        if (sendBearer) {
          options.extra.putIfAbsent(_authRevision, () => tokenStore.revision);
        }
        // 标准头
        options.headers['x-request-id'] = _uuid.v4();
        options.headers['x-client-platform'] = _platformTag();
        try {
          options.headers['x-device-fingerprint'] = await tokenStore
              .deviceFingerprint();
        } catch (_) {}
        options.headers['x-device-info'] = _deviceInfo();

        // refresh path 也需要 access token；登录入口不需要

        if (sendBearer) {
          final pair = await tokenStore.read();
          if (pair != null && pair.accessToken.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer ${pair.accessToken}';
          }
        }
        if (!options.headers.keys.any((key) => key.toLowerCase() == 'accept')) {
          options.headers['Accept'] = 'application/json';
        }
        if (_inactive) {
          handler.reject(_endpointChanged(options));
          return;
        }
        final revision = options.extra[_authRevision];
        if (revision is int && revision != tokenStore.revision) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
              error: StateError('Session changed'),
            ),
          );
          return;
        }
        handler.next(options);
      },
      onResponse: (response, handler) async {
        if (_inactive) {
          handler.reject(_endpointChanged(response.requestOptions));
          return;
        }
        final revision = response.requestOptions.extra[_authRevision];
        if (response.statusCode != 401 &&
            revision is int &&
            revision != tokenStore.revision) {
          handler.reject(
            DioException(
              requestOptions: response.requestOptions,
              type: DioExceptionType.cancel,
              error: StateError('Session changed'),
            ),
          );
          return;
        }
        final path = response.requestOptions.path;
        final status = response.statusCode ?? 0;
        final isAuthEntry = ApiPaths.isAuthEntryPath(path);
        final isRefresh = ApiPaths.isRefreshPath(path);

        if (status == 401 &&
            !isAuthEntry &&
            !isRefresh &&
            !ApiPaths.isCredentialMutationPath(
              path,
              method: response.requestOptions.method,
            )) {
          try {
            final retry = await _recoverUnauthorized(response.requestOptions);
            if (_inactive) {
              handler.reject(_endpointChanged(response.requestOptions));
              return;
            }
            if (retry != null) {
              handler.resolve(retry);
              return;
            }
          } on DioException catch (error) {
            handler.reject(error);
            return;
          }
        }
        handler.next(response);
      },
      onError: (DioException err, handler) async {
        if (_inactive) {
          handler.next(_endpointChanged(err.requestOptions));
          return;
        }
        final path = err.requestOptions.path;
        final status = err.response?.statusCode ?? 0;
        final isAuthEntry = ApiPaths.isAuthEntryPath(path);
        final isRefresh = ApiPaths.isRefreshPath(path);

        if (status == 401 &&
            !isAuthEntry &&
            !isRefresh &&
            !ApiPaths.isCredentialMutationPath(
              path,
              method: err.requestOptions.method,
            )) {
          try {
            final retry = await _recoverUnauthorized(err.requestOptions);
            if (_inactive) {
              handler.next(_endpointChanged(err.requestOptions));
              return;
            }
            if (retry != null) {
              handler.resolve(retry);
              return;
            }
          } on DioException catch (error) {
            handler.next(error);
            return;
          }
        }
        handler.next(err);
      },
    );
  }

  Future<void> _clearCurrent(int revision) async {
    if (_inactive) return;
    try {
      final cleared = await tokenStore.clearIfCurrent(revision);
      if (cleared && tokenStore.revision == revision + 1) {
        await onLogout?.call();
      }
    } catch (_) {
      // Return the original authentication failure even if local cleanup fails.
    }
  }

  Future<Response<dynamic>?> _recoverUnauthorized(
    RequestOptions options,
  ) async {
    final revision = options.extra[_authRevision];
    if (_inactive || revision is! int || revision != tokenStore.revision) {
      return null;
    }
    if (options.extra[_authRetried] == true) {
      await _clearCurrent(revision);
      return null;
    }
    try {
      await _refreshToken(revision);
    } catch (_) {
      await _clearCurrent(revision);
      return null;
    }
    if (_inactive || revision != tokenStore.revision) return null;
    final body = options.data;
    // Refresh the session, but leave the caller to submit a fresh upload.
    if (body is FormData && body.isFinalized) return null;
    options.extra[_authRetried] = true;
    options.headers.remove('Authorization');
    return _dio.fetch<dynamic>(options);
  }

  Future<void> _refreshToken(int revision) {
    final existing = _refreshFuture;
    if (existing != null && _refreshRevision == revision) return existing;
    late final Future<void> refresh;
    refresh = _performRefreshToken(revision).whenComplete(() {
      if (identical(_refreshFuture, refresh)) {
        _refreshFuture = null;
      }
    });
    _refreshFuture = refresh;
    _refreshRevision = revision;
    return refresh;
  }

  Future<void> _performRefreshToken(int revision) async {
    final pair = await tokenStore.read();
    if (_inactive || pair == null || revision != tokenStore.revision) {
      throw ApiException(
        code: 40101,
        message: 'No refresh token',
        statusCode: 401,
      );
    }
    final response = await _dio.patch<dynamic>(
      ApiPaths.authTokensCurrent,
      data: {'refresh_token': pair.refreshToken},
      options: Options(
        extra: {_authRevision: revision},
        headers: {'Cookie': 'refresh_token=${pair.refreshToken}'},
      ),
    );
    if (_inactive) throw _endpointChanged(response.requestOptions);
    final body = response.data;
    if (body is Map<String, dynamic> && body['code'] == 200) {
      final data = body['data'] as Map<String, dynamic>?;
      if (data != null) {
        final cookies = _authCookiesFromResponse(response);
        final updated = TokenPair.fromJson(data);
        if (updated.sessionId != pair.sessionId ||
            (cookies.accessToken != null &&
                cookies.accessToken != updated.accessToken) ||
            (cookies.refreshToken != null &&
                cookies.refreshToken != updated.refreshToken)) {
          throw const FormatException('Invalid refresh session or cookies');
        }
        if (!await tokenStore.writeIfCurrent(updated, revision)) {
          throw StateError('Session changed');
        }
      } else {
        throw StateError('Invalid refresh response');
      }
    } else {
      throw ApiException(
        code: 40101,
        message: 'Refresh failed',
        statusCode: 401,
        data: body,
      );
    }
  }

  String _platformTag() {
    if (kIsWeb) return 'flutter-web';
    try {
      if (Platform.isAndroid) return 'flutter-android';
      if (Platform.isIOS) return 'flutter-ios';
      if (Platform.isWindows) return 'flutter-windows';
      if (Platform.isMacOS) return 'flutter-macos';
      if (Platform.isLinux) return 'flutter-linux';
    } catch (_) {}
    return 'flutter';
  }

  String _deviceInfo() {
    if (kIsWeb) return 'flutter-web/${defaultTargetPlatform.name}';
    try {
      return '${Platform.operatingSystem}/${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'flutter-unknown';
    }
  }

  dynamic _mergeAuthCookiesIntoData({
    required String path,
    required dynamic data,
    required Response<dynamic> response,
  }) {
    if (data is! Map) return data;
    final cookies = _authCookiesFromResponse(response);
    if (cookies.isEmpty) return data;

    final normalized = Map<String, dynamic>.from(data);
    if (ApiPaths.isRefreshPath(path)) {
      _putCookieTokens(normalized, cookies);
      return normalized;
    }

    if (!ApiPaths.isAuthEntryPath(path)) return data;
    if (ApiPaths.isGitHubLoginCompletion(path)) {
      final login = normalized['login'];
      if (login is Map) {
        final loginData = Map<String, dynamic>.from(login);
        _mergeLoginCookies(loginData, cookies);
        normalized['login'] = loginData;
      }
    } else {
      _mergeLoginCookies(normalized, cookies);
    }
    return normalized;
  }

  void _mergeLoginCookies(Map<String, dynamic> login, _AuthCookies cookies) {
    final tokens = login['tokens'];
    if (tokens is Map) {
      final tokenMap = Map<String, dynamic>.from(tokens);
      _putCookieTokens(tokenMap, cookies);
      login['tokens'] = tokenMap;
    }
  }

  void _putCookieTokens(Map<String, dynamic> target, _AuthCookies cookies) {
    final accessToken = cookies.accessToken;
    final refreshToken = cookies.refreshToken;
    if (accessToken != null && accessToken.isNotEmpty) {
      target['access_token'] = accessToken;
    }
    if (refreshToken != null && refreshToken.isNotEmpty) {
      target['refresh_token'] = refreshToken;
    }
  }

  _AuthCookies _authCookiesFromResponse(Response<dynamic> response) {
    String? accessToken;
    String? refreshToken;
    for (final header in _setCookieHeaderValues(response)) {
      accessToken ??= _cookieValue(header, 'access_token');
      refreshToken ??= _cookieValue(header, 'refresh_token');
    }
    return _AuthCookies(accessToken: accessToken, refreshToken: refreshToken);
  }

  List<String> _setCookieHeaderValues(Response<dynamic> response) {
    final direct = response.headers['set-cookie'];
    if (direct != null && direct.isNotEmpty) return direct;
    for (final entry in response.headers.map.entries) {
      if (entry.key.toLowerCase() == 'set-cookie') {
        return entry.value;
      }
    }
    return const [];
  }

  String? _cookieValue(String setCookieHeader, String name) {
    final pair = setCookieHeader.split(';').first.trim();
    final equals = pair.indexOf('=');
    if (equals <= 0) return null;
    if (pair.substring(0, equals).trim() != name) return null;
    return pair.substring(equals + 1).trim();
  }
}

class _AuthCookies {
  const _AuthCookies({this.accessToken, this.refreshToken});

  final String? accessToken;
  final String? refreshToken;

  bool get isEmpty =>
      (accessToken == null || accessToken!.isEmpty) &&
      (refreshToken == null || refreshToken!.isEmpty);
}
