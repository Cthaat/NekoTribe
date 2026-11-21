import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/core/auth/token_store.dart';
import 'package:nekotribe/core/config/app_config.dart';
import 'package:nekotribe/core/network/api_client.dart';
import 'package:nekotribe/core/network/api_response.dart';
import 'package:nekotribe/features/posts/data/posts_api.dart';
import 'package:nekotribe/features/posts/presentation/post_likers_screen.dart';
import 'package:nekotribe/features/users/domain/user_models.dart';
import 'package:nekotribe/shared/providers/providers.dart';

void main() {
  testWidgets(
    'likes paginate and in-flight data is discarded on backend switch',
    (tester) async {
      final tokens = TokenStore();
      final api = _Posts(tokens);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tokenStoreProvider.overrideWithValue(tokens),
            postsApiProvider.overrideWithValue(api),
          ],
          child: const MaterialApp(home: PostLikersScreen(postId: 42)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('First liker'), findsOneWidget);
      await tester.tap(find.text('下一页'));
      await tester.pump();
      expect(api.pages, [(42, 1), (42, 2)]);
      await tokens.switchEndpoint(() {});
      expect(api.pendingToken!.isCancelled, isTrue);
      api.pending.complete(PagedResult(items: [_liker('Stale liker')]));
      await tester.pumpAndSettle();
      expect(find.text('Stale liker'), findsNothing);
      expect(find.text('First liker'), findsNothing);
      expect(find.text('会话已变化，请返回帖子重新打开名单'), findsOneWidget);
    },
  );
}

V2PublicUser _liker(String name) => V2PublicUser.fromJson({
  'user_id': 9,
  'username': 'liker',
  'display_name': name,
});

class _Posts extends PostsApi {
  _Posts(TokenStore tokens)
    : super(
        ApiClient(
          tokenStore: tokens,
          config: AppConfig.fromOrigin('https://neko.example'),
        ),
      );

  final pages = <(int, int)>[];
  final pending = Completer<PagedResult<V2PublicUser>>();
  CancelToken? pendingToken;

  @override
  Future<PagedResult<V2PublicUser>> postLikers(
    int postId, {
    required int page,
    required CancelToken cancelToken,
  }) async {
    pages.add((postId, page));
    if (page == 1) {
      return PagedResult(
        items: [_liker('First liker')],
        meta: const ApiMeta(hasNext: true),
      );
    }
    pendingToken = cancelToken;
    return pending.future;
  }
}
