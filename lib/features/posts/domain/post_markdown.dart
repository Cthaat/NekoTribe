import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

const postMarkdownMaxBytes = 16384;
const postMarkdownExcerptCodePoints = 280;
final _summaryWhitespace = RegExp(r'\s+');

typedef PostMarkdownUpdate = ({String? body});

bool isValidPostMarkdown(String source) =>
    source.trim().isNotEmpty &&
    utf8.encode(source).length <= postMarkdownMaxBytes;

String? readPostMarkdown(Object? source) =>
    source is String && isValidPostMarkdown(source) ? source : null;

List<md.Node> parsePostMarkdown(String source) => md.Document(
  encodeHtml: false,
  extensionSet: md.ExtensionSet(
    const [md.FencedCodeBlockSyntax(), md.TableSyntax()],
    [md.InlineHtmlSyntax(), md.StrikethroughSyntax()],
  ),
).parse(source);

String postMarkdownExcerpt(String source) {
  final text = StringBuffer();
  void collect(md.Node node) {
    if (node is! md.Element) {
      text.write(node.textContent);
      return;
    }
    if (node.tag == 'img') {
      text.write(node.attributes['alt'] ?? '');
      return;
    }
    if (node.tag == 'br') text.write(' ');
    for (final child in node.children ?? const <md.Node>[]) {
      collect(child);
    }
    if (const {
      'p',
      'li',
      'blockquote',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'th',
      'td',
      'pre',
    }.contains(node.tag)) {
      text.write(' ');
    }
  }

  for (final node in parsePostMarkdown(source)) {
    collect(node);
    text.write(' ');
  }
  final summary = text.toString().replaceAll(_summaryWhitespace, ' ').trim();
  final plain = summary.isEmpty
      ? source.replaceAll(_summaryWhitespace, ' ').trim()
      : summary;
  return String.fromCharCodes(plain.runes.take(postMarkdownExcerptCodePoints));
}
