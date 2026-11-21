# 创建认证验证码 v3

最新输入约束见 `auth-account-input.md`：在原必填/type/channel和SMS501检查之后，register/change_email的email通道先校验规范化后的邮箱，无效时固定400且不取序列、写库或发邮件；password_reset及既有OTP校验保留旧账号兼容。这是落实现有Nuxt UI规则的有意收紧，不影响旧OTP哈希格式；下文记录此前随机源/短信修订及既有投递行为。

`POST /api/v2/auth/otp` 由 Nuxt、Rust、Go 分别提供，三者在同一 Oracle 模型中创建验证码，供任一后端的 `auth-otp-verification.md` 校验。接口公开，不受失效 access Cookie 阻挡；不创建登录会话或认证 Cookie。

按现有 v2 字符串规则验证 `account`、`type`（`register`、`password_reset`、`change_email`）；`channel` 缺省或非标量时为 `email`，字符串、数字和布尔值转换后不得额外 trim。无效值返回 400。原先 `sms` 仅创建数据库记录却返回成功、实际不发送：从本版本起三端均在写入前返回 HTTP 501 / 50101 `短信验证码暂不可用`，避免误称发送成功；这是一项有意的客户端兼容性变更，需明确显示提示。短信提供方及其真实投递后续另行实现。

email 通道生成六位十进制验证码、`otp_` 加随机 UUID，并用密码学安全随机源。有效期为生成时 UTC 时间加 300 秒；以 bcrypt 成本 10 哈希后参数化插入 `n_auth_otp_events`，使用共享 `seq_otp_event_id`。插入独立提交后，通过加密 SMTP 投递邮件；投递失败安全返回 500，已提交的 OTP 仍可能存在。成功只返回 account、verification_id、expires_at，不返回验证码或哈希。运行时间、数据库时间、随机 ID 及密码哈希不可硬编码；验证码、哈希、SMTP 凭据及原始异常不得写入响应或日志。

输入校验通过后，随机生成、Oracle 写入和 SMTP 投递前，必须先通过共享 Redis 原子预留额度。按已 trim 且 ASCII 小写的账号做 SHA-256，Redis 键不保存原账号。同一账号跨后端及三个验证码用途共享 60 秒冷却和从首次预留开始的 3600 秒内最多 5 次额度。拒绝时返回 429/42901 和整数秒 `Retry-After`，不写库、不发邮件。Redis 异常、超时、不可用或返回无效状态时安全返回 503/50301。额度预留之后如插入或投递失败，冷却仍然生效，以约束重试和不确定投递。

SMTP 接受邮件后如果连接断开或超时，返回失败也不能证明邮件未投递；重试可能产生多条验证码或多封邮件，不能承诺投递恰好一次。

三端支持 `SMTP_HOST`、`SMTP_PORT`、`SMTP_USER`、`SMTP_PASS`，兼容 `NUXT_SMTP_HOST`、`NUXT_SMTP_PORT`、`NUXT_SMTP_USER`、`NUXT_SMTP_PASS` 优先值；SMTP 使用经过证书校验的隐式 TLS，端口取配置值，无真实配置时可启动但发送请求安全失败。服务端 SMTP 授权账号同时作为发件地址，禁止明文降级；需可配置网络超时。SMTP 凭据不出现在源码、测试样例、错误或调试输出。验证结果与 Nuxt 既有邮件主题/内容保持业务兼容，不要求 MIME 字节完全相同。

旧验证码的 bcrypt 格式与已存在的记录可继续校验。验证尝试上限和使用规则见 `auth-otp-verification.md`。短信与真实环境验收仍属 AUTH-901 的剩余工作。`scenarios/auth-otp-creation.json` 为合成边界场景。部署时三套后端应连接同一 Redis 实例及逻辑数据库，真实 Oracle、SMTP、客户端联调和多机部署仍需最终验收。
