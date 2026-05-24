import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/shared/routing/app_router.dart';

void main() {
  test('production parity route paths are registered', () {
    expect(
      productionRoutePaths,
      containsAll(<String>{
        '/feed',
        '/discover',
        '/notifications',
        '/chat',
        '/me',
        '/auth/login',
        '/auth/register',
        '/auth/forgot',
        '/auth/2fa',
        '/auth/terms',
        '/posts/:postId',
        '/posts/:postId/edit',
        '/tags/:tag',
        '/users/:userId',
        '/users/:userId/posts',
        '/groups',
        '/groups/:slug',
        '/groups/:slug/manage',
        '/groups/:slug/posts/:postId',
        '/chat/conversation/:id',
        '/chat/groups/:groupId/channels/:channelId',
        '/settings',
        '/settings/appearance',
        '/settings/billing',
        '/settings/pro',
        '/settings/security',
        '/settings/sessions',
        '/settings/statements',
        '/settings/endpoint',
        '/moderation',
        '/moderation/content',
        '/moderation/reports',
        '/moderation/users',
        '/moderation/settings',
        '/sentiment',
        '/about',
      }),
    );
  });

  test('public read-only routes do not require login', () {
    for (final path in <String>[
      '/feed',
      '/discover',
      '/posts/1',
      '/tags/flutter',
      '/users/1',
      '/users/1/posts',
      '/about',
      '/auth/terms',
    ]) {
      expect(isPublicRoutePath(path), isTrue, reason: path);
    }

    for (final path in <String>[
      '/notifications',
      '/chat',
      '/me',
      '/groups',
      '/moderation',
      '/settings',
    ]) {
      expect(isPublicRoutePath(path), isFalse, reason: path);
    }
  });
}
