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

// ========================== me.put ======================================

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

// ========================== me/email.put ======================================

interface ResetEmailPayload {
  resettoken: string;
  newEmail: string;
}

interface ResetEmailResponse extends Response {
  success: true;
  message: string;
  data: {
    newEmail: string;
  };
  code: 200;
  timestamp: string;
}

// ========================== [userId].get ======================================

type GetOthersInfo = [
  string, // AVATAR_URL
  string, // DISPLAY_NAME
  string, // BIO
  string, // LOCATION
  string, // WEBSITE
  string // BIRTH_DATE
];

interface ReturnOthersInfo {
  avatarUrl: string; // 头像地址
  displayName: string; // 显示名称
  bio: string; // 个人简介
  location: string; // 所在地
  website: string; // 个人网站
  birthDate: string; // 出生日期
}

interface GetOthersInfoResponse extends Response {
  success: true;
  message: string;
  data: {
    userData: {
      userInfo: ReturnOthersInfo;
    };
  };
  code: 200;
  timestamp: string;
}

// ========================== [userId]/stats.get ======================================

type GetOthersStats = [
  number, //USER_ID
  string, // USERNAME
  string, // DISPLAY_NAME
  string, // EMAIL
  string, // AVATAR_URL
  string, // BIO
  string, // LOCATION
  string, // WEBSITE
  number, // IS_VERIFIED
  number, // FOLLOWERS_COUNT
  number, // FOLLOWING_COUNT
  number, // TWEETS_COUNT
  number, // LIKES_COUNT
  string, // CREATED_AT
  string, // LAST_LOGIN_AT
  string // ACTIVITY_STATUS
];

interface ReturnOthersStats {
  userId: number; // 用户ID
  username: string; // 用户名
  displayName: string; // 显示名称
  email: string; // 邮箱
  avatarUrl: string; // 头像地址
  bio: string; // 个人简介
  location: string; // 所在地
  website: string; // 个人网站
  isVerified: number; // 是否认证
  followersCount: number; // 粉丝数
  followingCount: number; // 关注数
  tweetsCount: number; // 推文数
  likesCount: number; // 点赞数
  createdAt: string; // 创建时间
  lastLoginAt: string; // 最后登录时间
  activityStatus: string; // 活跃状态
}

interface GetOthersStatsResponse extends Response {
  success: true;
  message: string;
  data: {
    userData: {
      userInfo: ReturnOthersStats;
    };
  };
  code: 200;
  timestamp: string;
}

// ========================== search.get ======================================

interface SearchUsersPayload {
  q: string; // 搜索关键词
  page: number; // 页码
  pageSize: number; // 每页数量
}

interface ReturnUserInfo {
  username: string;
  displayName: string;
}

interface SearchUsersResponse extends Response {
  success: true;
  message: string;
  data: {
    users: ReturnUserInfo[]; // 用户信息数组
  };
  code: 200;
  timestamp: string;
}

// ========================== suggestion.get ======================================

interface SuggestionUsersPayload {
  limit: number; // 返回的推荐用户数量
}
interface ReturnSuggestionUserId {
  userId: number;
}

interface SuggestionResponse extends Response {
  success: true;
  message: string;
  data: {
    users: ReturnSuggestionUserId[]; // 推荐用户信息数组
  };
  code: 200;
  timestamp: string;
}

// ========================== search.get ======================================

// 用户搜索参数类型
interface UserSearchPayload {
  q: string; // 搜索关键词
  page?: number; // 页码
  pageSize?: number; // 每页数量
  sort?: 'popular' | 'newest' | 'oldest' | 'followers'; // 排序方式
  verified?: boolean; // 是否只搜索认证用户
}

// 用户数据库行类型
type UserSearchRow = [
  string, // USER_ID
  string, // USERNAME
  string, // DISPLAY_NAME
  string, // BIO
  string, // AVATAR_URL
  string, // COVER_URL
  number, // IS_VERIFIED
  number, // FOLLOWERS_COUNT
  number, // FOLLOWING_COUNT
  number, // TWEETS_COUNT
  string, // CREATED_AT
  string, // LAST_ACTIVE_AT
  number, // IS_PRIVATE
  string, // LOCATION
  string, // WEBSITE
  number // RN
];

// 用户搜索结果项类型
interface UserSearchItem {
  userId: string; // 用户ID
  username: string; // 用户名
  displayName: string; // 显示名
  bio: string; // 个人简介
  avatarUrl: string; // 头像URL
  coverUrl: string; // 封面URL
  isVerified: number; // 是否认证
  followersCount: number; // 粉丝数
  followingCount: number; // 关注数
  tweetsCount: number; // 推文数
  createdAt: string; // 创建时间
  lastActiveAt: string; // 最后活跃时间
  isPrivate: number; // 是否私密账户
  location: string; // 位置
  website: string; // 网站
  rn: number; // 行号
}

// 用户搜索成功响应类型
interface UserSearchSuccessResponse {
  success: true;
  message: string;
  data: {
    sort: 'popular' | 'newest' | 'oldest' | 'followers'; // 排序方式
    page: number; // 当前页码
    pageSize: number; // 每页数量
    users: UserSearchItem[]; // 用户列表
    totalCount: number; // 总数
    query: string; // 搜索关键词
    verified?: boolean; // 是否只搜索认证用户
  };
  code: 200;
  timestamp: string;
}

// 用户搜索失败响应类型
interface UserSearchErrorResponse {
  success: false;
  message: string;
  code: number;
  timestamp: string;
}

// 用户搜索响应联合类型
type UserSearchResponse = UserSearchSuccessResponse | UserSearchErrorResponse;
