import type { PageViewModel } from './posts';
import type {
  V2ModerationPriority,
  V2ModerationReportReason,
  V2ModerationReportStatus,
  V2ModerationStatus,
  V2ModerationTargetType
} from './v2';

export type ModerationReportReasonVM =
  V2ModerationReportReason;
export type ModerationStatusVM = V2ModerationStatus;
export type ModerationReportStatusVM =
  V2ModerationReportStatus;
export type ModerationPriorityVM = V2ModerationPriority;
export type ModerationTargetTypeVM =
  V2ModerationTargetType;

export interface ModerationReportVM {
  id: number;
  targetType: ModerationTargetTypeVM;
  targetId: number;
  reporterName: string;
  reporterUsername: string;
  reason: ModerationReportReasonVM;
  description: string;
  evidenceUrl: string | null;
  status: ModerationReportStatusVM;
  priority: ModerationPriorityVM;
  handledByName: string;
  createdAt: string;
  updatedAt: string;
  resolvedAt: string | null;
}

export interface ModerationTweetVM {
  id: number;
  caseId: number;
  content: string;
  author: {
    id: number;
    username: string;
    nickname: string;
    avatar: string;
    isVerified?: boolean;
  };
  media?: {
    type: 'image' | 'video';
    url: string;
    thumbnail?: string;
  }[];
  reportCount: number;
  reportReasons: ModerationReportReasonVM[];
  reports: ModerationReportVM[];
  status: ModerationStatusVM;
  priority: ModerationPriorityVM;
  createdAt: string;
  reportedAt: string;
  likes: number;
  retweets: number;
  replies: number;
}

export interface ModerationStatsVM {
  pending: number;
  approved: number;
  rejected: number;
  flagged: number;
  todayProcessed: number;
  avgProcessMinutes: number;
  openReports: number;
  appealSuccessRate: number;
}

export interface ModerationContentRequestVM {
  q?: string;
  status?: string;
  reason?: string;
  dateRange?: string;
  sort?: string;
  page?: number;
  pageSize?: number;
}

export interface ModerationReportRequestVM {
  status?: string;
  reason?: string;
  targetType?: string;
  page?: number;
  pageSize?: number;
}

export interface ModerationUserRequestVM {
  q?: string;
  status?: string;
  sort?: string;
  page?: number;
  pageSize?: number;
}

export interface ModerationUserVM {
  id: number;
  username: string;
  name: string;
  avatarUrl: string;
  email: string;
  status: string;
  active: boolean;
  verified: boolean;
  followersCount: number;
  postsCount: number;
  likesCount: number;
  reportCount: number;
  activeRestriction: string | null;
  restrictionUntil: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface ModerationSettingVM {
  key: string;
  value: string;
  valueType: 'boolean' | 'number' | 'string';
  label: string;
  description: string;
  updatedAt: string;
}

export type ModerationContentPageVM =
  PageViewModel<ModerationTweetVM>;
export type ModerationReportPageVM =
  PageViewModel<ModerationReportVM>;
export type ModerationUserPageVM =
  PageViewModel<ModerationUserVM>;
