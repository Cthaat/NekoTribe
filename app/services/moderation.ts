import type {
  V2ApiMeta,
  V2MediaAsset,
  V2ModerationAppeal,
  V2ModerationContentItem,
  V2ModerationReport,
  V2ModerationSetting,
  V2ModerationStats,
  V2ModerationUserItem,
  V2PagedResult
} from '@/types/v2';
import type {
  ModerationContentPageVM,
  ModerationContentRequestVM,
  ModerationAppealPageVM,
  ModerationAppealVM,
  ModerationReportPageVM,
  ModerationReportRequestVM,
  ModerationReportStatusVM,
  ModerationReportVM,
  ModerationSettingVM,
  ModerationStatsVM,
  ModerationTweetVM,
  ModerationUserPageVM,
  ModerationUserRequestVM,
  ModerationUserVM
} from '@/types/moderation';
import type { PageViewModel } from '@/types/posts';
import {
  v2GetModerationSettings as apiGetModerationSettings,
  v2GetModerationStats as apiGetModerationStats,
  v2ListModerationContent as apiListModerationContent,
  v2ListModerationAppeals as apiListModerationAppeals,
  v2ListModerationReports as apiListModerationReports,
  v2ListModerationUsers as apiListModerationUsers,
  v2ModeratePost as apiModeratePost,
  v2ModerateUser as apiModerateUser,
  v2PatchModerationAppeal as apiPatchModerationAppeal,
  v2PatchModerationReport as apiPatchModerationReport,
  v2PatchModerationSettings as apiPatchModerationSettings
} from '@/api/v2/moderation';
import {
  normalizeAssetUrl,
  normalizeAvatarUrl
} from '@/utils/assets';

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

function mapMedia(media: V2MediaAsset): {
  type: 'image' | 'video';
  url: string;
  thumbnail?: string;
} {
  const type =
    media.media_type === 'video' ||
    media.mime_type.startsWith('video/')
      ? 'video'
      : 'image';
  return {
    type,
    url: normalizeAssetUrl(media.public_url),
    thumbnail: media.thumbnail_url
      ? normalizeAssetUrl(media.thumbnail_url)
      : undefined
  };
}

function mapReport(
  report: V2ModerationReport
): ModerationReportVM {
  return {
    id: report.report_id,
    targetType: report.target_type,
    targetId: report.target_id,
    reporterName:
      report.reporter?.display_name ||
      report.reporter?.username ||
      '',
    reporterUsername: report.reporter?.username || '',
    reason: report.reason,
    description: report.description,
    evidenceUrl: report.evidence_url,
    status: report.status,
    priority: report.priority,
    handledByName:
      report.handled_by?.display_name ||
      report.handled_by?.username ||
      '',
    createdAt: report.created_at,
    updatedAt: report.updated_at,
    resolvedAt: report.resolved_at
  };
}

function mapContentItem(
  item: V2ModerationContentItem
): ModerationTweetVM {
  return {
    id: item.post_id,
    caseId: item.case_id,
    content: item.content,
    author: {
      id: item.author.user_id,
      username: item.author.username,
      nickname:
        item.author.display_name || item.author.username,
      avatar: normalizeAvatarUrl(item.author.avatar_url),
      isVerified: item.author.is_verified === 1
    },
    media: item.media.map(mapMedia),
    reportCount: item.report_count,
    reportReasons: item.report_reasons,
    reports: item.reports.map(mapReport),
    status: item.status,
    priority: item.priority,
    createdAt: item.created_at,
    reportedAt: item.reported_at,
    likes: item.likes_count,
    retweets: item.retweets_count,
    replies: item.replies_count
  };
}

function mapStats(
  stats: V2ModerationStats
): ModerationStatsVM {
  return {
    pending: stats.pending,
    approved: stats.approved,
    rejected: stats.rejected,
    flagged: stats.flagged,
    todayProcessed: stats.today_processed,
    avgProcessMinutes: stats.avg_process_minutes,
    openReports: stats.open_reports,
    appealSuccessRate: stats.appeal_success_rate
  };
}

function mapUser(
  user: V2ModerationUserItem
): ModerationUserVM {
  return {
    id: user.user_id,
    username: user.username,
    name: user.display_name || user.username,
    avatarUrl: normalizeAvatarUrl(user.avatar_url),
    email: user.email,
    status: user.status,
    active: user.is_active === 1,
    verified: user.is_verified === 1,
    followersCount: user.followers_count,
    postsCount: user.posts_count,
    likesCount: user.likes_count,
    reportCount: user.report_count,
    activeRestriction: user.active_restriction,
    restrictionUntil: user.restriction_until,
    createdAt: user.created_at,
    updatedAt: user.updated_at
  };
}

function mapSetting(
  setting: V2ModerationSetting
): ModerationSettingVM {
  return {
    key: setting.key,
    value: setting.value,
    valueType: setting.value_type,
    label: setting.label,
    description: setting.description,
    updatedAt: setting.updated_at
  };
}

function mapAppeal(
  appeal: V2ModerationAppeal
): ModerationAppealVM {
  return {
    id: appeal.appeal_id,
    statementId: appeal.statement_id,
    userId: appeal.user.user_id,
    userName:
      appeal.user.display_name || appeal.user.username,
    username: appeal.user.username,
    message: appeal.appeal_message,
    status: appeal.appeal_status,
    adminResponse: appeal.admin_response,
    createdAt: appeal.created_at,
    updatedAt: appeal.updated_at
  };
}

export async function listModerationContent(
  request: ModerationContentRequestVM = {}
): Promise<ModerationContentPageVM> {
  const result = await apiListModerationContent({
    q: request.q,
    status: request.status,
    reason: request.reason,
    date_range: request.dateRange,
    sort: request.sort,
    page: request.page,
    page_size: request.pageSize
  });
  return mapPageMeta(result, result.items.map(mapContentItem));
}

export async function getModerationStats(): Promise<ModerationStatsVM> {
  return mapStats(await apiGetModerationStats());
}

export async function moderatePost(
  postId: number,
  action:
    | 'approve'
    | 'reject'
    | 'flag'
    | 'remove'
    | 'restore'
    | 'claim'
    | 'release',
  note = ''
): Promise<ModerationTweetVM> {
  return mapContentItem(
    await apiModeratePost(postId, {
      action,
      note
    })
  );
}

export async function listModerationReports(
  request: ModerationReportRequestVM = {}
): Promise<ModerationReportPageVM> {
  const result = await apiListModerationReports({
    status: request.status,
    reason: request.reason,
    target_type: request.targetType,
    page: request.page,
    page_size: request.pageSize
  });
  return mapPageMeta(result, result.items.map(mapReport));
}

export async function updateModerationReportStatus(
  reportId: number,
  status: ModerationReportStatusVM
): Promise<ModerationReportVM> {
  return mapReport(
    await apiPatchModerationReport(reportId, status)
  );
}

export async function listModerationUsers(
  request: ModerationUserRequestVM = {}
): Promise<ModerationUserPageVM> {
  const result = await apiListModerationUsers({
    q: request.q,
    status: request.status,
    sort: request.sort,
    page: request.page,
    page_size: request.pageSize
  });
  return mapPageMeta(result, result.items.map(mapUser));
}

export async function listModerationAppeals(request: {
  status?: string;
  page?: number;
  pageSize?: number;
} = {}): Promise<ModerationAppealPageVM> {
  const result = await apiListModerationAppeals({
    status: request.status,
    page: request.page,
    page_size: request.pageSize
  });
  return mapPageMeta(result, result.items.map(mapAppeal));
}

export async function updateModerationAppeal(
  appealId: number,
  status: 'approved' | 'rejected',
  adminResponse = ''
): Promise<ModerationAppealVM> {
  return mapAppeal(
    await apiPatchModerationAppeal(appealId, {
      appeal_status: status,
      admin_response: adminResponse
    })
  );
}

export async function moderateUser(
  userId: number,
  action: 'ban' | 'unban' | 'mute' | 'unmute' | 'note',
  options: {
    reason?: string;
    note?: string;
    durationHours?: number;
  } = {}
): Promise<ModerationUserVM> {
  return mapUser(
    await apiModerateUser(userId, {
      action,
      reason: options.reason,
      note: options.note,
      duration_hours: options.durationHours
    })
  );
}

export async function getModerationSettings(): Promise<
  ModerationSettingVM[]
> {
  return (await apiGetModerationSettings()).map(mapSetting);
}

export async function updateModerationSettings(
  settings: ModerationSettingVM[]
): Promise<ModerationSettingVM[]> {
  return (
    await apiPatchModerationSettings({
      settings: settings.map(setting => ({
        key: setting.key,
        value: setting.value
      }))
    })
  ).map(mapSetting);
}
