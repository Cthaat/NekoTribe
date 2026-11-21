String? validateAiConversationPage(
  Iterable<String?> ids,
  String? cursor,
  Object? next,
) {
  if (ids.length > 50) {
    throw const FormatException('Invalid AI conversation page size');
  }
  var lastId = cursor;
  for (final id in ids) {
    if (id == null ||
        id.isEmpty ||
        (lastId != null && id.compareTo(lastId) <= 0)) {
      throw const FormatException('Invalid AI conversation order');
    }
    lastId = id;
  }
  if (next == null) return null;
  if (ids.isEmpty || next is! String || next != lastId) {
    throw const FormatException('Invalid AI conversation cursor');
  }
  return next;
}
