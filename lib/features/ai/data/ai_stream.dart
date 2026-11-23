import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/json_utils.dart';

Future<T> generateAiData<T>(
  ApiClient client,
  String path, {
  required String method,
  Object? data,
  CancelToken? cancelToken,
  required T Function(Object?) decode,
  void Function(String)? onDelta,
}) async {
  if (onDelta == null) {
    return client.requestData<T>(
      path,
      method: method,
      data: data,
      cancelToken: cancelToken,
      decode: decode,
    );
  }
  final response = await client.raw.request<ResponseBody>(
    path,
    data: data,
    cancelToken: cancelToken,
    options: Options(
      method: method,
      responseType: ResponseType.stream,
      headers: {'Accept': 'text/event-stream'},
      followRedirects: false,
      validateStatus: (_) => true,
    ),
  );
  final body = response.data;
  if (body == null) throw const FormatException('Missing generation response');
  if (response.statusCode != 200) {
    final status = response.statusCode ?? 500;
    final raw = await utf8.decoder.bind(body.stream).join();
    final json = toMap(jsonDecode(raw));
    final payload = json['data'] is Map ? toMap(json['data']) : json;
    throw ApiException(
      statusCode: status,
      code: payload['code'] as int? ?? status * 100 + 1,
      message: payload['message'] as String? ?? 'Generation failed',
      retryAfterSeconds: int.tryParse(
        response.headers.value('retry-after') ?? '',
      ),
    );
  }
  return readAiStream(body, decode, onDelta);
}

Future<T> readAiStream<T>(
  ResponseBody response,
  T Function(Object?) decode,
  void Function(String) onDelta,
) async {
  String? event;
  String? data;
  final lines = StreamIterator(
    utf8.decoder.bind(response.stream).transform(const LineSplitter()),
  );
  try {
    while (await lines.moveNext()) {
      final line = lines.current;
      if (line.startsWith('event: ')) event = line.substring(7);
      if (line.startsWith('data: ')) data = line.substring(6);
      if (line.isNotEmpty || event == null || data == null) continue;
      final payload = toMap(jsonDecode(data));
      if (event == 'delta' && payload['text'] is String) {
        onDelta(payload['text'] as String);
      } else if (event == 'done' &&
          payload['code'] == 200 &&
          payload.containsKey('data')) {
        return decode(payload['data']);
      } else if (event == 'failed') {
        final code = payload['code'] as int? ?? 50001;
        throw ApiException(
          code: code,
          statusCode: code ~/ 100,
          message: payload['message'] as String? ?? 'Generation failed',
        );
      }
      event = null;
      data = null;
    }
    throw const FormatException('Generation stream ended before completion');
  } finally {
    unawaited(lines.cancel());
  }
}
