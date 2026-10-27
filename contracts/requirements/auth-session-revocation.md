# 原生会话撤销切片 v1

对应 `DELETE /api/v2/auth/sessions/{id}` 与 `DELETE /api/v2/auth/sessions/others`，以及二者共用的 access 会话鉴权。Nuxt 为既有行为基准；Rust 原生模式、Go 独立服务直接访问同一 Oracle 模型，不代理 Nuxt。本切片不实现登录/刷新/会话列表/2FA/其他业务；完整认证基线及尚未决策问题仍见 `authentication.md`。

## HTTP 与数据行为

1. 两条 DELETE 必须先鉴权。Cookie字段按出现顺序共同解析（可有多条Cookie头），先取第一个同名access_token，即使其为空也不继续寻找后一个，按现有规则trim/去成对引号、URI百分号解码；解析值非空时优先，否则取Authorization，移除可选、不区分大小写的 `Bearer` 加空白前缀并trim；既有裸token保持兼容。无效非空Cookie不回退有效header。缺失/空token：401/40101，message `请先登录`。
2. 使用既有 token codec 和 access key 验证。需要正安全整数 userId、access 类型、非空 sessionId/jti；过期、错误签名/类型等为401/40101，message `Token无效或已过期`。本次不引入用户状态、issuer/audience 或新的设备策略；相关 AUTH-904 仍待统一修订。
3. 验签后，参数化执行以下 touch，自动提交，恰好更新一行才允许业务执行；0行或错误都按无效 token 拒绝。不只验 JWT，不使用响应缓存跳过会话查询。取得连接、执行或关闭连接失败均不得执行撤销；关闭失败归一化为上述安全401，不允许 finally 抛出底层错误覆盖响应。

```sql
UPDATE n_auth_sessions
SET last_accessed_at = CURRENT_TIMESTAMP
WHERE user_id = :user_id
  AND session_id = :session_id
  AND access_jti = :access_jti
  AND revoked_at IS NULL
  AND access_token_expires_at > CURRENT_TIMESTAMP
```

Nuxt 现有 bind 名为 camelCase，可保留语言惯例，但条件和值必须相同。touch 与业务撤销是两次独立提交，不冒称整体事务。撤销提交和另一已在途请求的竞争，不保证撤回已经获准的操作；撤销完成后的新请求须被数据库检查拒绝。

4. `{id}` 是非空 opaque 字符串，不是整数/UUID验证。字面路径 `others` 必须优先匹配专用路由；为兼容现有 H3 路由，其他 id 保留原始百分号编码的 path segment 后参数绑定，不自动解码、不拼接 SQL；例如 `%70eer` 不等于 `peer`，`%6fthers` 不变成专用 others。Go/Rust 不得直接依赖会自动解码的 PathValue/Path 提取器改变此规则。更新当前用户、指定 session_id、revoked_at IS NULL 的行，将 revoked_at 设 CURRENT_TIMESTAMP；可撤销已经到期但尚未吊销的记录。0行：404/40401，message `会话不存在`（包含他人、未知、重复撤销）。成功200：`{code:200,message:"session revoked",data:null,meta:null}`。
5. 成功撤销当前会话时同时清 access_token 和 refresh_token Cookie：空值、Max-Age=0、Path=/；不额外扩大 Cookie domain。失败及撤销其他会话不清 Cookie。后续使用被撤销 token 的请求401。
6. `others` 更新当前用户全部未撤销且 session_id 不等于当前 session 的行，包括已到期记录；返回200：`{code:200,message:"other sessions revoked",data:{revoked_count:n},meta:null}`。没有匹配返回0。不得撤销当前会话、其他用户或已撤销记录，不清 Cookie。
7. 撤销存储异常返回安全500，不能返回成功或泄漏 SQL/账号/地址/密钥；三端使用50001 `服务器内部错误` 的 v2 envelope。Nuxt 框架可将该 envelope 包于 error.data；共同用例归一化外壳，不声称 wire 字节完全一致。Nuxt通用连接辅助函数的获取/关闭错误也收口为安全500，关闭失败时恢复业务执行前的Set-Cookie，不发送本次新增/删除Cookie。撤销可能已在关闭失败前提交，HTTP500不保证数据库回滚。无真实 session/token/密码出现在日志。

## 跨后端新鲜性

Nuxt 的 session 列表停止使用 API 响应缓存；Rust/Go 将来实现列表时也直接读 Oracle。这样一个原生实例的撤销可被其他实例下一次鉴权/列表读取看到，无需借助某实例特有的 Redis 写入，不能用历史 SQL touch 的误分类来保证新鲜性。现有其他业务缓存和 Redis 协议不在本切片重写；Nuxt 已有 mutation 失效仍保留。

源码复核纠正旧 AUTH-906 观察：真实 Nuxt 连接有 oracle-query-cache 包装，session SELECT 不进 SQL缓存，INSERT/UPDATE 成功同时失效 API auth/account tags；touch 的 WHERE revoked_at 会导致其并非 neutral。因此不能将“2FA route-neutral 必然使列表陈旧”写成既有完整路径事实。列表包含到期记录、排序/分页/时区等其余行为本次保持，完整 GET 迁移另做切片。

## 独立服务接线

- Go 新建实际 `cmd/server`、配置、HTTP router、Oracle session repository；固定 Oracle 官方 `github.com/oracle/go-oracledb/v26 v26.4.0`（Go最低1.26.9，当前SDK1.27.3），使用其公共 `oracle` API 和 database/sql。不需要 Nuxt、C++、Oracle Instant Client。官方称支持19c+；本轮不据文档/编译声称真实库已通过。
- Go HOST 缺省127.0.0.1，GO_BACKEND_PORT 优先 PORT，缺省30006（避免30005现有公共网关）。AUTH ACCESS_SECRET/REFRESH_SECRET、Oracle host/port/service/user/password、pool范围显式配置；native缺密钥、无效端口/池值/必要数据库字段要安全拒绝。sample env不含真实密码，不自动加载父目录 `.env`，不回退到 Nuxt。监听前只读预检连接/必要会话列，不创建/初始化/迁移数据。优雅关闭 HTTP 与 DB，设置请求头/读写/闲置上限。进程 health 仅表示进程存活，不代表完整业务就绪。
- Rust 增加 RUST_BACKEND_MODE=compat|native，缺省compat保留当前兼容路径；native明确不注册 legacy API/storage/WS 转发。native需要 access/refresh keys，接入既有 OraclePool 和新 repository、两条实际 Axum route，未实现业务明确404，不伪造成功。native监听前只读预检所需会话结构。兼容模式继续沿用旧启动/路由，不把它计作原生证据。
- 服务端设置/错误/日志不格式化输出凭据。新增密钥类型/配置应有脱敏 Debug/String/GoString；Driver 的诊断不透传给 HTTP。进程只读本工程显式环境；改端口不触发初始化。
- 原生 CORS 在鉴权之前处理 OPTIONS，复用当前 Nuxt `server/utils/cors.ts` 的精确 origin、method/header 白名单、Vary 与 credentials 语义（含 Flutter x-request-id/platform/device 头）。配置 CORS_ALLOWED_ORIGINS 与可选 NUXT_ 前缀，localhost放行须按既有规则显式配置/开发模式。无 Origin预检204；带不允许origin/method/header预检403；允许204，不查询会话/数据库。实际响应仍鉴权；CORS不是权限。

## 验证与退出边界

公共 `scenarios/auth-session-revocation.json` 使用公开合成 token、固定时间和隔离内存存储状态，三端跑真实 H3/Axum/Go HTTP routing 与 JWT；只替换 Oracle/Redis边界。核对状态、业务 envelope、Cookie、touch次数、数据库状态与第二次失效请求；另测生产 repository 的 SQL/bind/commit/error 使用测试执行器或 database/sql 测试 driver，不把 fake store 通过当真实 Oracle 执行。

原生未知路由/GET/存储/WS 不得触发 Nuxt；模拟上游计数须保持零。Go 编译 Windows/Linux，Rust WSL编译/测试；不启动 Docker、实际后端、真实数据库或模型。完成本切片源码/隔离测试也不标完整 AUTH-S001..035 accepted，真实 Oracle 19c/Free、多实例/双前端与跨机仍待集中验收。

驱动来源：[固定版本 README](https://github.com/oracle/go-oracledb/blob/v26.4.0/README.md)、[公共连接器](https://github.com/oracle/go-oracledb/blob/v26.4.0/oracle/OracleDriver.go)。模块经官方Go校验和获取，origin commit `c62a5c1aa4c5fd5a4bc8a945c2913cd6c39a9fd5`。
