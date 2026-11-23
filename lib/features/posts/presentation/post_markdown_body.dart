import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:highlight/highlight_core.dart' as hl;
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/cpp.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/yaml.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../domain/post_markdown.dart';

class PostMarkdownBody extends StatefulWidget {
  const PostMarkdownBody({super.key, required this.source, this.onOpenLink});

  final String source;
  final Future<bool> Function(Uri uri)? onOpenLink;

  @override
  State<PostMarkdownBody> createState() => _PostMarkdownBodyState();
}

class _PostMarkdownBodyState extends State<PostMarkdownBody> {
  static final _languages = {
    'bash': bash,
    'cpp': cpp,
    'dart': dart,
    'go': go,
    'java': java,
    'javascript': javascript,
    'json': json,
    'python': python,
    'rust': rust,
    'sql': sql,
    'typescript': typescript,
    'yaml': yaml,
  };
  static const _aliases = {
    'c': 'cpp',
    'c++': 'cpp',
    'golang': 'go',
    'js': 'javascript',
    'py': 'python',
    'rs': 'rust',
    'sh': 'bash',
    'shell': 'bash',
    'ts': 'typescript',
    'yml': 'yaml',
  };
  static final _highlighter = hl.Highlight()..registerLanguages(_languages);

  final _links = <Uri, TapGestureRecognizer>{};
  final _code = <(String, String), List<hl.Node>?>{};
  late List<md.Node> _nodes = parsePostMarkdown(widget.source);

  @override
  void didUpdateWidget(covariant PostMarkdownBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _clearLinks();
      _code.clear();
      _nodes = parsePostMarkdown(widget.source);
    }
  }

  @override
  void dispose() {
    _clearLinks();
    super.dispose();
  }

  void _clearLinks() {
    for (final link in _links.values) {
      link.dispose();
    }
    _links.clear();
  }

  Uri? _allowedLink(String? href) {
    if (href == null) return null;
    final uri = Uri.tryParse(href);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri;
  }

  Future<void> _openLink(Uri uri) async {
    try {
      final open = widget.onOpenLink;
      final didOpen = open == null
          ? await launchUrl(uri, mode: LaunchMode.externalApplication)
          : await open(uri);
      if (didOpen) return;
    } catch (_) {
      // Handle devices without an available browser.
    }
    if (!mounted) return;
    final message = AppLocalizations.of(context).t('post.markdown.link_failed');
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  List<TextSpan> _inline(
    Iterable<md.Node> nodes,
    TextStyle style, [
    TapGestureRecognizer? link,
  ]) => [for (final node in nodes) _inlineNode(node, style, link)];

  TextSpan _inlineNode(
    md.Node node,
    TextStyle style,
    TapGestureRecognizer? link,
  ) {
    if (node is! md.Element) {
      return TextSpan(text: node.textContent, style: style, recognizer: link);
    }
    final children = node.children ?? const <md.Node>[];
    final colors = Theme.of(context).colorScheme;
    switch (node.tag) {
      case 'img':
        return TextSpan(
          text: node.attributes['alt'] ?? '',
          style: style,
          recognizer: link,
        );
      case 'br':
        return const TextSpan(text: '\n');
      case 'a':
        final uri = _allowedLink(node.attributes['href']);
        if (uri != null) {
          final recognizer = _links.putIfAbsent(uri, () {
            return TapGestureRecognizer()
              ..onTap = () => unawaited(_openLink(uri));
          });
          return TextSpan(
            children: _inline(
              children,
              style.copyWith(
                color: colors.primary,
                decoration: TextDecoration.underline,
              ),
              recognizer,
            ),
          );
        }
        return TextSpan(children: _inline(children, style, link));
      case 'strong':
        return TextSpan(
          children: _inline(
            children,
            style.copyWith(fontWeight: FontWeight.bold),
            link,
          ),
        );
      case 'em':
        return TextSpan(
          children: _inline(
            children,
            style.copyWith(fontStyle: FontStyle.italic),
            link,
          ),
        );
      case 'del':
        return TextSpan(
          children: _inline(
            children,
            style.copyWith(decoration: TextDecoration.lineThrough),
            link,
          ),
        );
      case 'code':
        return TextSpan(
          text: node.textContent,
          style: style.copyWith(
            fontFamily: 'monospace',
            backgroundColor: colors.surfaceContainerHighest,
          ),
          recognizer: link,
        );
      default:
        return TextSpan(text: node.textContent, style: style, recognizer: link);
    }
  }

  Widget _text(Iterable<md.Node> nodes, TextStyle style) =>
      Text.rich(TextSpan(children: _inline(nodes, style)), style: style);

  List<hl.Node>? _highlight(String language, String source) {
    // Keep highlighting bounded even for long code pasted into a post.
    if (source.length > 4096 || !_languages.containsKey(language)) return null;
    return _code.putIfAbsent((language, source), () {
      try {
        return _highlighter.parse(source, language: language).nodes;
      } catch (_) {
        return null;
      }
    });
  }

  TextSpan _codeToken(hl.Node token, ColorScheme colors) {
    final color = switch (token.className) {
      'comment' => colors.onSurfaceVariant,
      'keyword' || 'literal' || 'built_in' => colors.primary,
      'string' || 'regexp' => colors.tertiary,
      'number' ||
      'symbol' ||
      'attr' ||
      'attribute' ||
      'title' => colors.secondary,
      _ => null,
    };
    return TextSpan(
      text: token.value,
      style: color == null ? null : TextStyle(color: color),
      children: token.children
          ?.map((child) => _codeToken(child, colors))
          .toList(),
    );
  }

  Widget _codeBlock(md.Element node) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final code = node.children?.whereType<md.Element>().firstOrNull;
    final source = node.textContent.replaceFirst(RegExp(r'\n$'), '');
    final declared =
        code?.attributes['class']
            ?.split(' ')
            .first
            .replaceFirst('language-', '')
            .toLowerCase() ??
        '';
    final tokens = _highlight(_aliases[declared] ?? declared, source);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text.rich(
            TextSpan(
              text: tokens == null ? source : null,
              children: tokens
                  ?.map((token) => _codeToken(token, colors))
                  .toList(),
            ),
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            softWrap: false,
          ),
        ),
      ),
    );
  }

  Widget _table(md.Element node, TextStyle style) {
    final rows = [
      for (final section
          in node.children?.whereType<md.Element>() ?? const <md.Element>[])
        ...?section.children?.whereType<md.Element>(),
    ];
    final cells = rows
        .map(
          (row) => (row.children ?? const <md.Node>[])
              .whereType<md.Element>()
              .toList(),
        )
        .where((row) => row.isNotEmpty)
        .toList();
    if (cells.isEmpty) return const SizedBox.shrink();
    final columns = cells.first.length;
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        border: TableBorder.all(color: colors.outlineVariant),
        children: [
          for (final row in cells.where((row) => row.length == columns))
            TableRow(
              children: [
                for (final cell in row)
                  Container(
                    constraints: const BoxConstraints(maxWidth: 240),
                    color: cell.tag == 'th'
                        ? colors.surfaceContainerHighest
                        : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: _text(
                      cell.children ?? const <md.Node>[],
                      cell.tag == 'th'
                          ? style.copyWith(fontWeight: FontWeight.bold)
                          : style,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _list(md.Element node, TextStyle style) {
    final ordered = node.tag == 'ol';
    final first = int.tryParse(node.attributes['start'] ?? '') ?? 1;
    final items =
        node.children?.whereType<md.Element>() ?? const <md.Element>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (index, item) in items.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ordered ? '${first + index}.' : '•', style: style),
                const SizedBox(width: 8),
                Expanded(
                  child: _blocks(item.children ?? const <md.Node>[], style),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _blocks(Iterable<md.Node> nodes, TextStyle style) {
    // Loose list items contain blocks; tight ones contain a single inline run.
    final children = <Widget>[];
    final inline = <md.Node>[];
    void flush() {
      if (inline.isEmpty) return;
      children.add(_text(inline, style));
      inline.clear();
    }

    for (final node in nodes) {
      if (node is md.Element &&
          const {
            'p',
            'h1',
            'h2',
            'h3',
            'h4',
            'h5',
            'h6',
            'blockquote',
            'ul',
            'ol',
            'pre',
            'table',
            'hr',
          }.contains(node.tag)) {
        flush();
        children.add(_block(node, style));
      } else {
        inline.add(node);
      }
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: children,
    );
  }

  Widget _block(md.Element node, TextStyle style) {
    final children = node.children ?? const <md.Node>[];
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    switch (node.tag) {
      case 'pre':
        return _codeBlock(node);
      case 'table':
        return _table(node, style);
      case 'ol':
      case 'ul':
        return _list(node, style);
      case 'hr':
        return const Divider(height: 1);
      case 'blockquote':
        return Container(
          padding: const EdgeInsetsDirectional.only(start: 12),
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(color: colors.outline, width: 3),
            ),
          ),
          child: _blocks(
            children,
            style.copyWith(color: colors.onSurfaceVariant),
          ),
        );
      default:
        final heading = switch (node.tag) {
          'h1' => theme.textTheme.headlineSmall,
          'h2' => theme.textTheme.titleLarge,
          'h3' => theme.textTheme.titleMedium,
          'h4' || 'h5' || 'h6' => theme.textTheme.titleSmall,
          _ => null,
        };
        return _text(
          children,
          heading == null
              ? style
              : heading.copyWith(fontWeight: FontWeight.bold),
        );
    }
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    child: _blocks(
      _nodes,
      Theme.of(context).textTheme.bodyMedium ?? const TextStyle(),
    ),
  );
}
