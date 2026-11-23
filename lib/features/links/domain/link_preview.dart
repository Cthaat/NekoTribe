import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

import '../../posts/domain/post_markdown.dart';

const _maxUrlBytes = 2048;
final _httpLink = RegExp(r'https?://[^\s<>"\x00-\x1f]+', caseSensitive: false);
final _authority = RegExp(r'^https?://([^/?#]+)', caseSensitive: false);
final _urlUnsafe = RegExp(r'[\s\\\x00-\x1f\x7f]');
final _htmlTag = RegExp(r'<[^<>]*>');
final _rawCode = RegExp(
  r'<(script|style|pre|code)\b[^>]*>[\s\S]*?(?:</\1\s*>|$)',
  caseSensitive: false,
);
const _trailingPunctuation = '''.,;:!?'"，。；：！？、》」』''';

bool mayHaveLinkPreview(String text) => _httpLink.hasMatch(text);

Uri? normalizePreviewUrl(String value) {
  if (value.isEmpty ||
      _urlUnsafe.hasMatch(value) ||
      utf8.encode(value).length > _maxUrlBytes) {
    return null;
  }
  final authority = _authority.firstMatch(value)?.group(1);
  if (authority == null || authority.contains('@')) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return null;
  final expectedPort = switch (uri.scheme) {
    'http' => 80,
    'https' => 443,
    _ => null,
  };
  if (expectedPort == null || uri.port != expectedPort) return null;
  final withoutFragment = uri.removeFragment();
  final target = uri.path.isEmpty
      ? withoutFragment.replace(path: '/')
      : withoutFragment;
  return utf8.encode(target.toString()).length <= _maxUrlBytes ? target : null;
}

String _trimLinkPunctuation(String target) {
  var end = target.length;
  const pairs = {')': '(', ']': '[', '}': '{'};
  final excessClosing = <String, int>{};
  while (end > 0) {
    final last = target[end - 1];
    if (_trailingPunctuation.contains(last)) {
      end--;
      continue;
    }
    final opening = pairs[last];
    if (opening == null) break;
    final excess = excessClosing.putIfAbsent(
      last,
      () => last.allMatches(target).length - opening.allMatches(target).length,
    );
    if (excess <= 0) break;
    excessClosing[last] = excess - 1;
    end--;
  }
  return target.substring(0, end);
}

Uri? firstPreviewUrl(String source, {Set<String> excludedHosts = const {}}) {
  if (!mayHaveLinkPreview(source)) return null;
  Uri? external(String candidate) {
    final url = normalizePreviewUrl(candidate);
    final host = url?.host.replaceFirst(RegExp(r'\.$'), '');
    return url != null && !excludedHosts.contains(host) ? url : null;
  }

  final List<md.Node> nodes;
  try {
    nodes = parsePostMarkdown(source);
  } on StackOverflowError {
    return null;
  }
  final pending = nodes.reversed.toList();
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (node is md.Element) {
      switch (node.tag) {
        case 'a':
          final url = external(node.attributes['href'] ?? '');
          if (url != null) return url;
        case 'img':
        case 'code':
        case 'pre':
          break;
        default:
          final children = node.children;
          if (children != null) pending.addAll(children.reversed);
      }
    } else {
      final text = node.textContent
          .replaceAll(_rawCode, ' ')
          .replaceAll(_htmlTag, ' ');
      for (final match in _httpLink.allMatches(text)) {
        final url = external(_trimLinkPunctuation(match.group(0)!));
        if (url != null) return url;
      }
    }
  }
  return null;
}

class V2LinkPreview {
  const V2LinkPreview({
    required this.url,
    required this.title,
    required this.description,
    required this.siteName,
  });

  final Uri url;
  final String title;
  final String description;
  final String siteName;

  factory V2LinkPreview.fromJson(Map<String, dynamic> data) {
    String field(String name, int maximum) {
      final value = data[name];
      if (value is! String || value.runes.length > maximum) {
        throw const FormatException('Invalid link preview metadata');
      }
      return value.trim();
    }

    final rawUrl = data['url'];
    final url = rawUrl is String ? normalizePreviewUrl(rawUrl) : null;
    if (url == null) throw const FormatException('Invalid link preview URL');
    final title = field('title', 160);
    final description = field('description', 280);
    final siteName = field('site_name', 96);
    if (title.isEmpty && description.isEmpty && siteName.isEmpty) {
      throw const FormatException('Empty link preview');
    }
    return V2LinkPreview(
      url: url,
      title: title,
      description: description,
      siteName: siteName,
    );
  }
}
