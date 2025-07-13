// 用户偏好设置类型定义（TypeScript）

export type ThemeMode = 'dark' | 'light' | 'system';
export type FontSize =
  | 'normal'
  | 'large'
  | 'small'
  | string;
export type LanguageCode = 'zh' | 'en' | string;
export type ProfileVisibility =
  | 'public'
  | 'followers'
  | 'private';
export type HomeTab =
  | 'timeline'
  | 'trending'
  | 'notifications'
  | string;

export interface UserPreference {
  // 1. 主题相关
  theme_mode: ThemeMode; // 主题模式
  font_size: FontSize; // 字体大小
  language: LanguageCode; // 界面语言

  // 2. 隐私和安全
  show_online_status: boolean; // 是否显示在线状态
  allow_dm_from_strangers: boolean; // 允许陌生人私信
  profile_visibility: ProfileVisibility; // 个人资料可见范围

  // 3. 通知设置
  push_notification_enabled: boolean; // 推送通知开关
  email_notification_enabled: boolean; // 邮件通知开关
  notify_like: boolean; // 点赞通知
  notify_comment: boolean; // 评论通知
  notify_follow: boolean; // 关注通知
  notify_mention: boolean; // 提及通知

  // 4. 功能开关
  auto_play_video: boolean; // 自动播放视频
  show_sensitive_content: boolean; // 展示敏感内容
  compact_mode: boolean; // 紧凑视图模式

  // 5. 个性化体验
  default_home_tab: HomeTab; // 默认首页Tab
  custom_background?: string; // 自定义背景图/色（可选）
  badge_display: boolean; // 是否显示身份徽章

  // 6. 其他可扩展变量
  last_seen_tweet_id?: number; // 上次访问首页时看到的推文ID（可选）
  last_seen_notification_id?: number; // 上次查看通知的ID（可选）
  mute_keywords?: string[]; // 屏蔽关键词列表（可选）
  blocked_users?: number[]; // 屏蔽用户ID列表（可选）

  // 7. 用户登录相关
  access_token: string; // 用户访问令牌
  refresh_token: string; // 用户刷新令牌

  // 更新时间戳等辅助字段
  updated_at?: string; // ISO 时间字符串（可选）
}
