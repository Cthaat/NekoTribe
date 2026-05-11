import type { PageViewModel } from './posts';
import type { V2ProfileVisibility } from './v2';

export interface UserRelationshipVM {
  isSelf: boolean;
  isFollowing: boolean;
  isBlocked: boolean;
  isBlocking: boolean;
  relation: string;
}

export interface PublicUserVM {
  id: number;
  username: string;
  name: string;
  avatarUrl: string;
  bio: string;
  location: string;
  website: string;
  verified: boolean;
  followersCount: number;
  followingCount: number;
  postsCount: number;
  likesCount: number;
  relationship: UserRelationshipVM;
}

export interface CurrentUserVM extends PublicUserVM {
  email: string;
  phone: string;
  birthDate: string | null;
  emailVerifiedAt: string | null;
  active: boolean;
  status: string;
  createdAt: string;
  updatedAt: string;
}

export interface UserAnalyticsVM {
  userId: number;
  totalPosts: number;
  postsThisWeek: number;
  postsThisMonth: number;
  totalLikesReceived: number;
  avgLikesPerPost: number;
  totalLikesGiven: number;
  totalCommentsMade: number;
  engagementScore: number;
}

export interface UserDailyAnalyticsVM {
  day: string;
  postsCount: number;
  likesReceived: number;
  commentsReceived: number;
  retweetsReceived: number;
  likesGiven: number;
  commentsMade: number;
  engagementScore: number;
}

export interface FollowUserVM {
  targetUserId: number;
  relationship: string;
  followersCount: number;
}

export interface AvatarVM {
  avatarUrl: string;
  avatarMediaId: number;
}

export interface ChangeEmailFormVM {
  newEmail: string;
  verificationId: string;
  code: string;
}

export interface ChangeEmailVM {
  email: string;
  emailVerifiedAt: string;
}

export interface UpdateUserProfileFormVM {
  displayName?: string;
  bio?: string;
  location?: string;
  website?: string;
  birthDate?: string | null;
  phone?: string;
}

export interface UserSettingsVM {
  userId: number;
  twoFactorEnabled: boolean;
  loginAlerts: boolean;
  profileVisibility: string;
  showOnlineStatus: boolean;
  allowDmFromStrangers: boolean;
  pushNotificationEnabled: boolean;
  emailNotificationEnabled: boolean;
  updatedAt: string;
}

export interface UserSearchRequestVM {
  q?: string;
  verified?: boolean;
  sort?: 'popular' | 'newest' | 'oldest' | 'followers';
  page?: number;
  pageSize?: number;
}

export interface UserRelationshipListRequestVM {
  page?: number;
  pageSize?: number;
}

export interface UpdateUserSettingsFormVM {
  twoFactorEnabled?: boolean;
  loginAlerts?: boolean;
  profileVisibility?: V2ProfileVisibility;
  showOnlineStatus?: boolean;
  allowDmFromStrangers?: boolean;
  pushNotificationEnabled?: boolean;
  emailNotificationEnabled?: boolean;
}

export type UserSearchPageVM = PageViewModel<PublicUserVM>;
export type UserRelationshipPageVM =
  PageViewModel<PublicUserVM>;
