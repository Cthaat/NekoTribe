# 2026-10-27 原生令牌刷新检查点

本轮以现有 Nuxt 会话刷新为基准，推进 Rust native 和 Go 独立服务的 `PATCH /api/v2/auth/tokens/current`。两者使用各自 JWT 与 Oracle 会话仓储，不通过 Nuxt 业务进程；现有会话的 refresh hash、所属用户和 session、撤销与过期条件共同限制更新。刷新成功后更新 access jti 和 refresh hash，使旧凭据无法再次匹配。功能要求与待验收场景见 `specifications/requirements/auth-refresh.md` 和 `specifications/scenarios/auth-refresh.json`。

这份检查点更新此前会话撤销记录中“Rust/Go native 尚无刷新”的当时状态；不表示两套后端已有完整登录、退出、2FA、业务接口或可部署成品。Rust 缺省 `compat`，只有显式 `native` 才使用原生接口；Go 和 Rust 的部署、数据库、密钥及 CORS 均须各自正确配置。用户可在服务端选择后端地址，但真实客户端跨端切换尚未验证。

Nuxt 刷新查询和更新处将底层存储错误转换为通用错误；隔离测试检查成功/失败响应、Cookie、JWT、原始异常不进入 handler 日志替身。连接池初始化日志也已收口为固定类别和经过白名单校验的驱动错误码。实际驱动、所有连接池调用方及全局日志链仍需检查，真实全链路敏感信息保护尚未验收。无效 Cookie 不回退有效正文，URL 编码表单同 JSON 一样是 Nuxt 既有行为。

已增强 parity 检查器：已评审功能的需求和场景必须登记到 `sharedFiles`，并维持 Rust/Go 副本的哈希核验。刷新需求和场景均登记并复制到两后端；当前验收场景是待执行的行为清单，不把隔离测试记录成真实 Oracle 验收凭据。未提供 workspace 根目录时仍不能核验其他工作区的实体副本；手动重钉需求哈希也未自动强制递增功能版本。

本轮 Nuxt 全套测试 350 通过、2 跳过；刷新/认证及连接池日志隔离测试 19 通过；typecheck 通过。一次并行运行全套时帖子测试出现 `fetch failed`，单独复测和之后的全套复测均通过；原始原因未确认，不能将其解释为已修复的确定故障。Go 单元测试和 vet 通过，Windows/Linux amd64 `CGO_ENABLED=0` 交叉构建通过。Rust 在 WSL 离线全套测试 59 通过、2 项真实 Oracle/Redis 连接测试按原设置忽略，Linux build 和格式检查通过；这不是原生 Windows 链接验证。上述数据库测试使用隔离替身或驱动模拟，不是 Oracle 联机测试。

跨端 JWT 的非标准 type、数字转换及错误外壳仍有差异；原生配置拒绝 refresh TTL 小于或等于 access TTL，Nuxt 尚无相同预检。Flutter 的通用客户端可解析 Nuxt 嵌套或原生顶层业务错误，但客户端真实联测尚未完成。连接或响应失败后的提交状态可能未知，Go 的连接关闭通常是归还池连接，Rust 已开始的阻塞数据库操作不会因 HTTP 取消而自动中止。

尚须在隔离真实 Oracle 上测试数据库并发、跨进程及跨主机时间/类型行为，验证三端签发与接收、两个前端、Windows/Linux 部署及错误恢复；旧情感分析退役和问答/写作、群运营、审核助手产品及实际可切换模型同样未完成。此阶段不启动 Docker、真实应用、数据库或模型，不改动日常业务数据。
