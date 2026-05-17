import type { PageViewModel } from './posts';
import type { V2ProfileVisibility } from './v2';

export interface AccountStatementVM {
  id: string;
  type: string;
  title: string;
  message: string;
  policy?: string;
  createdAt: string;
  status: string;
  appeal?: {
    id: string;
    message: string;
    createdAt: string;
    status: 'pending' | 'approved' | 'rejected';
    response?: string;
  };
}

export interface AccountStatementListRequestVM {
  page?: number;
  pageSize?: number;
  status?: string;
  type?: string;
}

export type AccountStatementActionVM =
  | 'mark_read'
  | 'mark_unread'
  | 'dismiss'
  | 'resolve';

export interface UpdateAccountStatementFormVM {
  action: AccountStatementActionVM;
}

export interface AccountStatementStatusVM {
  id: number;
  status: string;
  updatedAt: string;
}

export interface StatementAppealFormVM {
  appealMessage: string;
}

export interface StatementAppealVM {
  statementId: number;
  status: string;
  appealId: number;
  appealStatus: string;
}

export interface SessionVM {
  id: string;
  deviceInfo: string;
  ipAddress: string;
  lastAccessedAt: string;
  createdAt: string;
  current: boolean;
}

export interface RevokedSessionsVM {
  revokedCount: number;
}

export interface AccountSettingsVM {
  userId: number;
  twoFactorEnabled: boolean;
  loginAlerts: boolean;
  profileVisibility: string;
  showOnlineStatus: boolean;
  allowDmFromStrangers: boolean;
  pushNotificationEnabled: boolean;
  emailNotificationEnabled: boolean;
  aiSentimentEnabled: boolean;
  aiSentimentModelId: string | null;
  aiSentimentReturnProbabilities: boolean;
  aiSentimentIncludeMetadata: boolean;
  aiSentimentTopK: number;
  updatedAt: string;
}

export interface UpdateAccountSettingsFormVM {
  twoFactorEnabled?: boolean;
  loginAlerts?: boolean;
  profileVisibility?: V2ProfileVisibility;
  showOnlineStatus?: boolean;
  allowDmFromStrangers?: boolean;
  pushNotificationEnabled?: boolean;
  emailNotificationEnabled?: boolean;
  aiSentimentEnabled?: boolean;
  aiSentimentModelId?: string | null;
  aiSentimentReturnProbabilities?: boolean;
  aiSentimentIncludeMetadata?: boolean;
  aiSentimentTopK?: number;
}

export type AccountStatementPageVM =
  PageViewModel<AccountStatementVM>;
export type SessionPageVM = PageViewModel<SessionVM>;
