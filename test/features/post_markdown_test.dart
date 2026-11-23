import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/features/groups/data/groups_api.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/domain/post_draft.dart';
import 'package:nekotribe/features/posts/domain/post_markdown.dart';
import 'package:nekotribe/features/posts/presentation/post_markdown_body.dart';

void main() {
  test('Markdown limit counts UTF-8 bytes and excerpts count code points', () {
    expect(isValidPostMarkdown('😀' * 4096), isTrue);
    expect(isValidPostMarkdown('😀' * 4097), isFalse);
    expect(isValidPostMarkdown(' \n '), isFalse);
    expect(
      postMarkdownExcerpt(
        '# Title\n\n[Link](https://example.com) **bold** ![alt](https://example.com/probe)',
      ),
      'Title Link bold alt',
    );
    final excerpt = postMarkdownExcerpt('# ${'😀' * 300}');
    expect(excerpt, '😀' * 280);
    expect(excerpt.runes.length, 280);
  });

  test('regular, group, draft and patch wire shapes retain Markdown', () async {
    final client = ApiClient(
      config: const AppConfig(
        apiBaseUrl: 'https://example.invalid',
        storageBaseUrl: 'https://example.invalid',
        wsBaseUrl: 'wss://example.invalid',
      ),
      tokenStore: _Tokens(),
    );
    addTearDown(client.dispose);
    final requests = <RequestOptions>[];
    const source = '  # Rich source\n\n**bold**\n';
    client.raw.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests.add(request);
          final input = request.data as Map<String, Object?>;
          final group = request.path.contains('groups');
          final response = {
            'post_id': 21,
            'content': 'Rich source bold',
            'author': {'user_id': 51},
            'viewer_state': {'can_delete': true},
            if (group) ...{'group_id': 32, 'is_announcement': false},
            if (input['markdown'] != null) 'markdown': input['markdown'],
          };
          handler.resolve(
            Response(
              requestOptions: request,
              statusCode: 200,
              data: {
                'code': 200,
                'message': request.method == 'PATCH' ? 'post updated' : 'ok',
                'data': response,
                'meta': null,
              },
            ),
          );
        },
      ),
    );
    final posts = PostsApi(client);
    final groups = GroupsApi(client);
    final regular = await posts.createPost(
      content: 'Rich source bold',
      markdown: source,
    );
    expect(regular.markdown, source);
    final group = await groups.createPost(
      groupId: 32,
      content: 'Rich source bold',
      markdown: source,
    );
    expect(group.markdown, source);
    expect(group.copyWith(likesCount: 2).markdown, source);
    expect(regular.copyWith().markdown, source);
    await posts.updatePost(postId: 21, content: 'Plain');
    await posts.updatePost(postId: 21, markdown: (body: source));
    await posts.updatePost(postId: 21, markdown: (body: null));
    expect((requests[0].data as Map)['markdown'], source);
    expect((requests[1].data as Map)['markdown'], source);
    expect((requests[2].data as Map).containsKey('markdown'), isFalse);
    expect(requests[3].data, {'markdown': source});
    expect(requests[4].data, {'markdown': null});
    final draft = V2PostDraftInput.fromJson({
      'group_id': 32,
      'content': 'Rich source bold',
      'markdown': source,
    });
    expect(draft.canPublish, isTrue);
    expect(draft.toJson()['markdown'], source);
  });

  testWidgets('allowlisted formatting keeps HTML and image alt as text', (
    tester,
  ) async {
    final opened = <Uri>[];
    const source = '''
# Heading

**bold** and *emphasis*

> quote

1. list item

| Header | Value |
| ------ | ----- |
| A      | 42    |

<script>alert(1)</script>

![avatar alt](https://example.com/tracker)

[safe](https://example.com/post)

[unsafe](javascript:alert%281%29)

[local](/private)

```dart
final myValue = 42;
```

```unknown-language
uncolored block
```
''';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 300,
              child: PostMarkdownBody(
                source: source,
                onOpenLink: (url) async {
                  opened.add(url);
                  return true;
                },
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Table), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(
      find.textContaining('<script>alert(1)</script>', findRichText: true),
      findsWidgets,
    );
    expect(find.text('avatar alt', findRichText: true), findsWidgets);
    expect(find.text('Heading', findRichText: true), findsWidgets);
    expect(find.text('quote', findRichText: true), findsWidgets);
    expect(find.text('list item', findRichText: true), findsWidgets);
    final richText = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan?.toPlainText() == 'final myValue = 42;',
      ),
    );
    final highlighted = richText.textSpan! as TextSpan;
    expect(highlighted.children, isNotEmpty);
    expect(
      highlighted.children?.any((span) => span.style?.color != null),
      isTrue,
    );
    final plainText = tester.widget<Text>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.textSpan?.toPlainText() == 'uncolored block',
      ),
    );
    expect((plainText.textSpan! as TextSpan).children, isNull);
    expect(opened, isEmpty);
    for (final label in ['unsafe', 'local', 'safe']) {
      final link = find.text(label, findRichText: true).last;
      await tester.ensureVisible(link);
      await tester.tapAt(tester.getTopLeft(link) + const Offset(3, 8));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(opened, [Uri.parse('https://example.com/post')]);
  });
}

class _Tokens extends TokenStore {
  @override
  Future<TokenPair?> read() async => null;

  @override
  Future<String> deviceFingerprint() async => 'test';
}
