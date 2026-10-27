# 原生登录与双因素认证 v1

目标为 `POST /api/v2/auth/tokens` 及双因素挑战完成接口。Nuxt 为既有业务基准；Rust native 和 Go 独立服务分别访问共享 Oracle，不转发到 Nuxt。登录的密码验证、双因素、用户资料和新设备提醒均属于最终一致性范围；只有某一阶段可运行，不表示本功能已完成。`authentication.md` 是原始审计，具体待验收场景见 `scenarios/auth-login.json`。

## 密码与会话

1. 公开路由读取 account/password；当前 Nuxt 的 `v2RequiredString` 对部分非字符串先转字符串再 trim，使用 email 或 username 原样匹配。无账号与密码错误均 401/40101 `账号或密码错误`；找到账号但 `is_active != 1` 或 status 非 active 时先返回 403/40301 `账号不可用`。只接受安全参数化查询，密码、哈希、令牌与密钥不得进入响应或日志。
2. 密码按平台现存 bcrypt 格式校验；Nuxt 的 bcrypt 按 UTF-8 字节在 72 字节截断，公共样例 `scenarios/auth-bcrypt.json` 固定 `$2a$`/`$2b$`、中文、长输入、错误及损坏哈希等合成情况。测试使用低成本哈希仅为快速验证，不是推荐新密码配置。不得用自行实现的加密或明文密码替代 bcrypt。
3. 密码通过后先检查双因素数据结构就绪，Nuxt 用迁移账本、当前 schema、表列/约束、索引和序列元数据只读检查；不合格返回安全 503，不在请求中自动建表/迁移。三端以 `two-factor-schema-catalog.json` 中 Nuxt 导出的只读规则与全部迁移校验值作为共同检查基础；`scenarios/two-factor-readiness.json` 包含共同字典快照和负向样例。账本不存在或存在但为空时，只要其他结构满足要求可以就绪；账本存在时任一已有记录未知或校验值不符都须拒绝，包括其他功能的记录。一次检查使用同一数据库连接，检查完成后不缓存成功结果。只在设置启用且 secret 已启用时要求第二因素；任何结构/查询异常不能绕过 2FA。
4. 未启用 2FA 或命中现有受信设备才签发会话：生成 `sess_` 加 UUID、随机 access jti 和 refresh jti、两种 JWT；Oracle 保存 access jti 和 refresh token SHA-256，而非明文 token。记录原有设备 header、IP、UA、期限，更新用户 last_login_at；返回 `{two_factor_required:false,user,tokens}`，`user` 为完整 self profile，非简化字段；头像公共地址遵循 `storage-public-urls.md`，token 和 Cookie 与 `auth-refresh.md` 契约一致。普通登录 `remember_me` 不改变 TTL。JWT 密钥及用户/session 数据必须跨端共享。
5. 查历史设备、插入 session、更新 last_login、通知和读取用户资料依既有 Nuxt 逐语句提交，不声称整个登录是事务。登录资料读取成功后才设置 Cookie；session 已提交后资料或关闭步骤失败，仍可能留下服务端会话。新设备判断依历史 fingerprint 数量（包含已撤销或过期会话）。提醒先受 login_alerts 控制；通知类型偏好决定是否存储、push 开关决定是否推送，email 开关独立决定是否发邮件，通知类型禁用并不必然阻止邮件。提醒失败不阻断登录，错误处理不能记录凭据或内部原始异常。该副作用不可省略后称为完整登录。

## 双因素

6. 启用双因素时，Nuxt 按 user+fingerprint 查未撤销、未到期的 trusted device，命中后更新设备信息并签 session；否则创建 `2fa_` 加 UUID、300 秒到期的挑战，只返回 `{two_factor_required:true,challenge_id,account,expires_at}`，不签 token、不建 session、不发认证 Cookie、不更新 last_login。是否记住设备仅记录字面 `remember_me:true`。fingerprint 仅由客户端提供，存在 AUTH-902 伪造与撤销竞争风险，不能称为强设备凭据。
7. 挑战完成时按已有路径/body 规则取 challenge id，检查未消费、数据库时间未到、用户仍 active；解密共享 AES-256-GCM secret（key 及密文/IV/tag 格式与 Nuxt 相同，公共合成样例见 `scenarios/auth-twofactor-crypto.json`），验 TOTP SHA1、6 位、30 秒、允许相邻时间步，或验 bcrypt 恢复码并按 used_at 条件一次消费。按未消费和未过期条件原子消费挑战，只有一行成功才可继续；若记住设备，按挑战原 fingerprint 创建/恢复 30 天设备信任，然后按完成请求当前 header 签发 session。无效、重放、并发及恢复码必须测试。多语句各自提交，因此恢复码或挑战可能已消费但后续步骤失败。
8. 保留 Nuxt 已有的非标准 JWT、TTL、用户状态、设备信任和自动提交差异及 AUTH-901..907；不以更宽输入或失败回退绕过校验。网络故障、写入提交和连接关闭结果可能未知，不能声称失败一定未写入。

## 验收

三端分别通过共享 bcrypt fixtures 和登录/挑战场景，验证真实 HTTP、JWT、bcrypt、TOTP 和隔离持久化边界；检查实际生产 repository 的 SQL、参数绑定和副作用顺序。三语言交叉发行/消费令牌、真实 Oracle 约束/时区/并发、通知/邮件与两前端、Windows/Linux 部署均需最终集中联测。只实现密码登录或只发挑战、不支持挑战完成，均保持 `in-progress`，不得列为 accepted。
