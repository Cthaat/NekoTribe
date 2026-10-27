# 2026-10-27 原生验证码校验检查点

Rust 原生模式和 Go 独立服务新增 `POST /api/v2/auth/otp/verification`，可从共享数据库读取并校验已有验证码哈希，按既有 Nuxt 行为更新与返回校验时间。共同需求与 16 条隔离场景见 [验证码校验规格](../../specifications/requirements/auth-otp-verification.md) 和 `parity.json` 的 `API-post_auth_otp_verification`。不需要可达的 Nuxt 后端；本切片没有实现验证码发送或注册。

Nuxt 该入口新增安全错误收口：数据库异常不把原始错误输出给客户端或认证处理日志；固定业务错误保留原状态与消息。隔离场景包含验证码错误、过期、账号/用途不匹配、参数缺失、重复校验及写入前后注入故障。测试核对写入次数、响应、无认证 Cookie 和错误脱敏；生产仓储 SQL 另以假驱动/执行器检查绑定与更新顺序。

- Nuxt 全量测试 462 通过、2 跳过，类型检查通过；Go 全量测试、vet 及 Windows/Linux amd64 构建通过。
- Rust WSL Linux 离线全量测试通过，2 项真实依赖测试跳过。
- 三端共同文件核对 30 份；功能仍为 `in-progress`，总体 `accepted:0`、`ready:false`。

这些结果不证明真实 Oracle 驱动和时区、并发行为或 SMTP 已验证。验证码发送、注册、密码重置及最终跨后端链路仍需继续开发和集中联测。本轮未启动 Docker、真实应用、数据库或邮件服务，也未读取日常业务数据。
