import nodemailer from 'nodemailer';
import type { SentMessageInfo } from 'nodemailer';
import type { EmailOptions } from '../type';

const runtimeConfig = useRuntimeConfig();

// 定义一个用于发送邮件的类
class Mailer {
  // 私有静态属性，用于存储 nodemailer 的 Transporter 实例
  private static transporter: nodemailer.Transporter;

  // 私有静态方法，用于获取或创建 nodemailer 的 Transporter 实例
  private static getTransporter(): nodemailer.Transporter {
    if (!Mailer.transporter) {
      Mailer.transporter = nodemailer.createTransport({
        host: runtimeConfig.smtpHost,
        port: Number(runtimeConfig.smtpPort),
        secure: true,
        auth: {
          user: runtimeConfig.smtpUser,
          pass: runtimeConfig.smtpPass
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
      from: runtimeConfig.smtpUser,
      to: options.to,
      subject: options.subject,
      text: options.text,
      html: options.html
    });
  }
}
export default Mailer;
