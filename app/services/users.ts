import {
  v2ChangeEmail as apiChangeEmail,
  v2FollowUser as apiFollowUser,
  v2GetMe as apiGetMe,
  v2GetUserAnalytics as apiGetUserAnalytics,
  v2GetUserById as apiGetUserById,
  v2ListUserFollowers as apiListUserFollowers,
  v2ListUserFollowing as apiListUserFollowing,
  v2PatchMe as apiPatchMe,
  v2SearchUsers as apiSearchUsers,
  v2UnfollowUser as apiUnfollowUser,
  v2UpdateAvatar as apiUpdateAvatar
} from '@/api/v2/users';
import type {
  V2ApiMeta,
  V2AvatarData,
  V2ChangeEmailData,
  V2ChangeEmailPayload,
  V2FollowUserData,
  V2PagedResult,
  V2PublicUser,
  V2SelfUser,
  V2UpdateUserPayload,
  V2UserAnalytics
} from '@/types/v2';
import type {
  AvatarVM,
  ChangeEmailFormVM,
  ChangeEmailVM,
  CurrentUserVM,
  FollowUserVM,
  PublicUserVM,
  UpdateUserProfileFormVM,
  UserAnalyticsVM,
  UserRelationshipListRequestVM,
  UserRelationshipPageVM,
  UserSearchRequestVM,
  UserSearchPageVM
} from '@/types/users';
import type { PageViewModel } from '@/types/posts';
import { normalizeAvatarUrl } from '@/utils/assets';

function mapPageMeta<TDto, TViewModel>(
  result: V2PagedResult<TDto>,
  items: TViewModel[]
): PageViewModel<TViewModel> {
  const meta: V2ApiMeta | null = result.meta;
  return {
    items,
    total: meta?.total ?? items.length,
    page: meta?.page ?? 1,
    pageSize: meta?.page_size ?? items.length,
    hasNext: meta?.has_next ?? false
  };
}

export function mapPublicUser(dto: V2PublicUser): PublicUserVM {
  return {
    id: dto.user_id,
    username: dto.username,
    name: dto.display_name,
    avatarUrl: normalizeAvatarUrl(dto.avatar_url),
    bio: dto.bio,
    location: dto.location,
    website: dto.website,
    verified: dto.is_verified === 1,
    followersCount: dto.followers_count,
    followingCount: dto.following_count,
    postsCount: dto.posts_count,
    likesCount: dto.likes_count,
    relationship: {
      isSelf: dto.relationship.is_self,
      isFollowing: dto.relationship.is_following,
      isBlocked: dto.relationship.is_blocked,
      isBlocking: dto.relationship.is_blocking,
      relation: dto.relationship.relation
    }
  };
}

export function mapCurrentUser(dto: V2SelfUser): CurrentUserVM {
  return {
    ...mapPublicUser(dto),
    email: dto.email,
    phone: dto.phone,
    birthDate: dto.birth_date,
    emailVerifiedAt: dto.email_verified_at,
    active: dto.is_active === 1,
    status: dto.status,
    createdAt: dto.created_at,
    updatedAt: dto.updated_at
  };
}

function mapAnalytics(dto: V2UserAnalytics): UserAnalyticsVM {
  return {
    userId: dto.user_id,
    totalPosts: dto.total_posts,
    postsThisWeek: dto.posts_this_week,
    postsThisMonth: dto.posts_this_month,
    totalLikesReceived: dto.total_likes_received,
    avgLikesPerPost: dto.avg_likes_per_post,
    totalLikesGiven: dto.total_likes_given,
    totalCommentsMade: dto.total_comments_made,
    engagementScore: dto.engagement_score
  };
}

function mapFollowResult(dto: V2FollowUserData): FollowUserVM {
  return {
    targetUserId: dto.target_user_id,
    relationship: dto.relationship,
    followersCount: dto.followers_count
  };
}

function mapAvatar(dto: V2AvatarData): AvatarVM {
  return {
    avatarUrl: normalizeAvatarUrl(dto.avatar_url),
    avatarMediaId: dto.avatar_media_id
  };
}

function mapChangeEmailForm(
  form: ChangeEmailFormVM
): V2ChangeEmailPayload {
  return {
    new_email: form.newEmail,
    verification_id: form.verificationId,
    code: form.code
  };
}

function mapChangeEmail(dto: V2ChangeEmailData): ChangeEmailVM {
  return {
    email: dto.email,
    emailVerifiedAt: dto.email_verified_at
  };
}

function mapUpdateProfileForm(
  form: UpdateUserProfileFormVM
): V2UpdateUserPayload {
  return {
    display_name: form.displayName,
    bio: form.bio,
    location: form.location,
    website: form.website,
    birth_date: form.birthDate,
    phone: form.phone
  };
}

export async function v2GetMe(): Promise<CurrentUserVM> {
  return mapCurrentUser(await apiGetMe());
}

export async function v2PatchMe(
  form: UpdateUserProfileFormVM
): Promise<CurrentUserVM> {
  return mapCurrentUser(await apiPatchMe(mapUpdateProfileForm(form)));
}

export async function v2ChangeEmail(
  form: ChangeEmailFormVM
): Promise<ChangeEmailVM> {
  return mapChangeEmail(await apiChangeEmail(mapChangeEmailForm(form)));
}

export async function v2UpdateAvatar(
  formData: FormData
): Promise<AvatarVM> {
  return mapAvatar(await apiUpdateAvatar(formData));
}

export async function v2SearchUsers(
  query: UserSearchRequestVM
): Promise<UserSearchPageVM> {
  const result = await apiSearchUsers({
    q: query.q,
    verified: query.verified,
    sort: query.sort,
    page: query.page,
    page_size: query.pageSize
  });
  return mapPageMeta(result, result.items.map(mapPublicUser));
}

export async function v2GetUserById(
  userId: number
): Promise<PublicUserVM> {
  return mapPublicUser(await apiGetUserById(userId));
}

export async function v2GetUserAnalytics(
  userId: number
): Promise<UserAnalyticsVM> {
  return mapAnalytics(await apiGetUserAnalytics(userId));
}

export async function v2ListUserFollowers(
  userId: number,
  request: UserRelationshipListRequestVM = {}
): Promise<UserRelationshipPageVM> {
  const result = await apiListUserFollowers(userId, {
    page: request.page,
    page_size: request.pageSize
  });
  return mapPageMeta(
    result,
    result.items.map(mapPublicUser)
  );
}

export async function v2ListUserFollowing(
  userId: number,
  request: UserRelationshipListRequestVM = {}
): Promise<UserRelationshipPageVM> {
  const result = await apiListUserFollowing(userId, {
    page: request.page,
    page_size: request.pageSize
  });
  return mapPageMeta(
    result,
    result.items.map(mapPublicUser)
  );
}

export async function v2FollowUser(
  userId: number
): Promise<FollowUserVM> {
  return mapFollowResult(await apiFollowUser(userId));
}

export async function v2UnfollowUser(
  userId: number
): Promise<FollowUserVM> {
  return mapFollowResult(await apiUnfollowUser(userId));
}
