# Passkey 登记、管理与登录

三套原生后端启用前须明确配置 `WEBAUTHN_RP_ID` 与逗号分隔的 `WEBAUTHN_ORIGINS`。RP ID 是域名，来源为精确的 HTTPS origin、开发用 HTTP localhost，或明确配置的 Android APK 签名来源。界面通过标准 WebAuthn JSON 与已配置的任一后端通信。服务使用支持 ES256 的标准 WebAuthn 库，校验 challenge、来源、RP ID、类型、签名、用户在场及用户验证。登记要求可发现凭据，认证会使用设备的 Passkey 选择器。 [Web Authentication Level 3](https://www.w3.org/TR/webauthn-3/)

| 接口 | 身份 | 成功数据 |
| --- | --- | --- |
| `POST /api/v2/auth/passkeys/registration/options` | 已登录 | `{challenge_id,options}` |
| `POST /api/v2/auth/passkeys/registration/verification` | 同一有效会话 | `{credential}` |
| `POST /api/v2/auth/passkeys/authentication/options` | 公开 | `{challenge_id,options}` |
| `POST /api/v2/auth/passkeys/authentication/verification` | 公开 | 现有登录成功或两步验证回执 |
| `GET /api/v2/users/me/passkeys` | 已登录 | `{credentials:[...]}` |
| `DELETE /api/v2/users/me/passkeys/{credential_id}` | 已登录 | `null` |

登记验证提交 `{challenge_id,credential,label?}`，认证验证提交 `{challenge_id,credential,remember_me?}`，其中 `credential` 为浏览器或原生认证器返回的标准 JSON。`options` 为标准 `PublicKeyCredentialCreationOptionsJSON` 或 `PublicKeyCredentialRequestOptionsJSON`。用户句柄为 16 字节无符号大端账号 ID，按 Base64URL 表示。挑战标识为 32 随机字节的无填充 Base64URL，每次开始建立一个挑战，5 分钟过期。已登录登记挑战绑定当前账号和会话。验证在同类后端实例消费一次挑战，即便证明错误也需重建挑战。三后端共用标准 ES256 公钥坐标及凭据标识持久化格式，坐标是 32 字节的无填充 Base64URL。已登记凭据可在采用相同 RP 配置的其他后端使用。库生成的短期挑战状态只由签发它的后端实现读取。

客户端管理回执只暴露 `credential_id`、`label`、`created_at` 和可空 `last_used_at`。名称至多 80 个字符，默认 `Passkey`。只有账号所有者可删除其凭据，账号行锁保证删除时仍留有至少一种有效登录方式。认证根据持久化凭据和用户句柄确定账号，成功时原子更新凭据计数和使用时间，再复用密码登录使用的账号状态、可信设备、2FA、会话签发和登录提醒。任一计数为非零时，新计数必须大于已存计数，两个零值兼容无计数器的认证器。密码重置和会话撤销继续走既有失效逻辑。回复为 `private, no-store`。

无效参数返回 400，无效、过期、重复挑战或认证证明返回通用 401，已验证但不可用的账号返回 403。删除其他账号或不存在的凭据返回 404，重复登记或需要保留最后一个登录方式返回 409，未配置或所需结构未就绪返回 503。Oracle 只通过 Nuxt 显式迁移应用表和索引。Web 与 Flutter 从登录和安全中心访问此功能，凭据和密钥由设备认证器管理。
