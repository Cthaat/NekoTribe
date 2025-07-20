// 通知搜索参数类型
interface NotificationSearchPayload {
  type:
    | 'all'
    | 'like'
    | 'retweet'
    | 'comment'
    | 'follow'
    | 'mention'
    | 'system'; // 通知类型
  page?: number; // 页码，从1开始
  pageSize?: number; // 每页数量，默认20
  unreadOnly?: string; // 是否只获取未读通知
}

// 通知数据库行类型
type NotificationRow = [
  string, // NOTIFICATION_ID
  string, // USER_ID
  string, // TYPE
  string, // TITLE
  string, // MESSAGE
  string, // RELATED_TYPE
  string, // RELATED_ID
  string, // ACTOR_ID
  number, // IS_READ
  string, // PRIORITY
  string, // CREATED_AT
  string, // READ_AT
  string, // RECIPIENT_USERNAME
  string, // RECIPIENT_DISPLAY_NAME
  string, // RECIPIENT_AVATAR_URL
  string, // ACTOR_USERNAME
  string, // ACTOR_DISPLAY_NAME
  string, // ACTOR_AVATAR_URL
  number, // ACTOR_IS_VERIFIED
  string, // READ_STATUS_DESC
  string, // PRIORITY_DESC
  string, // TYPE_DESC
  string, // TIME_CATEGORY
  number, // HOURS_SINCE_CREATED
  number, // IS_RECENT
  number, // TOTAL_COUNT
  number // RN
];

// 通知结果项类型
interface NotificationItem {
  notificationId: string; // 通知ID
  userId: string; // 用户ID
  type: string; // 通知类型
  title: string; // 通知标题
  message: string; // 通知内容
  relatedType: string; // 相关类型
  relatedId: string; // 相关ID
  actorId: string; // 触发者ID
  isRead: number; // 是否已读
  priority: string; // 优先级
  createdAt: string; // 创建时间
  readAt: string; // 阅读时间
  recipientUsername: string; // 接收者用户名
  recipientDisplayName: string; // 接收者显示名
  recipientAvatarUrl: string; // 接收者头像
  actorUsername: string; // 触发者用户名
  actorDisplayName: string; // 触发者显示名
  actorAvatarUrl: string; // 触发者头像
  actorIsVerified: number; // 触发者是否认证
  readStatusDesc: string; // 读取状态描述
  priorityDesc: string; // 优先级描述
  typeDesc: string; // 类型描述
  timeCategory: string; // 时间分类
  hoursSinceCreated: number; // 创建后小时数
  isRecent: number; // 是否最近
  totalCount: number; // 总数
  rn: number; // 行号
}

// 通知获取成功响应类型
interface NotificationSuccessResponse {
  success: true;
  message: string;
  data: {
    type:
      | 'all'
      | 'like'
      | 'retweet'
      | 'comment'
      | 'follow'
      | 'mention'
      | 'system'; // 通知类型
    page: number; // 当前页码
    pageSize: number; // 每页数量
    notifications: NotificationItem[]; // 通知列表
    totalCount: number; // 总数
    unreadOnly?: boolean; // 是否只获取未读通知
    hasNext: boolean; // 是否有下一页
    hasPrev: boolean; // 是否有上一页
    totalPages: number; // 总页数
  };
  code: 200;
  timestamp: string;
}

// 通知获取失败响应类型
interface NotificationErrorResponse {
  success: false;
  message: string;
  code: number;
  timestamp: string;
}

// 通知响应联合类型
type NotificationResponse =
  | NotificationSuccessResponse
  | NotificationErrorResponse;
