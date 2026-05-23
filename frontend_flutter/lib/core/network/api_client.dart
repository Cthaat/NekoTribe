import 'dart:async';
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
    _dio.interceptors.add(_buildInterceptor());
  }

  final AppConfig config;
  final TokenStore tokenStore;
  final LogoutCallback? onLogout;
  final Dio _dio;
  final _uuid = const Uuid();

  Completer<void>? _refreshCompleter;

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
    final options = Options(
      method: method,
      headers: headers,
    );
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
      final code = (body['code'] is num) ? (body['code'] as num).toInt() : status;
      final message = (body['message'] is String)
          ? body['message'] as String
          : 'request failed';
      final raw = body['data'];
      final metaJson = body['meta'];
      final meta = metaJson is Map<String, dynamic>
          ? ApiMeta.fromJson(metaJson)
          : null;
      if (status >= 200 && status < 300 && code < 30000) {
        final decoded = decode == null ? raw as T : decode(raw);
        return ApiResponse<T>(
          code: code,
          message: message,
          data: decoded,
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
      return ApiResponse<T>(
        code: status,
        message: 'OK',
        data: decoded,
      );
    }

    throw ApiException(
      code: status,
      statusCode: status,
      message: 'HTTP $status',
      data: body,
    );
  }

  Interceptor _buildInterceptor() {
    return InterceptorsWrapper(
      onRequest: (options, handler) async {
        // 标准头
        options.headers['x-request-id'] = _uuid.v4();
        options.headers['x-client-platform'] = _platformTag();
        try {
          options.headers['x-device-fingerprint'] =
              await tokenStore.deviceFingerprint();
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

  Future<void> _refreshToken() async {
    if (_refreshCompleter != null) {
      return _refreshCompleter!.future;
    }
    final completer = Completer<void>();
    _refreshCompleter = completer;
    try {
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
        data: {
          'refresh_token': pair.refreshToken,
        },
      );
      final body = response.data;
      if (body is Map<String, dynamic> && body['code'] == 200) {
        final data = body['data'] as Map<String, dynamic>?;
        if (data != null) {
          final accessToken = data['access_token'] as String? ?? pair.accessToken;
          final refreshToken =
              data['refresh_token'] as String? ?? pair.refreshToken;
          final accessExpStr = data['access_token_expires_at'] as String?;
          final refreshExpStr = data['refresh_token_expires_at'] as String?;
          final updated = TokenPair(
            accessToken: accessToken,
            refreshToken: refreshToken,
            sessionId:
                (data['session_id'] as String?) ?? pair.sessionId,
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
      completer.complete();
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _refreshCompleter = null;
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
}
