import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_pair.dart';
import 'package:nekotribe/features/auth/domain/auth_models.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              'contracts/scenarios/auth-client-response-vectors.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final bases = fixture['bases'] as Map<String, dynamic>;
  for (final raw in fixture['cases'] as List<dynamic>) {
    final vector = raw as Map<String, dynamic>;
    test('shared auth response: ${vector['id']}', () {
      final input =
          jsonDecode(jsonEncode(bases[vector['base']])) as Map<String, dynamic>;
      for (final rawChange in vector['changes'] as List<dynamic>) {
        final change = rawChange as Map<String, dynamic>;
        final path = (change['path'] as List<dynamic>).cast<String>();
        var node = input;
        for (final part in path.take(path.length - 1)) {
          node = node[part] as Map<String, dynamic>;
        }
        if (change['remove'] == true) {
          node.remove(path.last);
        } else {
          node[path.last] = change['value'];
        }
      }
      Object decode() => switch (vector['operation']) {
        'login' => parseLoginResult(input),
        'completion' => parseLoginSuccess(input),
        'refresh' => TokenPair.fromJson(input),
        _ => throw StateError('Unknown fixture operation'),
      };
      if (vector['expected'] == 'reject') {
        expect(decode, throwsFormatException);
      } else if (vector['expected'] == 'challenge') {
        expect(decode(), isA<V2TwoFactorRequired>());
      } else if (vector['operation'] == 'refresh') {
        expect((decode() as TokenPair).sessionId, 'synthetic-session');
      } else {
        expect((decode() as V2LoginSuccess).user.userId, 1);
      }
    });
  }
}
