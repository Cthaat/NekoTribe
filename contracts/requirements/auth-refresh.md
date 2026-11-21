# 原生会话令牌刷新切片 v1

本切片对应公开接口 `PATCH /api/v2/auth/tokens/current`。Nuxt、Rust 原生模式及 Go 独立服务访问同一 Oracle 会话表。共有验收场景见 `specifications/scenarios/auth-refresh.json`。

## 行为

1. 刷新入口不要求有效 access token。优先使用 `refresh_token` Cookie。Cookie 值非空时跳过正文，即使该值无效或修剪后为空。否则从 JSON 对象的精确字段 `refresh_token` 读取字符串，或从 URL 编码表单读取唯一同名项。按不区分大小写的媒体类型识别表单及 `text/*`，`text/*` 不提供凭据，其余按 JSON 处理。正文必须为有效 UTF-8，表单拒绝无效转义和未转义分号。令牌去除首尾空白。在数据库连接与关闭正常的前提下，无凭据、过期、错签名或无匹配会话返回 401、业务代码 40101、消息 `未认证或 token 无效`，不发新 Cookie；连接或关闭失败可优先返回 500。
2. 合法刷新凭据使用 refresh 密钥校验，需定位原 userId 和 sessionId；保存的是原 token 的 SHA-256 哈希。原子更新必须同时限定 user_id、session_id、旧 refresh hash、未撤销及数据库 refresh 到期时间晚于数据库当前时间。该用户也必须在同一语句内满足 `n_users.is_active = 1 AND status = 'active'`。恰好更新一行才视为成功。账号不可用返回 401／40101，不轮换令牌、不发新 Cookie。Nuxt 的前置读取也检查相同账号状态。数据库、连接和响应均正常时，单个旧 token 并发使用只能有一个成功；这个断言最终须由真实 Oracle 并发测试验证。
3. 成功时保持 sessionId 和用户身份，生成新的 access jti 和具有随机 jti 的 refresh JWT，存储新 refresh 哈希，更新两个到期时间、last_refresh_at 与 last_accessed_at。旧 refresh 不再匹配，旧 access jti 不再通过会话鉴权；同秒多次成功刷新也产生不同 refresh。期限采用滑动方式，缺省 access 900 秒、refresh 2592000 秒。三套后端启动时校验秒数为 1 至 2147483647 的十进制整数且 refresh 大于 access。显式空值无效。
4. 成功响应是 `{code:200,message:"success",data:{session_id,access_token,refresh_token,access_token_expires_at,refresh_token_expires_at},meta:null}`；时间为 ISO 8601 UTC。同步设置同名 access 和 refresh Cookie，分别使用对应 TTL，HttpOnly、SameSite=Lax、Path=/，仅 `COOKIE_SECURE=true` 设置 Secure。正文返回的 token 与 Cookie 一致。失败不得暴露底层异常、令牌或密钥。
5. 数据库错误不得冒充成功或发送新 Cookie。连接、提交、网络失败后的数据库状态可能未知：例如写入已提交但连接关闭失败或响应未送达；不能假定回滚，也不能自动重试旧 token 并声称结果确定。预检和日志不得泄漏密钥、数据库凭据、session 或 token。
6. OPTIONS/CORS 在鉴权前处理，复用已有共享会话撤销规范中的来源和请求头规则；预检不访问数据库。

## 已知兼容边界

三套后端按同一 V2 规则区分 access 和 refresh。刷新及退出兼容缺少 `jti` 的旧 refresh JWT，会话仍须匹配保存的刷新令牌哈希。算法及载荷边界见 `authentication.md` 的 AUTH-904。

Nuxt 通过 H3 错误外壳将业务错误 envelope 放入 `data`；现有原生接口直接返回顶层业务 envelope。应比较 HTTP 状态和归一化后的业务错误，而非宣称字节相同；Flutter 当前客户端支持两种外壳，其他客户端与统一错误协议仍须实测。Nuxt 在读取凭据前取得连接，原生服务可先校验凭据，因此数据库不可用与无效凭据同时出现时的错误优先级可能不同。

三套后端在读取刷新或退出的凭据正文时使用 1 MiB（1048576 字节）上限，无 Content-Length 的流式请求也适用。超限、格式错误和空正文均按未提供正文凭据处理。退出仍按原先规则选取 access 凭据并清除 Cookie。共同请求体用例见 `scenarios/auth-refresh.json` 的 `requestBodyCases`。

会话列表的 Nuxt 响应缓存已绕过，受保护路由每次仍校验 Oracle 的 access jti。其他业务缓存、Oracle TIMESTAMP/主机时区、三端签发和接收组合、真实事务/驱动失败、两前端跨机切换仍需集中联测；本切片不改变或清理任何现有数据。

Nuxt 刷新路径的查询与更新异常已在服务层转换为通用错误，连接池初始化日志也只记录固定类别与受限驱动错误码。隔离测试覆盖 handler 和连接池日志替身，但没有覆盖真实驱动、缓存、全部调用方和全局日志链；实际日志脱敏要求尚未验收，不能据本切片声称整个数据库日志链安全。


## 客户端会话身份与重试

Flutter 为每个受保护请求保存本地会话意图版本，发送前再次核对；旧401不得刷新或清理新会话。自动刷新只在同版本内共享在途Future，结果条件写入；失败仅清理仍匹配的本地版本。每个原请求最多重试一次，重试必须仍属原会话，第二次401终止并条件清理，不能在用户切换后以新身份重放旧请求。旧会话晚到的受保护成功响应应取消，避免把旧用户数据交给新会话。清理和退出回调不得覆盖较新登录；重试网络异常按实际错误返回，不额外清理已成功刷新的凭据。Nuxt Web 需要按其 Cookie/状态管理实现相同语义并完成浏览器验证。

上述自动恢复规则只用于允许恢复的普通资源。改邮箱等已显式声明的凭据修改接口须按各自契约处理：`PATCH /api/v2/users/me/email`的错误OTP也是401，不能自动刷新/重放或清理有效会话；仍发送鉴权并检查原会话归属。Nuxt与Flutter须在该接口的响应错误/网络库错误分支都遵守例外，绝对地址与带查询地址也按规范化路径识别。过期鉴权错误交给页面/用户处理，不能靠重放凭据修改来试探结果。

这些规则不声称安全存储事务、跨进程同步、实际Cookie隔离或真实三后端矩阵已经验收；同时需审查刷新返回的完整令牌/到期字段与同session约束，不能把身份版本检查代替响应契约验证。

刷新客户端必须校验正文完整的非空字符串 session_id/access_token/refresh_token 与两个带时区的有效日历日期；refresh 到期必须晚于 access。session_id 必须与原请求会话一致，响应若可读 Cookie 存在，其 token 必须与正文相等。禁止用旧凭据或旧到期时间补缺字段；非法响应不保存、不重放原请求，只能按原版本失败处理。Flutter 登录与刷新共用纯 TokenPair 模型；显式刷新 API 也用同一校验。Nuxt Web 需按浏览器 HttpOnly Cookie 边界实现与验证，不能把JS忽略旧响应当作已防止浏览器处理Set-Cookie。
