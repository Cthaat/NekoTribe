interface Response {
  success: true;
  message: string;
  data: {};
  code: 0;
  timestamp: string;
}

interface ErrorResponse {
  success: false;
  message: string;
  code: number;
  timestamp: string;
}

interface Auth {
  userId: number; // 用户ID
  userName: string; // 用户名
  type: string; // token类型
  iat: number; // 签发时间
  exp: number; // 过期时间
}

type StatementType =
  | 'info'
  | 'warning'
  | 'strike'
  | 'suspension';
type StatementStatus =
  | 'unread'
  | 'read'
  | 'resolved'
  | 'dismissed'
  | 'appealed';

interface StatementAppeal {
  id: string;
  message: string;
  createdAt: string;
  status: 'pending' | 'approved' | 'rejected';
  response?: string;
}

interface AccountStatement {
  id: string;
  userId: number;
  type: StatementType;
  title: string;
  message: string;
  policy?: string;
  createdAt: string;
  status: StatementStatus;
  appeal?: StatementAppeal;
}
