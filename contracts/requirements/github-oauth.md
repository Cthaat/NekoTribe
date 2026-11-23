# GitHub 登录与账号绑定

部署配置包含 `GITHUB_OAUTH_CLIENT_ID`、`GITHUB_OAUTH_CLIENT_SECRET` 与 `GITHUB_OAUTH_REDIRECT_URI`。回调地址必须匹配 GitHub OAuth 应用登记的 `/api/v2/auth/oauth/github/callback`，使用 HTTPS，开发环境可使用 HTTP localhost。客户端从正常登录或安全中心打开 GitHub 授权页面。服务端使用固定 GitHub OAuth／用户接口、随机 state 及 S256 PKCE。只依据已验证的 GitHub 数字用户 ID 识别绑定，GitHub 用户名用于显示。登录须先在已有 NekoTribe 账号中绑定 GitHub。[GitHub OAuth 授权流程](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps) · [GitHub 当前用户接口](https://docs.github.com/en/rest/users/users#get-the-authenticated-user)

| 接口 | 作用 |
| --- | --- |
| `POST /api/v2/auth/oauth/github/login/flows` | 开始登录授权 |
| `POST /api/v2/auth/oauth/github/login/flows/{flow_id}/complete` | 核对授权并走既有账号状态、可信设备、两步验证和会话签发流程 |
| `GET /api/v2/auth/oauth/github/callback` | 校验 GitHub 回调和身份，更新临时流程，显示返回应用的固定页面 |
| `POST /api/v2/users/me/oauth/github/flows` | 当前登录账号开始绑定 |
| `POST /api/v2/users/me/oauth/github/flows/{flow_id}/complete` | 同一有效会话完成绑定 |
| `GET /api/v2/users/me/oauth/github` | 读取当前账号的绑定 |
| `DELETE /api/v2/users/me/oauth/github` | 解绑当前账号的 GitHub，保留至少一种登录方式 |

开始接口返回 `{flow_id,flow_key,authorization_url,expires_in}`。客户端将 `flow_key` 保留在当前操作内，完成时只通过 JSON `{flow_key,remember_me?}` 提交。`flow_id`、`flow_key`、`state`、PKCE verifier 均使用独立随机 32 字节无填充 Base64URL。Oracle 只保存流程密钥和 state 的 SHA-256 十六进制摘要。流程 5 分钟过期，回调 state 与完成流程均一次性消费。回调只写临时流程状态，授权码、GitHub token 和 NekoTribe token 不写入回调页面或日志。GitHub token 只用于取得当前 GitHub 用户，随后丢弃。

完成接口等待期间返回 `{status:"pending"}`，成功分别返回 `{status:"completed",login}` 或 `{status:"completed",link}`。`login` 使用现有登录数据结构；`link` 为 `{github_user_id,github_login,linked_at}`，ID 为十进制字符串。读取绑定返回 `{link}`，未绑定为 `null`。每个 GitHub 身份只绑定一个账号，每个账号只绑定一个 GitHub 身份。相同绑定可确认，其他冲突返回 409。解绑与 Passkey 移除都在账号行锁下检查本地密码、Passkey 和 GitHub 绑定，至少留有一个登录方式。

参数错误为 400，无效、过期、重复、被拒或未绑定的流程为 401，已验证身份所属账号不可用为 403，目标绑定不存在为 404，绑定冲突或最后一个登录方式无法移除为 409，未配置或结构未就绪为 503。回调返回固定无敏感数据的 HTML。接口禁用缓存，回调不向第三方发送 referrer。Oracle 仅通过 Nuxt 显式迁移应用结构。
