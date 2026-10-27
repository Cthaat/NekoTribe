# 原生会话令牌刷新切片 v1

本切片对应公开接口 `PATCH /api/v2/auth/tokens/current`。Nuxt 是已有业务行为基准；Rust 原生模式及 Go 独立服务应访问同一 Oracle 会话表，不能通过 Nuxt 代理。它不代表登录、退出、2FA、账号状态检查或完整认证已经实现。共有验收场景见 `specifications/scenarios/auth-refresh.json`；源码与隔离测试通过不等于真实数据库或跨机器验收。

## 行为

1. 刷新入口不要求有效 access token。优先使用 `refresh_token` Cookie；该 Cookie 的原始值非空时不读取正文，否则从请求体对象的 `refresh_token` 字符串读取。Nuxt 的解析器接受 JSON 及 URL 编码表单，解析失败按无凭据处理。取得的字符串去首尾空白。非空但无效 Cookie 不回退正文；原始 Cookie 非空而去空白后为空时也不回退。在数据库连接与关闭正常的前提下，无凭据、过期、错签名或无匹配会话返回 401、业务代码 40101、消息 `未认证或 token 无效`，不发新 Cookie；连接或关闭失败可优先返回 500。
2. 合法刷新凭据使用 refresh 密钥校验，需定位原 userId 和 sessionId；保存的是原 token 的 SHA-256 哈希。原子更新必须同时限定 user_id、session_id、旧 refresh hash、未撤销及数据库 refresh 到期时间晚于数据库当前时间；恰好更新一行才视为成功。失效、他人、已撤销、已到期及旧 hash 均不得更新会话。数据库、连接和响应均正常时，单个旧 token 并发使用只能有一个成功；这个断言最终须由真实 Oracle 并发测试验证。
3. 成功时保持 sessionId 和用户身份，生成新的 access jti 和具有随机 jti 的 refresh JWT，存储新 refresh 哈希，更新两个到期时间、last_refresh_at 与 last_accessed_at。旧 refresh 不再匹配，旧 access jti 不再通过会话鉴权；同秒多次成功刷新也产生不同 refresh。期限采用滑动方式，默认 access 900 秒、refresh 2592000 秒。Oracle 表约束要求 refresh 到期晚于 access；无效 TTL 的跨后端处理仍见 AUTH-907。
4. 成功响应是 `{code:200,message:"success",data:{session_id,access_token,refresh_token,access_token_expires_at,refresh_token_expires_at},meta:null}`；时间为 ISO 8601 UTC。同步设置同名 access 和 refresh Cookie，分别使用对应 TTL，HttpOnly、SameSite=Lax、Path=/，仅 `COOKIE_SECURE=true` 设置 Secure。正文返回的 token 与 Cookie 一致。失败不得暴露底层异常、令牌或密钥。
5. 数据库错误不得冒充成功或发送新 Cookie。连接、提交、网络失败后的数据库状态可能未知：例如写入已提交但连接关闭失败或响应未送达；不能假定回滚，也不能自动重试旧 token 并声称结果确定。预检和日志不得泄漏密钥、数据库凭据、session 或 token。
6. OPTIONS/CORS 在鉴权前处理，复用已有共享会话撤销规范中的来源和请求头规则；预检不访问数据库。

## 已知兼容边界

Nuxt 当前 refresh verifier 对经 refresh 密钥签名的 `type` 接受范围比原生严格 codec 更宽，对 userId 的数值转换也更宽；算法允许范围与配置错误处理亦有差异，属于 `authentication.md` 的 AUTH-904/907。原生服务拒绝非正 TTL 或 refresh 不大于 access 的配置；Nuxt 当前没有同等预检。有效、正常签发的 refresh token 是本切片的跨端目标；畸形或旧非标准 token 的全面一致性不得在未统一迁移前宣称完成。用户状态未在 Nuxt 刷新路径重新检查，也不能把此切片描述为账号停用即时失效。

Nuxt 通过 H3 错误外壳将业务错误 envelope 放入 `data`；现有原生接口直接返回顶层业务 envelope。应比较 HTTP 状态和归一化后的业务错误，而非宣称字节相同；Flutter 当前客户端支持两种外壳，其他客户端与统一错误协议仍须实测。Nuxt 在读取凭据前取得连接，原生服务可先校验凭据，因此数据库不可用与无效凭据同时出现时的错误优先级可能不同。

无 refresh Cookie 时，原生服务限制请求正文为 1 MiB，超限按无有效凭据处理；Nuxt 目前没有此处相同的限制。有效 refresh Cookie 优先且不读取正文。超限请求不是三端完全一致的兼容承诺。

会话列表的 Nuxt 响应缓存已绕过，受保护路由每次仍校验 Oracle 的 access jti。其他业务缓存、Oracle TIMESTAMP/主机时区、三端签发和接收组合、真实事务/驱动失败、两前端跨机切换仍需集中联测；本切片不改变或清理任何现有数据。

Nuxt 刷新路径的查询与更新异常已在服务层转换为通用错误，连接池初始化日志也只记录固定类别与受限驱动错误码。隔离测试覆盖 handler 和连接池日志替身，但没有覆盖真实驱动、缓存、全部调用方和全局日志链；实际日志脱敏要求尚未验收，不能据本切片声称整个数据库日志链安全。
