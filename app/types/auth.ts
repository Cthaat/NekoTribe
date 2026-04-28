import type {
  V2AuthOtpChannel,
  V2AuthOtpType
} from './v2';
import type { CurrentUserVM } from './users';

export interface AuthOtpFormVM {
  account: string;
  type: V2AuthOtpType;
  channel: V2AuthOtpChannel;
}

export interface AuthOtpVM {
  account: string;
  verificationId: string;
  expiresAt: string;
}

export interface AuthOtpVerificationFormVM {
  account: string;
  type: V2AuthOtpType;
  verificationId: string;
  code: string;
}

export interface AuthOtpVerificationVM {
  account: string;
  verified: boolean;
  verifiedAt: string;
}

export interface RegistrationFormVM {
  email: string;
  username: string;
  password: string;
  confirmPassword: string;
  displayName: string;
  bio?: string;
  location?: string;
  phone?: string;
  birthDate?: string;
  verificationId: string;
  agreeToTerms: boolean;
}

export interface LoginFormVM {
  account: string;
  password: string;
  rememberMe?: boolean;
}

export interface AuthSessionVM {
  sessionId: string;
  accessTokenExpiresAt: string;
  refreshTokenExpiresAt: string;
}

export interface LoginVM {
  user: CurrentUserVM;
  tokens: AuthSessionVM;
}

export interface PasswordResetFormVM {
  email: string;
  verificationId: string;
  code: string;
  newPassword: string;
}

export interface RevokedOtherSessionsVM {
  revokedCount: number;
}
