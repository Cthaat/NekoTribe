# 创建认证验证码 v2

`POST /api/v2/auth/otp` 由 Nuxt、Rust、Go 分别提供，三者在同一 Oracle 模型中创建验证码，供任一后端的 `auth-otp-verification.md` 校验。接口公开，不受失效 access Cookie 阻挡；不创建登录会话或认证 Cookie。

按现有 v2 字符串规则验证 `account`、`type`（`register`、`password_reset`、`change_email`）；`channel` 缺省或非标量时为 `email`，字符串、数字和布尔值转换后不得额外 trim。无效值返回 400。原先 `sms` 仅创建数据库记录却返回成功、实际不发送：从本版本起三端均在写入前返回 HTTP 501 / 50101 `短信验证码暂不可用`，避免误称发送成功；这是一项有意的客户端兼容性变更，需明确显示提示。短信提供方及其真实投递后续另行实现。

email 通道生成六位十进制验证码、`otp_` 加随机 UUID，并用密码学安全随机源。有效期为生成时 UTC 时间加 300 秒；以 bcrypt 成本 10 哈希后参数化插入 `n_auth_otp_events`，使用共享 `seq_otp_event_id`。插入独立提交后，通过加密 SMTP 投递邮件；投递失败安全返回 500，已提交的 OTP 仍可能存在。成功只返回 account、verification_id、expires_at，不返回验证码或哈希。运行时间、数据库时间、随机 ID 及密码哈希不可硬编码；验证码、哈希、SMTP 凭据及原始异常不得写入响应或日志。

SMTP 接受邮件后如果连接断开或超时，返回失败也不能证明邮件未投递；重试可能产生多条验证码或多封邮件，不能承诺投递恰好一次。

三端支持 `SMTP_HOST`、`SMTP_PORT`、`SMTP_USER`、`SMTP_PASS`，兼容 `NUXT_SMTP_HOST`、`NUXT_SMTP_PORT`、`NUXT_SMTP_USER`、`NUXT_SMTP_PASS` 优先值；SMTP 使用经过证书校验的隐式 TLS，端口取配置值，无真实配置时可启动但发送请求安全失败。服务端 SMTP 授权账号同时作为发件地址，禁止明文降级；需可配置网络超时。SMTP 凭据不出现在源码、测试样例、错误或调试输出。验证结果与 Nuxt 既有邮件主题/内容保持业务兼容，不要求 MIME 字节完全相同。

本变更只升级安全随机源及修正短信的假成功；旧验证码的 bcrypt 格式与已存在的记录可继续校验。发送间隔、尝试次数及 OTP 一次性消费尚未实现，仍记录为 AUTH-901；三套实现都必须最终补齐并经过共同修订。`scenarios/auth-otp-creation.json` 为合成边界场景；实际 Oracle、SMTP、跨后端读写和另一台机器运行必须在最终阶段隔离验收。
