// ========================== register.post ======================================

interface registerPayload {
  email: string; // 邮箱地址
  username: string; // 用户名（3-20位字母数字下划线）
  password: string; // 密码（8-32位，包含字母数字）
  confirmPassword: string; // 确认密码
  displayName: string; // 显示名称
  bio: string;
  location: string;
  phone: string; // 手机号（可选）
  birthDate: string; // 生日（YYYY-MM-DD格式）（可选）
  agreeToTerms: 'boolean'; // 同意服务条款
  captcha: string; // 验证码
}

interface RegisterResponse extends Response {
  success: true;
  message: string;
  data: {
    userId: number; // 用户ID
    username: string; // 用户名
    email: string; // 邮箱地址
    displayName: string; // 显示名称
    avatar: string; // 头像URL
    isVerified: boolean; // 是否已验证
    createdAt: string; // 创建时间
  };
  code: 200;
  timestamp: string;
}

type checkResultRow = [
  number // COUNT
];

type UserRow = [
  number, // USER_ID
  string, // USERNAME
  string, // EMAIL
  string, // DISPLAY_NAME
  string, // AVATAR_URL
  number, // IS_VERIFIED
  string // CREATED_AT
];

// ========================== get-verification.post ======================================

interface GetVerificationPayload {
  account: string; // 账号
}

interface GetRandomCode {
  (length?: number): number;
}

interface GetVerificationResponse extends Response {
  success: true;
  message: string;
  data: {
    account: string;
  };
  code: 200;
  timestamp: string;
}

// ========================== check-verification.post ======================================

interface CheckVerificationPayload {
  account: string; // 账号
  code: string; // 验证码
}

interface CheckVerificationResponse extends Response {
  success: true;
  message: string;
  data: {
    account: string;
  };
  code: 200;
  timestamp: string;
}

// ========================== login.post ======================================

interface LoginPayload {
  account: string; // 邮箱或用户名
  password: string; // 密码
  rememberMe: boolean; // 记住登录状态（可选）
  captcha: string; // 验证码（失败次数过多时需要）（可选）
}

type LoginUserRow = [
  number, // USER_ID
  string, // USERNAME
  string, // EMAIL
  string, // DISPLAY_NAME
  string, // AVATAR_URL
  number, // IS_VERIFIED
  string // PASSWORD_HASH
];

type LoginUserInfo = [
  number, //USER_ID
  string, // EMAIL
  string, // USERNAME
  string, // PASSWORD_HASH
  string, // AVATAR_URL
  string, // DISPLAY_NAME
  string, // BIO
  string, // LOCATION
  string, // WEBSITE
  string, // BIRTH_DATE
  string, // PHONE
  number, // IS_VERIFIED
  number, // IS_ACTIVE
  number, // FOLLOWERS_COUNT
  number, // FOLLOWING_COUNT
  number, // TWEETS_COUNT
  number, // LIKES_COUNT
  string, // CREATED_AT
  string, // UPDATED_AT
  string, // LAST_LOGIN_AT
  string, // CREATED_BY
  string // UPDATED_BY
];

interface LoginResponse extends Response {
  success: true;
  message: string;
  data: {
    user: {
      userInfo: LoginUserInfo;
    };
    token: string; // JWT令牌
    refreshToken: string; // 刷新令牌
  };
  code: 200;
  timestamp: string;
}

type sessionResultRow = [
  number // COUNT
];

// ========================== logout.get ======================================

interface LogoutResponse extends Response {
  success: true;
  message: string;
  code: 200;
  timestamp: string;
}

// ========================== refresh.get ======================================

type checkSessionResultRow = [
  number // COUNT
];

type sessionRow = [
  string, // REFRESH_TOKEN_EXPIRES_AT
  string // SESSION_ID
];

type refreshUserRow = [
  string // USERNAME
];

interface RefreshResponse extends Response {
  success: true;
  message: string;
  data: {
    accessToken: string; // 新的JWT令牌
    refreshToken: string; // 新的刷新令牌
  };
  code: 200;
  timestamp: string;
}

// ========================== reset-password.post ======================================

interface ResetPasswordPayload {
  email: string; // 邮箱地址
  resettoken: string; //邮箱验证码
  newPassword: string; // 新密码
}

interface ResetPasswordResponse extends Response {
  success: true;
  message: string;
  code: 200;
  timestamp: string;
}
