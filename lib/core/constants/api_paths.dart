class ApiPaths {
  ApiPaths._();

  static const String health = '/api/health';

  // Auth
  static const String authOtp = '/api/v2/auth/otp';
  static const String authOtpVerification = '/api/v2/auth/otp/verification';
  static const String authRegistration = '/api/v2/auth/registration';
  static const String authTokens = '/api/v2/auth/tokens';
  static const String authTokensCurrent = '/api/v2/auth/tokens/current';
  static const String authPasswordReset = '/api/v2/auth/password-reset';
  static const String authSessions = '/api/v2/auth/sessions';
  static const String authSessionsOthers = '/api/v2/auth/sessions/others';
  static const String authTwoFactorChallenges =
      '/api/v2/auth/two-factor/challenges';

  // Users
  static const String usersMe = '/api/v2/users/me';
  static const String usersMeEmail = '/api/v2/users/me/email';
  static const String usersMeAvatar = '/api/v2/users/me/avatar';
  static const String usersMeSettings = '/api/v2/users/me/settings';
  static const String usersMeBlocks = '/api/v2/users/me/blocks';
  static const String usersMeMutes = '/api/v2/users/me/mutes';
  static const String usersMePosts = '/api/v2/users/me/posts';
  static const String usersMeLikes = '/api/v2/users/me/likes';
  static const String usersMeBookmarks = '/api/v2/users/me/bookmarks';
  static const String usersMeGroups = '/api/v2/users/me/groups';
  static const String usersMeGroupInvites = '/api/v2/users/me/group-invites';
  static const String usersMeStatements = '/api/v2/users/me/account-statements';
  static const String usersMeTwoFactorSetup =
      '/api/v2/users/me/two-factor/setup';
  static const String usersMeTwoFactorConfirm =
      '/api/v2/users/me/two-factor/confirm';
  static const String usersMeTwoFactor = '/api/v2/users/me/two-factor';
  static const String users = '/api/v2/users';
  static const String userRecommendations = '/api/v2/users/recommendations';

  // Posts
  static const String posts = '/api/v2/posts';
  static const String postsTrending = '/api/v2/posts/trending';
  static const String comments = '/api/v2/comments';
  static const String tags = '/api/v2/tags';
  static const String tagsTrending = '/api/v2/tags/trending';
  static const String reports = '/api/v2/reports';
  static const String recommendationsFeedback =
      '/api/v2/recommendations/feedback';

  // Media
  static const String media = '/api/v2/media';

  // Notifications
  static const String notifications = '/api/v2/notifications';
  static const String notificationsReadStatus =
      '/api/v2/notifications/read-status';

  // Groups
  static const String groups = '/api/v2/groups';
  static const String groupsPopular = '/api/v2/groups/popular';

  // Chat
  static const String chatGroups = '/api/v2/chat/groups';
  static const String chatDirectConversations =
      '/api/v2/chat/direct-conversations';
  static const String chatChannels = '/api/v2/chat/channels';
  static const String chatMessages = '/api/v2/chat/messages';

  // Moderation
  static const String moderationStats = '/api/v2/moderation/stats';
  static const String moderationContent = '/api/v2/moderation/content';
  static const String moderationContentBulkActions =
      '/api/v2/moderation/content/bulk-actions';
  static const String moderationReports = '/api/v2/moderation/reports';
  static const String moderationUsers = '/api/v2/moderation/users';
  static const String moderationAppeals = '/api/v2/moderation/appeals';
  static const String moderationSettings = '/api/v2/moderation/settings';

  // SentimentFlow
  static const String sentimentFlowConfig =
      '/api/v2/integrations/sentiment-flow/config';
  static const String sentimentFlowProxy =
      '/api/v2/integrations/sentiment-flow';

  static const Set<String> authEntryPaths = {
    authOtp,
    authOtpVerification,
    authRegistration,
    authTokens,
    authTwoFactorChallenges,
    authPasswordReset,
  };

  static bool isAuthEntryPath(String path) {
    final normalized = _normalize(path);
    if (authEntryPaths.contains(normalized)) {
      return true;
    }
    // /api/v2/auth/two-factor/challenges/{id}
    return RegExp(
      r'^/api/v2/auth/two-factor/challenges/[^/]+$',
    ).hasMatch(normalized);
  }

  static bool isRefreshPath(String path) {
    final normalized = _normalize(path);
    return normalized == authTokensCurrent;
  }

  static String _normalize(String path) {
    try {
      final uri = Uri.parse(path);
      final p = uri.path;
      return p.isEmpty ? path : p;
    } catch (_) {
      final idx = path.indexOf(RegExp(r'[?#]'));
      return idx >= 0 ? path.substring(0, idx) : path;
    }
  }
}
