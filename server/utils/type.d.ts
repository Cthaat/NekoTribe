// ========================= mailer ===========================
import type { Transporter, SentMessageInfo } from 'nodemailer';

// 导出 EmailOptions 接口
export interface EmailOptions {
  to: string;
  subject: string;
  text?: string;
  html?: string;
}

export declare class Mailer {
  // nodemailer 的 Transporter 实例
  protected static transporter: Transporter;

  // 获取或创建 Transporter 实例
  protected static getTransporter(): Transporter;

  // 发送邮件
  static sendMail(options: EmailOptions): Promise<SentMessageInfo>;
}
