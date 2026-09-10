class ApiException implements Exception {
  ApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.data,
    this.cause,
  });

  final int code;
  final String message;
  final int? statusCode;
  final dynamic data;
  final Object? cause;

  bool get isUnauthorized => statusCode == 401 || code == 40101;
  bool get isForbidden => statusCode == 403 || code == 40301;
  bool get isNotFound => statusCode == 404 || code == 40401;
  bool get isValidation => statusCode == 422 || code == 42201;
  bool get isBadRequest => statusCode == 400 || code == 40001;

  @override
  String toString() =>
      'ApiException(code: $code, statusCode: $statusCode, message: $message)';
}
