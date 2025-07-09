// ========================== me.get ======================================

type GetUserInfo = [
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

interface ReturnUserInfo {
  userId: number; // 用户ID
  email: string; // 邮箱
  username: string; // 用户名
  passwordHash: string; // 密码哈希
  avatarUrl: string; // 头像地址
  displayName: string; // 显示名称
  bio: string; // 个人简介
  location: string; // 所在地
  website: string; // 个人网站
  birthDate: string; // 出生日期
  phone: string; // 手机号
  isVerified: number; // 是否认证
  isActive: number; // 是否激活
  followersCount: number; // 粉丝数
  followingCount: number; // 关注数
  tweetsCount: number; // 推文数
  likesCount: number; // 点赞数
  createdAt: string; // 创建时间
  updatedAt: string; // 更新时间
  lastLoginAt: string; // 最后登录时间
  createdBy: string; // 创建人
  updatedBy: string; // 更新人
}

interface GetUserInfoResponse extends Response {
  success: true;
  message: string;
  data: {
    userData: {
      userInfo: ReturnUserInfo;
    };
  };
  code: 200;
  timestamp: string;
}

// ========================== me.get ======================================

interface UpdateUserInfoPayload {
  displayName: string;
  bio: string;
  location: string;
  website: string;
  birthDate: string;
  phone: string;
}

interface UpdateUserInfoResponse extends Response {
  success: boolean;
  message: string;
  data: {};
  code: number;
  timestamp: string;
}

// ========================== me/avatar.post ======================================

interface SuccessUploadResponse extends Response {
  success: true;
  message: string;
  data: {
    url: string; // 上传成功后返回的头像 URL
  };
  code: number; // 状态码
  timestamp: string; // 时间戳
}
