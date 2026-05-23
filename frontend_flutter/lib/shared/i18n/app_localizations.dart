import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/storage_keys.dart';

class LocaleController extends StateNotifier<Locale?> {
  LocaleController() : super(null) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(StorageKeys.locale);
    if (raw == null || raw.isEmpty) return;
    final parts = raw.split('_');
    state = parts.length == 1
        ? Locale(parts[0])
        : Locale(parts[0], parts[1]);
  }

  Future<void> set(Locale? locale) async {
    state = locale;
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(StorageKeys.locale);
    } else {
      final v = locale.countryCode == null || locale.countryCode!.isEmpty
          ? locale.languageCode
          : '${locale.languageCode}_${locale.countryCode}';
      await prefs.setString(StorageKeys.locale, v);
    }
  }
}

final localeProvider =
    StateNotifierProvider<LocaleController, Locale?>((ref) => LocaleController());

class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;

  static const supported = [Locale('zh'), Locale('en')];

  static AppLocalizations of(BuildContext context) {
    final fallback = AppLocalizations(const Locale('zh'));
    return Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        fallback;
  }

  static const Map<String, Map<String, String>> _strings = {
    'zh': {
      'app.title': 'NekoTribe',
      'tab.home': '首页',
      'tab.discover': '发现',
      'tab.notifications': '通知',
      'tab.messages': '消息',
      'tab.profile': '我的',
      'auth.login': '登录',
      'auth.register': '注册',
      'auth.logout': '退出登录',
      'auth.account': '邮箱/用户名',
      'auth.password': '密码',
      'auth.confirm_password': '确认密码',
      'auth.username': '用户名',
      'auth.display_name': '昵称',
      'auth.otp': '验证码',
      'auth.send_otp': '获取验证码',
      'auth.forgot_password': '忘记密码',
      'auth.two_factor_code': '两步验证码',
      'auth.submit': '提交',
      'feed.empty': '暂时没有动态',
      'feed.loading': '加载中...',
      'feed.refresh': '下拉刷新',
      'compose.placeholder': '说点什么...',
      'compose.publish': '发布',
      'common.cancel': '取消',
      'common.confirm': '确认',
      'common.save': '保存',
      'common.edit': '编辑',
      'common.delete': '删除',
      'common.share': '分享',
      'common.like': '点赞',
      'common.comment': '评论',
      'common.bookmark': '收藏',
      'common.report': '举报',
      'common.follow': '关注',
      'common.unfollow': '取关',
      'common.search': '搜索',
      'common.settings': '设置',
      'common.theme': '主题',
      'common.language': '语言',
      'common.loading': '加载中',
      'common.error': '出错了',
      'common.retry': '重试',
      'common.network_error': '网络错误',
      'common.success': '成功',
      'profile.followers': '粉丝',
      'profile.following': '关注',
      'profile.posts': '动态',
      'profile.likes': '点赞',
      'notification.empty': '暂无通知',
      'chat.empty': '暂无对话',
      'group.discover': '发现群组',
      'group.my': '我的群组',
      'group.invites': '邀请',
      'moderation.title': '审核中心',
      'moderation.pending': '待处理',
      'moderation.approved': '已通过',
      'moderation.rejected': '已拒绝',
      'sentiment.title': '情感分析',
      'sentiment.predict': '分析',
      'endpoint.title': '服务器端点',
      'endpoint.current': '当前端点',
      'endpoint.presets': '预设端点',
      'endpoint.custom_section': '自定义端点',
      'endpoint.custom': '自定义',
      'endpoint.apply_custom': '保存自定义',
      'endpoint.reset': '恢复默认',
      'endpoint.hint': '切换端点会立即重建网络层；如果切换前后属于不同后端环境，可能需要重新登录。所有 URL 均由 assets/config/app_config.json 与 SharedPreferences 共同管理，源码中不含任何硬编码。',
    },
    'en': {
      'app.title': 'NekoTribe',
      'tab.home': 'Home',
      'tab.discover': 'Discover',
      'tab.notifications': 'Alerts',
      'tab.messages': 'Chat',
      'tab.profile': 'Profile',
      'auth.login': 'Sign in',
      'auth.register': 'Sign up',
      'auth.logout': 'Sign out',
      'auth.account': 'Email / Username',
      'auth.password': 'Password',
      'auth.confirm_password': 'Confirm password',
      'auth.username': 'Username',
      'auth.display_name': 'Display name',
      'auth.otp': 'Code',
      'auth.send_otp': 'Send code',
      'auth.forgot_password': 'Forgot?',
      'auth.two_factor_code': '2FA code',
      'auth.submit': 'Submit',
      'feed.empty': 'No posts yet',
      'feed.loading': 'Loading...',
      'feed.refresh': 'Pull to refresh',
      'compose.placeholder': 'Share something...',
      'compose.publish': 'Publish',
      'common.cancel': 'Cancel',
      'common.confirm': 'Confirm',
      'common.save': 'Save',
      'common.edit': 'Edit',
      'common.delete': 'Delete',
      'common.share': 'Share',
      'common.like': 'Like',
      'common.comment': 'Comment',
      'common.bookmark': 'Bookmark',
      'common.report': 'Report',
      'common.follow': 'Follow',
      'common.unfollow': 'Unfollow',
      'common.search': 'Search',
      'common.settings': 'Settings',
      'common.theme': 'Theme',
      'common.language': 'Language',
      'common.loading': 'Loading',
      'common.error': 'Error',
      'common.retry': 'Retry',
      'common.network_error': 'Network error',
      'common.success': 'Success',
      'profile.followers': 'Followers',
      'profile.following': 'Following',
      'profile.posts': 'Posts',
      'profile.likes': 'Likes',
      'notification.empty': 'No notifications',
      'chat.empty': 'No conversations',
      'group.discover': 'Discover',
      'group.my': 'My Groups',
      'group.invites': 'Invites',
      'moderation.title': 'Moderation',
      'moderation.pending': 'Pending',
      'moderation.approved': 'Approved',
      'moderation.rejected': 'Rejected',
      'sentiment.title': 'Sentiment',
      'sentiment.predict': 'Analyze',
      'endpoint.title': 'Server endpoint',
      'endpoint.current': 'Current endpoint',
      'endpoint.presets': 'Presets',
      'endpoint.custom_section': 'Custom endpoint',
      'endpoint.custom': 'Custom',
      'endpoint.apply_custom': 'Save custom',
      'endpoint.reset': 'Reset to default',
      'endpoint.hint': 'Switching rebuilds the network layer immediately. If the new endpoint points at a different backend, you may need to sign in again. All URLs are sourced from assets/config/app_config.json + SharedPreferences — none are hardcoded in source.',
    }
  };

  String t(String key) {
    final lang = locale.languageCode;
    final bundle = _strings[lang] ?? _strings['zh']!;
    return bundle[key] ?? key;
  }
}

class AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['zh', 'en'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale);

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}
