# 2026-10-27 验证码创建与邮件检查点

三套后端实现邮箱 OTP 创建、密码学安全随机码、bcrypt 哈希及先提交 Oracle 再投递邮件的流程。共同规格和 12 条隔离场景见 [验证码创建](../../specifications/requirements/auth-otp-creation.md)。每套实现都用自身创建的合成验证码执行后续校验；Rust/Go 还用假的 SQL 执行器验证序列和参数绑定。

原有 `sms` 路径只写记录却返回成功，现已统一改为写入前返回 501；OpenAPI 与 Rust、Go、Flutter 的契约副本同步更新。`SMTP_*` 与 `NUXT_SMTP_*` 均可配置，Nuxt 前缀优先；SMTP 使用隐式 TLS。Rust 使用 lettre 0.11.23，Go 使用标准库 SMTP；各自通过 localhost 模拟 SMTP 的证书验证和消息投递测试，Go 还覆盖 PLAIN/LOGIN 认证。测试证书及密钥仅为公开合成夹具。SMTP 密码及错误经过脱敏检查。

- Nuxt 全量测试 464 通过、2 跳过，类型检查通过。
- Go 全量测试和 vet 通过，Windows/Linux amd64 构建通过。
- Rust WSL Linux 离线全量测试通过，2 项真实依赖测试跳过；Rust Windows 原生工具链仍未验证。
- 公共 API 契约核对覆盖四个工程；共同需求检查覆盖 32 份三端文件，功能仍为 `in-progress`，总体 `accepted:0`、`ready:false`。

本轮未启动 Docker、真实应用、数据库或外部邮件服务。真实 Oracle 时间/驱动和真实 SMTP、跨后端交叉验证及跨机器部署仍需最终隔离联测。发送频率、尝试次数、一次性消费和短信供应商未实现；生产环境不能将这些未完成能力视为已具备。SMTP 在服务器接收后断连可能造成投递结果不确定。
