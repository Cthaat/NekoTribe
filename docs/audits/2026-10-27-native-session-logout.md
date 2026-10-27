# 2026-10-27 当前会话原生退出检查点

Rust native 和 Go 独立服务实现 `DELETE /api/v2/auth/tokens/current`：按 Nuxt 的凭据优先级选择 refresh 或 access，验证 JWT 后直接按用户、会话、未撤销状态和当前 refresh hash/access jti 条件更新 Oracle；不通过 Nuxt 业务代理。无效或陈旧凭据不撤销记录，数据库正常时仍按既有约定清 Cookie、返回退出成功。详细合同及待执行场景见 `specifications/requirements/auth-logout.md`、`specifications/scenarios/auth-logout.json`。

Nuxt 的退出更新异常改为通用错误，避免此 handler 日志输出底层异常；合成错误及连接关闭失败测试检查了响应、Cookie 和模拟存储状态。测试中的提交后关闭失败能让会话已撤销而响应为 500，不能把故障响应等同数据库回滚。真实驱动、数据库、全局日志链的验证仍待完成。

退出和刷新竞争旧 token 时保留既有条件更新语义：退出先提交则刷新失败，刷新先提交则旧 token 的退出可能返回成功而新会话仍有效。测试包含两种确定顺序及 Go 内存替身竞争，真实 Oracle 并发和多进程联测未执行，不能把模拟结果当作生产保证。规范还记录 H3 错误外壳、非标准 Cookie/JWT 和正文长度差异。

## 验证

- Nuxt 全套测试 359 通过、2 跳过；认证兼容专项 24 通过，包含空白/失效 Cookie、跨会话凭据、表单、过期数据库记录、故障及退出先于刷新的模拟。完整类型检查通过。
- Rust 在 WSL 离线测试 69 通过、2 项真实 Oracle/Redis 连接测试忽略；离线构建和格式检查通过，不等于 Windows 原生链接或真实数据库验收。双账户 fake 验证未选账户仍可鉴权。
- Go 全套测试与 vet 通过，Windows/Linux amd64 `CGO_ENABLED=0` 构建通过；条件更新、SQL/bind、双账户、错误及两种顺序使用隔离替身/模拟 driver 验证，不证明真实 Oracle。
- 四工作区 OpenAPI 与共享需求检查通过；165 项功能、162 操作、9 份场景、18 份共享文件，`accepted: 0`、`ready: false`。新增场景是待执行行为清单，不能被记为真实端到端验收。

本轮第一次 Nuxt 全套测试出现多处 loopback `fetch failed` 和 AI `PROVIDER_UNAVAILABLE`。已在当前 Windows 实测复现：`listen(0)` 可分配 Fetch 禁用的 3659 端口，导致 `bad port`。四处测试监听改为安全高端口并在冲突时有界重试，新增监听回归测试；之后全套通过。原失败日志没有记录端口，不能逐条证明此前失败都由此造成。未修改生产网络或系统端口设置。

此切片不代表 Rust/Go 已拥有完整登录、注册、2FA、用户/内容/群组、存储、实时消息和 AI 产品；跨后端令牌和双前端切换、Windows/Linux 部署及 Docker 仍须在开发完成后集中验收。本阶段未启动 Docker、真实应用、数据库或模型，也未修改日常数据。
