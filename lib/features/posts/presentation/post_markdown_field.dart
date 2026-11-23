import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../shared/i18n/app_localizations.dart';
import '../domain/post_markdown.dart';

class PostMarkdownToggle extends StatelessWidget {
  const PostMarkdownToggle({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final bool selected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    key: const Key('post-markdown-toggle'),
    value: selected,
    onChanged: onChanged == null ? null : (value) => onChanged!(value ?? false),
    contentPadding: EdgeInsets.zero,
    title: Text(AppLocalizations.of(context).t('post.markdown.option')),
  );
}

class PostMarkdownField extends StatelessWidget {
  const PostMarkdownField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final length = utf8.encode(value).length;
    return TextFormField(
      key: const Key('post-markdown-field'),
      initialValue: value,
      onChanged: onChanged,
      readOnly: onChanged == null,
      minLines: 5,
      maxLines: 12,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.multiline,
      decoration: InputDecoration(
        labelText: l10n.t('post.markdown.body'),
        counterText: l10n
            .t('post.markdown.bytes')
            .replaceFirst('{used}', '$length')
            .replaceFirst('{maximum}', '$postMarkdownMaxBytes'),
        errorText: length > postMarkdownMaxBytes
            ? l10n.t('post.markdown.too_long')
            : null,
      ),
    );
  }
}
