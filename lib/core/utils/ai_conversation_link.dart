import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:go_router/go_router.dart';

void openAiConversation(BuildContext context, {bool knowledge = false}) {
  final path = knowledge ? '/ai/knowledge' : '/ai/writing';
  if (kIsWeb) {
    context.go(path);
  } else {
    context.push<void>(path);
  }
}

String? readAiConversationLink(Uri uri) {
  final values = uri.queryParametersAll['conversation'];
  return values?.length == 1 ? validAiConversationLinkId(values!.single) : null;
}

String? validAiConversationLinkId(String value) {
  final valid =
      value.trim() == value &&
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(value);
  return valid ? value.toLowerCase() : null;
}
