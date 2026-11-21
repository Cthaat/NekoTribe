# 当前会话原生退出切片 v1

范围为公开接口 `DELETE /api/v2/auth/tokens/current`。Nuxt 既有行为为基准，Rust native 与 Go 独立服务须直接更新共享 Oracle 会话，不依赖 Nuxt 代理。此切片不代表登录、OTP、2FA 或完整业务已完成。`specifications/scenarios/auth-logout.json` 是待执行验收行为，不等于真实 Oracle 或跨端验收结果。

## 凭据与优先级

1. 不需要先通过 access 中间件。`refresh_token` Cookie 原始值非空时不读取正文；否则从 JSON 或 URL 编码表单对象读取 `refresh_token` 字符串。解析失败、缺字段和非字符串按无 refresh 处理，字符串取首尾空白。原始 Cookie 非空但 trim 后为空时，正文仍不读取，随后可回退 access；非空但无效的 refresh 则不得回退 access。
2. 无 refresh 时，非空 access Cookie 原值优先于 Authorization；即使 Cookie 无效，也不得回退 header。只有 header 整体匹配大小写不敏感的 `^Bearer\s+(\S+)$` 才使用凭据；裸 token 和尾随额外文本不接受。不同于受保护中间件，此处不额外 trim access Cookie 或接受裸 Authorization。
3. 使用对应密钥验证 JWT：refresh 须为 refresh 类型，但不要求 jti；access 须为 access 类型并带 jti。均需可定位 userId 和 sessionId。JWT 签名、过期或凭据无效时不能撤销任何会话。Nuxt 对 userId 数值转换和某些非标准 claims 较宽，原生 codec 的兼容范围差异沿用 AUTH-904，不能声称所有畸形 JWT 等价。

## 状态与响应

4. 只有有效凭据才执行参数化单行更新：按 `session_id`、`user_id` 和 `revoked_at IS NULL` 匹配，并且 refresh 使用完整 token SHA-256 哈希，access 使用当前 access jti。将 `revoked_at` 设为数据库当前时间。只能撤销所选有效凭据明确标识的用户和会话，不得按旧 hash/jti 撤销已轮换会话，也不更新已撤销记录。此公开接口没有独立认证主体；同时提供属于不同账户的有效 refresh 与 access 时，按优先级选择 refresh，而不与 access 主体比较。JWT 必须有效；但 Nuxt 的退出 SQL **不检查数据库会话到期时间**，已过数据库期限而 JWT 仍有效的匹配记录也可撤销。
5. 连接、执行和关闭正常时，成功、无凭据、无效凭据、匹配 0 行或重复退出均返回 HTTP 200，`{code:200,message:"logout success",data:null,meta:null}`，清除两个 Cookie：空值、`Max-Age=0; Path=/`。无有效 refresh 时才可能使用 access；无效非空 refresh 不能让同时提供的 access 吊销会话。退出后对已匹配会话的新受保护请求和刷新应被数据库校验拒绝。
6. 存储故障不能当成功，不得将原始异常、token 或凭据返回或写入此路径的 handler 日志。业务更新失败不清 Cookie；关闭失败需要丢弃本次新增的清 Cookie 头。成功写入后关闭或网络出错时，提交可能已经发生；不能声称必然回滚，也不能把客户端看到 500 当作仍登录的保证。连接池/全局日志链的真实驱动脱敏仍需单独验收。
7. OPTIONS/CORS 在鉴权前处理，预检不查询数据库。无 refresh Cookie 时 Rust/Go 原生正文上限为 1 MiB，超限按无法取得 refresh 处理；Nuxt 未在此路径设置同一上限。有效非空 refresh Cookie 时原生实现不读取正文。Nuxt 在读取凭据前取得连接，原生实现可以先解析凭据；无效凭据叠加数据库故障时结果可能不同。Nuxt 的 H3 错误 envelope 包在 `data` 中，原生后端目前在顶层；比较业务错误时须归一化。

Cookie 解析库对畸形引号等非标准语法不完全一致；上述优先级适用于可正常解析的 Cookie，不将异常 Cookie 的所有解析结果声称为跨端一致。

## 竞争及验收边界

用同一个旧 refresh 并发退出与刷新时，按真实单行条件更新竞争：退出先提交则刷新失败；刷新先提交则旧 token 退出可返回 200 并清 Cookie，但旧 hash 不再匹配，新的会话仍可能有效。该既有语义不保证并发退出会撤销已轮换出的新凭据；如果产品要求强保证，需对三端和客户端的协议一起设计迁移，不能在单端静默改变。

验证须覆盖真实 H3/Axum/Go HTTP 路由与 JWT、隔离存储条件、重复及陈旧凭据、无效 Cookie 优先、空白 Cookie 回退、表单、数据库失败、关闭失败和并发顺序；生产 Oracle SQL 与绑定单独用替身验证。三端互认凭据、Oracle 真实提交及并发、时区和两前端跨机仍须集中联测。隔离测试不得作为完整认证验收凭据。

Nuxt Web 当前退出必须与同app的登录/2FA/刷新通过同一认证请求队列，具体规则依赖auth-login.md的客户端网络顺序。仅排队不保证旧状态回调/提前reset不会覆盖新登录；退出UI与状态发布仍需按会话意图版本守卫，并最终验证真实浏览器Cookie与多后端行为。
