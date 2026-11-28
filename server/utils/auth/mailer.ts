import nodemailer from 'nodemailer';
import type { SentMessageInfo } from 'nodemailer';
import type { EmailOptions } from '../type';

import { useRuntimeConfig } from '#imports';

function smtpConfig() {
  const runtime = useRuntimeConfig();
  return {
    host: process.env.NUXT_SMTP_HOST ?? process.env.SMTP_HOST ?? runtime.smtpHost,
    port: Number(process.env.NUXT_SMTP_PORT ?? process.env.SMTP_PORT ?? runtime.smtpPort),
    user: process.env.NUXT_SMTP_USER ?? process.env.SMTP_USER ?? runtime.smtpUser,
    pass: process.env.NUXT_SMTP_PASS ?? process.env.SMTP_PASS ?? runtime.smtpPass
  };
}

// 定义一个用于发送邮件的类
class Mailer {
  // 私有静态属性，用于存储 nodemailer 的 Transporter 实例
  private static transporter: nodemailer.Transporter;

  // 私有静态方法，用于获取或创建 nodemailer 的 Transporter 实例
  private static getTransporter(): nodemailer.Transporter {
    if (!Mailer.transporter) {
      const config = smtpConfig();
      Mailer.transporter = nodemailer.createTransport({
        host: config.host,
        port: config.port,
        secure: true,
        connectionTimeout: 15000,
        greetingTimeout: 15000,
        socketTimeout: 15000,
        auth: {
          user: config.user,
          pass: config.pass
        }
      });
    }
    return Mailer.transporter;
  }

  // 静态异步方法，用于发送邮件
  static async sendMail(
    options: EmailOptions
  ): Promise<SentMessageInfo> {
    const transporter = this.getTransporter();
    return transporter.sendMail({
      from: smtpConfig().user,
      to: options.to,
      subject: options.subject,
      text: options.text,
      html: options.html
    });
  }
}
export default Mailer;
