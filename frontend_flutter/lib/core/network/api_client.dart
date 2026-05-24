import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../auth/token_store.dart';
import '../config/app_config.dart';
import '../constants/api_paths.dart';
import 'api_exception.dart';
import 'api_response.dart';

typedef LogoutCallback = Future<void> Function();

class ApiClient {
  ApiClient({
    required this.config,
    required this.tokenStore,
    this.onLogout,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
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
  final _uuid = const Uuid();

  Future<void>? _refreshFuture;

  Dio get raw => _dio;

  Future<ApiResponse<T>> request<T>(
    String path, {
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    T Function(dynamic data)? decode,
    bool sendAuth = true,
  }) async {
    final options = Options(method: method, headers: headers);
    final response = await _dio.request<dynamic>(
      path,
      data: data,
      queryParameters: _sanitizeQuery(query),
      options: options,
    );
    return _processResponse<T>(
      path: path,
      method: method,
      data: data,
      query: query,
      headers: headers,
      response: response,
      decode: decode,
      sendAuth: sendAuth,
    );
  }

  Future<T> requestData<T>(
    String path, {
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
    T Function(dynamic data)? decode,
    bool sendAuth = true,
  }) async {
    final res = await request<T>(
      path,
      method: method,
      data: data,
      query: query,
      headers: headers,
      decode: decode,
      sendAuth: sendAuth,
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
  }) async {
    final res = await request<dynamic>(
      path,
      method: method,
      data: data,
      query: query,
      headers: headers,
      sendAuth: sendAuth,
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

    // 401 自动刷新逻辑：通过 interceptor 实现，这里只处理统一响应
    if (body is Map<String, dynamic>) {
      final envelope = _v2Envelope(body);
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

  Interceptor _buildInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) async {
        // 标准头
        options.headers['x-request-id'] = _uuid.v4();
        options.headers['x-client-platform'] = _platformTag();
        try {
          options.headers['x-device-fingerprint'] = await tokenStore
              .deviceFingerprint();
        } catch (_) {}
        options.headers['x-device-info'] = _deviceInfo();

        final shouldSendAuth =
            !ApiPaths.isAuthEntryPath(options.path) ||
            ApiPaths.isRefreshPath(options.path);
        // refresh path 也需要 access token；登录入口不需要

        if (shouldSendAuth) {
          final pair = await tokenStore.read();
          if (pair != null && pair.accessToken.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer ${pair.accessToken}';
          }
        }
        if (!options.headers.containsKey('Accept')) {
          options.headers['Accept'] = 'application/json';
        }
        handler.next(options);
      },
      onResponse: (response, handler) async {
        final path = response.requestOptions.path;
        final status = response.statusCode ?? 0;
        final isAuthEntry = ApiPaths.isAuthEntryPath(path);
        final isRefresh = ApiPaths.isRefreshPath(path);

        if (status == 401 && !isAuthEntry && !isRefresh) {
          try {
            await _refreshToken();
            // 重试
            final retry = await _dio.fetch<dynamic>(
              response.requestOptions..headers.remove('Authorization'),
            );
            handler.resolve(retry);
            return;
          } catch (e) {
            await tokenStore.clear();
            await onLogout?.call();
            // 继续返回原响应，调用方会得到 401
          }
        }
        handler.next(response);
      },
      onError: (DioException err, handler) async {
        final path = err.requestOptions.path;
        final status = err.response?.statusCode ?? 0;
        final isAuthEntry = ApiPaths.isAuthEntryPath(path);
        final isRefresh = ApiPaths.isRefreshPath(path);

        if (status == 401 && !isAuthEntry && !isRefresh) {
          try {
            await _refreshToken();
            final retry = await _dio.fetch<dynamic>(
              err.requestOptions..headers.remove('Authorization'),
            );
            handler.resolve(retry);
            return;
          } catch (_) {
            await tokenStore.clear();
            await onLogout?.call();
          }
        }
        handler.next(err);
      },
    );
  }

  Future<void> _refreshToken() {
    final existing = _refreshFuture;
    if (existing != null) return existing;
    late final Future<void> refresh;
    refresh = _performRefreshToken().whenComplete(() {
      if (identical(_refreshFuture, refresh)) {
        _refreshFuture = null;
      }
    });
    _refreshFuture = refresh;
    return refresh;
  }

  Future<void> _performRefreshToken() async {
    final pair = await tokenStore.read();
    if (pair == null) {
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
        headers: {'Cookie': 'refresh_token=${pair.refreshToken}'},
      ),
    );
    final body = response.data;
    if (body is Map<String, dynamic> && body['code'] == 200) {
      final data = body['data'] as Map<String, dynamic>?;
      if (data != null) {
        final cookies = _authCookiesFromResponse(response);
        final accessToken =
            cookies.accessToken ??
            data['access_token'] as String? ??
            pair.accessToken;
        final refreshToken =
            cookies.refreshToken ??
            data['refresh_token'] as String? ??
            pair.refreshToken;
        final accessExpStr = data['access_token_expires_at'] as String?;
        final refreshExpStr = data['refresh_token_expires_at'] as String?;
        final updated = TokenPair(
          accessToken: accessToken,
          refreshToken: refreshToken,
          sessionId: (data['session_id'] as String?) ?? pair.sessionId,
          accessTokenExpiresAt: accessExpStr == null
              ? pair.accessTokenExpiresAt
              : DateTime.tryParse(accessExpStr),
          refreshTokenExpiresAt: refreshExpStr == null
              ? pair.refreshTokenExpiresAt
              : DateTime.tryParse(refreshExpStr),
        );
        await tokenStore.write(updated);
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
    final tokens = normalized['tokens'];
    if (tokens is Map) {
      final tokenMap = Map<String, dynamic>.from(tokens);
      _putCookieTokens(tokenMap, cookies);
      normalized['tokens'] = tokenMap;
    }
    return normalized;
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
