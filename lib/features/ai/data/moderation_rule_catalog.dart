import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/json_utils.dart';
import 'ai_moderation_advice_api.dart';

Future<({String title, List<String> blocks})?> readModerationRule(
  ModerationRule reference, {
  AssetBundle? bundle,
}) async {
  const sections = ['acceptance', 'accounts', 'conduct', 'termination'];
  if (reference.id < 1 || reference.id > 8) return null;
  final section = sections[(reference.id - 1) % sections.length];
  final locale = reference.id <= sections.length ? 'zh' : 'en';
  final key = 'terms.$section';
  final href = '/$locale/auth/terms#$section';
  final raw = await (bundle ?? rootBundle).loadString(
    'contracts/requirements/ai-public-terms-catalog.json',
  );
  final documents = toMap(jsonDecode(raw))['documents'];
  if (documents is! List) return null;
  for (final item in documents) {
    final row = toMap(item);
    if (row['key'] != key || row['locale'] != locale || row['href'] != href) {
      continue;
    }
    final title = row['title'];
    final content = row['blocks'];
    if (title is! String ||
        content is! List ||
        content.any((block) => block is! String)) {
      return null;
    }
    final blocks = content.cast<String>();
    // Use the same ordered UTF-8 byte framing as the server's public terms catalog.
    final framed = BytesBuilder()..add(utf8.encode('neko-ai-terms-v1\u0000'));
    for (final part in [
      '${reference.id}',
      key,
      locale,
      href,
      title,
      '${blocks.length}',
      ...blocks,
    ]) {
      final bytes = utf8.encode(part);
      framed.add(utf8.encode('${bytes.length}:'));
      framed.add(bytes);
    }
    return sha256.convert(framed.takeBytes()).toString() == reference.version
        ? (title: title, blocks: blocks)
        : null;
  }
  return null;
}
