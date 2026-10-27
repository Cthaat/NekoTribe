# 2026-10-27 原生登录开发检查点

本轮在 Nuxt 全栈基准上推进 Rust native 与 Go 独立登录：密码查询及 bcrypt 校验、账号状态、session/JWT/Cookie、个人资料、受信设备、双因素挑战创建及两个完成路由、AES-GCM 密文、TOTP、恢复码/挑战条件消费、历史设备与站内登录提醒存储。上述 Oracle 访问使用各自原生仓储，不通过 Nuxt 业务代理。完整合同为 `specifications/requirements/auth-login.md`；受影响的三个操作合并为 `AUTH-LOGIN` 工作项，原工作项 ID 保存在 `supersedes`，没有删除接口。

两个原生后端新增只读双因素表列预检，缺失时拒绝登录；当前尚不复刻 Nuxt 对迁移账本、索引、约束和序列的完整 readiness 校验。站内通知可按偏好持久化，但 Redis/WebSocket 推送和 SMTP 邮件尚未接通。默认头像可映射，配置化存储/CDN URL 与部分非标准输入、UTF-16 设备头边界仍需统一。Rust 资料日期对无时区 Oracle TIMESTAMP 按运行主机时区转换；真实 Oracle 驱动返回类型、时区及跨主机结果尚未验证。两端保留 Nuxt 既有客户端 fingerprint 信任设计及 AUTH-902 风险，不能称为强设备认证。

Nuxt 登录/挑战入口新增安全异常边界，非公开异常不将驱动/资料异常写入 handler 日志；明确业务错误重建后保留。登录提醒失败不再直接输出原始异常，self profile 读取成功后才设置 Cookie。此前 autoCommit 的 session 或通知等可能已经存在；连接关闭、网络或提交故障的结果不保证回滚。白名单式业务错误处理需要新错误消息同步更新与测试；真实驱动和所有日志链尚未验收。

公共 `auth-bcrypt.json` 有 9 个 Nuxt bcrypt 样例，包括 `$2a$`/`$2b$`、错误 hash、72 字节及截断在中文多字节内的输入；`auth-twofactor-crypto.json` 有 3 个 Node AES-GCM 样例，覆盖有效、错误 key 与篡改 tag。Go/Rust 均读取各自 contracts 副本，不使用真实密码或模型数据。双因素同挑战和跨挑战同恢复码的隔离测试使用同步点使两条请求竞争存储替身的条件消费；这不是实际 Oracle 并发证明。

Nuxt 全套测试 378 通过、2 跳过，认证和入口异常专项 43 通过，typecheck 通过。Go `test ./...`、`vet ./...` 和 Windows/Linux amd64 CGO0 构建通过；Rust WSL 离线全套 86 通过、2 个真实 Oracle/Redis 连接测试忽略，build 与 fmt 通过，并不代表 Windows 原生链接成功。OpenAPI 工作区检查覆盖162个操作且通过，共同登记覆盖163功能、12场景和22共享文件，`accepted:0`、`ready:false`。新增场景是待执行行为清单，不能用 fake 数据库代替真实验收。

尚需完成完整 readiness、通知推送和邮件、媒体地址规则、剩余注册/OTP/2FA 管理及全部其他业务、AI 产品和跨平台部署；还须集中验证真实 Oracle/Redis、跨后端 token、Web 与 Flutter。此阶段未启动 Docker、真实应用、数据库或模型，没有操作日常业务数据。
