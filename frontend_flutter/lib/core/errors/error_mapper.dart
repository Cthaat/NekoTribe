import 'package:dio/dio.dart';

import '../network/api_exception.dart';

class ErrorMapper {
  ErrorMapper._();

  static ApiException toApiException(Object error) {
    if (error is ApiException) return error;
    if (error is DioException) {
      final status = error.response?.statusCode ?? 0;
      final body = error.response?.data;
      if (body is Map<String, dynamic>) {
        final envelope = _v2Envelope(body);
        final code = (envelope['code'] is num)
            ? (envelope['code'] as num).toInt()
            : status;
        final message = (envelope['message'] is String)
            ? envelope['message'] as String
            : error.message ?? 'Network error';
        return ApiException(
          code: code,
          statusCode: status,
          message: message,
          data: envelope['data'],
          cause: error,
        );
      }
      final message = _describeDio(error);
      return ApiException(
        code: status,
        statusCode: status,
        message: message,
        data: body,
        cause: error,
      );
    }
    return ApiException(code: 50001, message: error.toString(), cause: error);
  }

  static String _describeDio(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Network timeout';
      case DioExceptionType.connectionError:
        return 'Network error';
      case DioExceptionType.badCertificate:
        return 'Certificate error';
      case DioExceptionType.cancel:
        return 'Request cancelled';
      case DioExceptionType.badResponse:
        return 'Server error (${error.response?.statusCode ?? 'unknown'})';
      case DioExceptionType.unknown:
      // ignore: unreachable_switch_default
      default:
        return error.message ?? 'Unknown network error';
    }
  }

  static Map<String, dynamic> _v2Envelope(Map<String, dynamic> body) {
    if (body['code'] is num || body.containsKey('meta')) return body;
    final nested = body['data'];
    if (nested is Map<String, dynamic> &&
        (nested['code'] is num || nested.containsKey('meta'))) {
      return nested;
    }
    return body;
  }
}
