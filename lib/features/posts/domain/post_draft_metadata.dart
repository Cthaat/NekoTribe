import 'dart:convert';

import 'post_models.dart';

String discussionSummaryDraft(V2Post post, Iterable<V2Comment> comments) =>
    discussionTextDraft(
      postId: post.postId,
      visibility: post.visibility,
      content: post.content,
      comments: comments.map(
        (comment) => (postId: comment.postId, content: comment.content),
      ),
    );

String discussionTextDraft({
  required int postId,
  required String visibility,
  required String content,
  required Iterable<({int postId, String content})> comments,
}) {
  final body = content.trim();
  if (visibility != 'public' || body.isEmpty) return '';
  var bytes = utf8.encode(body).length;
  if (bytes > 16384) return '';
  final parts = [body];
  for (final comment in comments) {
    if (parts.length > 20) break;
    final text = comment.content.trim();
    if (comment.postId != postId || text.isEmpty) continue;
    final size = 2 + utf8.encode(text).length;
    if (bytes + size > 16384) break;
    parts.add(text);
    bytes += size;
  }
  return parts.join('\n\n');
}

const maxDraftTags = 8;

List<String> draftTagNames({
  required String content,
  required String tags,
  Iterable<String> imageTags = const [],
}) {
  return _uniqueTags([
    ..._extractHashTags(content),
    ..._splitManualTags(tags),
    ...imageTags,
  ]).take(maxDraftTags).toList(growable: false);
}

List<String> _extractHashTags(String value) {
  return RegExp(r'#([\p{L}\p{N}_]+)', unicode: true)
      .allMatches(value)
      .map((match) => _normalizeTag(match.group(1) ?? ''))
      .where((tag) => tag.isNotEmpty)
      .toList(growable: false);
}

List<String> _splitManualTags(String value) {
  return value
      .split(RegExp(r'[\s,，]+'))
      .map(_normalizeTag)
      .where((tag) => tag.isNotEmpty)
      .toList(growable: false);
}

List<String> _uniqueTags(Iterable<String> tags) {
  final seen = <String>{};
  final result = <String>[];
  for (final tag in tags) {
    if (seen.add(tag.toLowerCase())) result.add(tag);
  }
  return result;
}

String _normalizeTag(String value) {
  final normalized = value
      .trim()
      .replaceFirst(RegExp(r'^#+'), '')
      .toLowerCase();
  if (normalized.length <= 32) return normalized;
  return normalized.substring(0, 32);
}
