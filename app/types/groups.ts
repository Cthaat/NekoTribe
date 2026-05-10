import type {
  V2GroupPostPermission,
  V2GroupPrivacy,
  V2GroupRole
} from './v2';

export type GroupPrivacy = V2GroupPrivacy;
export type GroupRole = V2GroupRole;

export interface GroupOwner {
  id: number;
  username: string;
  nickname: string;
  avatar: string;
}

export interface Group {
  id: number;
  name: string;
  description: string;
  avatar: string;
  coverImage?: string;
  privacy: GroupPrivacy;
  joinApproval: boolean;
  postPermission: V2GroupPostPermission;
  memberCount: number;
  postCount: number;
  createdAt: string;
  updatedAt: string;
  owner: GroupOwner;
  isMember?: boolean;
  isOwner?: boolean;
  isAdmin?: boolean;
  membershipRole?: GroupRole | null;
  membershipStatus?: string | null;
  category?: string;
  tags?: string[];
}

export interface GroupMember {
  id: number;
  userId: number;
  username: string;
  nickname: string;
  avatar: string;
  role: GroupRole;
  status: string;
  joinedAt: string;
  isMuted?: boolean;
  mutedUntil?: string;
  lastActiveAt?: string;
}

export interface GroupPostMedia {
  type: 'image' | 'video';
  url: string;
  thumbnail?: string;
}

export interface GroupPost {
  id: number;
  content: string;
  author: GroupOwner & {
    role: GroupRole;
  };
  media?: GroupPostMedia[];
  isPinned?: boolean;
  likeCount: number;
  commentCount: number;
  isLiked?: boolean;
  createdAt: string;
}

export interface GroupStatsData {
  totalGroups: number;
  myGroups: number;
  pendingInvites: number;
  todayPosts: number;
  activeMembers: number;
  newMembers: number;
}

export interface GroupFiltersData {
  search: string;
  privacy: string;
  category: string;
  sortBy: string;
}

export interface CreateGroupData {
  name: string;
  description: string;
  avatar: string;
  coverImage: string;
  privacy: GroupPrivacy;
  category: string;
}

export interface UpdateGroupData {
  name: string;
  description: string;
  avatar: string;
  coverImage: string;
  privacy: GroupPrivacy;
  joinApproval: boolean;
  postPermission: V2GroupPostPermission;
}

export interface GroupInviteView {
  id: number;
  group: {
    id: number;
    name: string;
    avatar: string;
    memberCount: number;
    description: string;
  };
  inviter: GroupOwner;
  message?: string;
  createdAt: string;
  expiresAt?: string;
}

export interface GroupListResult {
  groups: Group[];
  total: number;
  hasNext: boolean;
}

export interface GroupDetailResult {
  members: GroupMember[];
  posts: GroupPost[];
}
