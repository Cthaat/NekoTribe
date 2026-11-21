import 'package:flutter_test/flutter_test.dart';
import 'package:nekotribe/shared/routing/app_shell.dart';
import 'package:nekotribe/shared/routing/app_router.dart';
import 'package:nekotribe/core/utils/group_invite.dart';
import 'package:nekotribe/core/utils/group_post_link.dart';

void main() {
  test('group shares use the frontend and strip old browser parameters', () {
    const link = (groupId: 42, postId: 9, commentId: 17);
    expect(
      groupPostShareUrl(
        link,
        configuredBase: 'https://community.test/site/en/',
      ).toString(),
      'https://community.test/site/en/groups/posts?group=42&post=9&comment=17',
    );
    final web = groupPostShareUrl(
      link,
      configuredBase: '',
      browserEntry: Uri.parse('https://flutter.test/client/?old=1#/feed'),
    )!;
    expect(web.path, '/client/');
    expect(web.hasQuery, isFalse);
    expect(web.fragment, '/groups/posts?group=42&post=9&comment=17');
    expect(groupPostShareUrl(link, configuredBase: ''), isNull);
    for (final invalid in [
      'https://user:pass@site.test',
      'file:///tmp',
      'https://site.test?q=1',
      'https://site.test/#/',
    ]) {
      expect(groupPostShareUrl(link, configuredBase: invalid), isNull);
    }
  });

  test('shared group posts round-trip through internal login params', () {
    final shared = Uri.parse(
      '/groups/posts?group=42&post=9&comment=17&report=1',
    );
    final link = readGroupPostLink(shared)!;
    final login = Uri(
      path: '/auth/login',
      queryParameters: groupPostLinkQuery(link),
    );
    expect(
      groupPostLocation(readGroupPostLink(login)!),
      '/groups/posts?group=42&post=9&comment=17',
    );
    expect(isPublicRoutePath(shared.toString()), isFalse);
    for (final invalid in [
      'group=42&group=43&post=9',
      'group=042&post=9',
      'group=42&post=9007199254740992',
      'group=42%0A&post=9',
    ]) {
      expect(readGroupPostLink(Uri.parse('/groups/posts?$invalid')), isNull);
    }
  });
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
        '/groups/invite',
        '/groups/invite/:code',
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
        '/ai/knowledge',
        '/ai/writing',
        '/about',
      }),
    );
  });

  test('account analysis pages are registered as first-class routes', () {
    expect(productionRoutePaths, contains('/account/overview'));
    expect(productionRoutePaths, contains('/account/analytics'));
    expect(productionRoutePaths, contains('/account/data'));
  });

  test('invite continuation stays local and accepts a pasted share link', () {
    expect(
      parseGroupInviteInput(' https://example.test/en/groups/invite/aBc '),
      'ABC',
    );
    expect(parseGroupInviteInput(' a1b '), 'A1B');
    expect(
      parseGroupInviteInput('https://example.test/groups/invite/a%2Fb'),
      isNull,
    );
    expect(parseGroupInviteInput('https://example.test/other/ABC'), isNull);
    expect(groupInviteLocation('abc'), '/groups/invite/ABC');
    expect(groupInviteLocation('//example.test'), isNull);
    expect(groupInviteLocation('https://example.test'), isNull);
    expect(isPublicRoutePath('/groups/invite/ABC'), isFalse);
  });

  test('public and local endpoint routes do not require login', () {
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
      '/settings/endpoint',
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
      '/settings/security',
      '/settings/endpoint/private',
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
        '/ai/knowledge',
        '/ai/writing',
      }),
    );
    expect(desktopAppShellPaths, isNot(contains('/sentiment')));
  });

  test('desktop shell keeps profile entry at the bottom', () {
    expect(desktopAppShellPathOrder.last, '/me');
    expect(desktopAppShellPathOrder, <String>[
      '/feed',
      '/discover',
      '/notifications',
      '/chat',
      '/groups',
      '/moderation',
      '/ai/knowledge',
      '/ai/writing',
      '/me',
    ]);
  });
}
