import {
  v2CreateStatementAppeal as apiCreateStatementAppeal,
  v2GetSettings as apiGetSettings,
  v2ListAccountStatements as apiListAccountStatements,
  v2PatchAccountStatement as apiPatchAccountStatement,
  v2PatchSettings as apiPatchSettings
} from '@/api/v2/users';
import {
  v2ListSessions as apiListSessions,
  v2RevokeOtherSessions as apiRevokeOtherSessions,
  v2RevokeSession
} from '@/api/v2/auth';
import type {
  V2AccountStatement,
  V2ApiMeta,
  V2PagedResult,
  V2SessionItem,
  V2StatementAppealData,
  V2StatementAppealPayload,
  V2StatementStatusData,
  V2UpdateSettingsPayload,
  V2UpdateStatementPayload,
  V2UserSettings
} from '@/types/v2';
import type { PageViewModel } from '@/types/posts';
import type {
  AccountSettingsVM,
  AccountStatementListRequestVM,
  AccountStatementPageVM,
  AccountStatementStatusVM,
  AccountStatementVM,
  RevokedSessionsVM,
  SessionPageVM,
  SessionVM,
  StatementAppealFormVM,
  StatementAppealVM,
  UpdateAccountSettingsFormVM,
  UpdateAccountStatementFormVM
} from '@/types/account';

export { v2RevokeSession };

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

function mapSettings(dto: V2UserSettings): AccountSettingsVM {
  return {
    userId: dto.user_id,
    twoFactorEnabled: !!dto.two_factor_enabled,
    loginAlerts: dto.login_alerts,
    profileVisibility: dto.profile_visibility,
    showOnlineStatus: !!dto.show_online_status,
    allowDmFromStrangers: !!dto.allow_dm_from_strangers,
    pushNotificationEnabled: !!dto.push_notification_enabled,
    emailNotificationEnabled: !!dto.email_notification_enabled,
    aiSentimentEnabled: !!dto.ai_sentiment_enabled,
    aiSentimentModelId: dto.ai_sentiment_model_id ?? null,
    aiSentimentReturnProbabilities:
      dto.ai_sentiment_return_probabilities ?? true,
    aiSentimentIncludeMetadata:
      !!dto.ai_sentiment_include_metadata,
    aiSentimentTopK: dto.ai_sentiment_top_k ?? 3,
    updatedAt: dto.updated_at
  };
}

function mapUpdateSettingsForm(
  form: UpdateAccountSettingsFormVM
): V2UpdateSettingsPayload {
  return {
    two_factor_enabled: form.twoFactorEnabled,
    login_alerts: form.loginAlerts,
    profile_visibility: form.profileVisibility,
    show_online_status: form.showOnlineStatus,
    allow_dm_from_strangers: form.allowDmFromStrangers,
    push_notification_enabled: form.pushNotificationEnabled,
    email_notification_enabled: form.emailNotificationEnabled,
    ai_sentiment_enabled: form.aiSentimentEnabled,
    ai_sentiment_model_id: form.aiSentimentModelId,
    ai_sentiment_return_probabilities:
      form.aiSentimentReturnProbabilities,
    ai_sentiment_include_metadata:
      form.aiSentimentIncludeMetadata,
    ai_sentiment_top_k: form.aiSentimentTopK
  };
}

function mapStatement(
  dto: V2AccountStatement
): AccountStatementVM {
  return {
    id: String(dto.statement_id),
    type: dto.type,
    title: dto.title,
    message: dto.message,
    policy: dto.policy_code || undefined,
    createdAt: dto.created_at,
    status: dto.status
  };
}

function mapStatementListRequest(
  request: AccountStatementListRequestVM
): {
  page?: number;
  page_size?: number;
  status?: string;
  type?: string;
} {
  return {
    page: request.page,
    page_size: request.pageSize,
    status: request.status,
    type: request.type
  };
}

function mapStatementActionForm(
  form: UpdateAccountStatementFormVM
): V2UpdateStatementPayload {
  return {
    action: form.action
  };
}

function mapStatementStatus(
  dto: V2StatementStatusData
): AccountStatementStatusVM {
  return {
    id: dto.statement_id,
    status: dto.status,
    updatedAt: dto.updated_at
  };
}

function mapAppealForm(
  form: StatementAppealFormVM
): V2StatementAppealPayload {
  return {
    appeal_message: form.appealMessage
  };
}

function mapAppeal(
  dto: V2StatementAppealData
): StatementAppealVM {
  return {
    statementId: dto.statement_id,
    status: dto.status,
    appealId: dto.appeal_id,
    appealStatus: dto.appeal_status
  };
}

function mapSession(dto: V2SessionItem): SessionVM {
  return {
    id: dto.session_id,
    deviceInfo: dto.device_info,
    ipAddress: dto.ip_address,
    lastAccessedAt: dto.last_accessed_at,
    createdAt: dto.created_at,
    current: dto.is_current
  };
}

export async function v2GetSettings(): Promise<AccountSettingsVM> {
  return mapSettings(await apiGetSettings());
}

export async function v2PatchSettings(
  form: UpdateAccountSettingsFormVM
): Promise<AccountSettingsVM> {
  return mapSettings(await apiPatchSettings(mapUpdateSettingsForm(form)));
}

export async function v2ListAccountStatements(
  request: AccountStatementListRequestVM = {}
): Promise<AccountStatementPageVM> {
  const result = await apiListAccountStatements(
    mapStatementListRequest(request)
  );
  return mapPageMeta(result, result.items.map(mapStatement));
}

export async function v2PatchAccountStatement(
  statementId: number,
  form: UpdateAccountStatementFormVM
): Promise<AccountStatementStatusVM> {
  return mapStatementStatus(
    await apiPatchAccountStatement(
      statementId,
      mapStatementActionForm(form)
    )
  );
}

export async function v2CreateStatementAppeal(
  statementId: number,
  form: StatementAppealFormVM
): Promise<StatementAppealVM> {
  return mapAppeal(
    await apiCreateStatementAppeal(statementId, mapAppealForm(form))
  );
}

export async function v2ListSessions(): Promise<SessionPageVM> {
  const result = await apiListSessions();
  return mapPageMeta(result, result.items.map(mapSession));
}

export async function v2RevokeOtherSessions(): Promise<RevokedSessionsVM> {
  const result = await apiRevokeOtherSessions();
  return {
    revokedCount: result.revoked_count
  };
}
