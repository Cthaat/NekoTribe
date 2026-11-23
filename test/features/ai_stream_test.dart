import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/network/api_exception.dart';
import 'package:nekotribe/features/ai/data/ai_stream.dart';

void main() {
  test('decodes early deltas and returns the committed response', () async {
    final deltas = <String>[];
    final chunks = Stream<Uint8List>.fromIterable([
      utf8.encode('event: delta\ndata: {"text":"早'),
      utf8.encode('期"}\n\nevent: done\ndata: {"code":200,"data":42}\n\n'),
    ]);
    final result = await readAiStream(
      ResponseBody(chunks, 200),
      (value) => value as int,
      deltas.add,
    );
    expect(deltas, ['早期']);
    expect(result, 42);
  });

  test(
    'reports terminal persistence conflicts to the history recovery path',
    () async {
      await expectLater(
        readAiStream(
          ResponseBody.fromString(
            'event: failed\ndata: {"code":40901,"message":"Conflict"}\n\n',
            200,
          ),
          (value) => value,
          (_) {},
        ),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'status',
            409,
          ),
        ),
      );
    },
  );
}
