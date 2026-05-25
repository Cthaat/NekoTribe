import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/shared/routing/app_shell.dart';
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
        '/auth/sign-up',
        '/auth/forgot',
        '/auth/forgot-password',
        '/auth/2fa',
        '/auth/terms',
        '/meow',
        '/posts/:postId',
        '/posts/:postId/edit',
        '/tweet/:postId',
        '/tweet/search/:search',
        '/tweet/:type/:userId',
        '/tags/:tag',
        '/user/:userId/profile',
        '/user/:userId/notifications',
        '/users/:userId',
        '/users/:userId/posts',
        '/groups',
        '/groups/discover',
        '/groups/my',
        '/groups/invites',
        '/groups/posts',
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
        '/account',
        '/account/overview',
        '/account/analytics',
        '/account/data',
        '/account/profile',
        '/account/settings',
        '/account/appearance',
        '/account/billing',
        '/account/pro',
        '/account/security',
        '/account/active',
        '/account/statements',
        '/account/posts',
        '/account/likes',
        '/account/bookmarks',
        '/moderation',
        '/moderation/content',
        '/moderation/reports',
        '/moderation/users',
        '/moderation/appeals',
        '/moderation/settings',
        '/sentiment',
        '/about',
      }),
    );
  });

  test('account analysis pages are registered as first-class routes', () {
    expect(productionRoutePaths, contains('/account/overview'));
    expect(productionRoutePaths, contains('/account/analytics'));
    expect(productionRoutePaths, contains('/account/data'));
  });

  test('public read-only routes do not require login', () {
    for (final path in <String>[
      '/feed',
      '/discover',
      '/posts/1',
      '/tweet/1',
      '/tweet/search/flutter',
      '/tweet/home/1',
      '/tags/flutter',
      '/user/1/profile',
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

  test('desktop shell exposes core functional areas', () {
    expect(
      desktopAppShellPaths,
      containsAll(<String>{
        '/feed',
        '/discover',
        '/notifications',
        '/chat',
        '/me',
        '/groups',
        '/moderation',
        '/sentiment',
      }),
    );
  });
}
