# 认证与会话需求基线

版本：2026-10-26 / 0.1（源码提炼，未共同验收）。范围：Nuxt v2；Rust、Go 必须原生独立实现同一业务，Flutter 仅为客户端。共享 Oracle、Redis 和 files；认证不依赖 SentimentFlow。关联计划：[native-backend-parity](../../docs/plans/2026-10-26-native-backend-parity.md)。

本文的“已观察”表示静态源码事实，不表示线上正确、实际数据库已安装该结构或三后端通过验收。AUTH-001 至 AUTH-016 是兼容基线；AUTH-901 至 AUTH-907 是需统一决策的缺口，不能擅自把修复后的理想行为当作 Nuxt 现状。场景是语言无关的待执行断言，尚无本轮真实服务/Oracle/Redis测试证据。本轮未启动服务或 Docker，未访问数据库、私有环境文件及密钥。

## 来源与接口边界

下列路径均相对 `C:/Code/NekoTribe/nuxt/`；行号来自本轮工作区读取，后续修改应同时更新来源。

| 来源 | 核对内容 |
| --- | --- |
| `server/services/v2/auth.ts:1-1967` | 完整认证服务；各节进一步标明函数和范围 |
| `server/middleware/auth.ts:43-257` | v2公开路径、Cookie优先、JWT和Oracle会话校验 |
| `app/types/v2.ts:119-245`、`app/types/auth.ts:7-86` | HTTP snake_case DTO 与客户端 camelCase VM；VM没有原始token字段不代表HTTP不返回token |
| `server/utils/auth-token-response.ts:9-34` | HTTP token正文、refresh来源优先级 |
| `server/utils/v2.ts:42-132,147-237,263-273,296-343,497-527` | 包装、错误、连接、默认自动提交、输入转换、分页 |
| `doc/neko_tribe-oracle-v2.sql:183-207,259-307,2638-2698` | 基础用户、OTP、会话DDL及用户初始化/审计、会话默认值触发器；不是运行态结构证明 |
| `server/models/v2.ts:72-83,153-205` | 登录/注册SelfUser响应查询与映射；依赖v_user_profile_self和fn_get_user_relationship |
| `server/database/schema-definition.mjs:41-153`、`server/database/readiness.ts:6-50` | two-factor显式迁移结构与只读就绪检查 |
| `server/services/v2/notifications.ts:58-98,137-258`、`server/utils/redis.ts:265-271,323-367` | 登录提醒的通知存储、WebSocket与Redis发布及降级 |
| `server/utils/api-cache.ts:262-268,288-298,344-357,390-428,563-622` | 会话列表缓存、scope、失效例外与tag版本 |
| `node_modules/jsonwebtoken/sign.js:98`、`verify.js:14,132-145`、其`package.json:3` | 本地9.0.2库默认签名HS256；对称密钥默认验证算法集合HS256/384/512；应用未显式收紧算法 |
| `tests/auth-compatibility.test.mjs` | 已有隔离边界测试源码；Oracle/Redis、通知、邮件、用户映射均被替代，不是三后端或真实数据库验收 |

路由文件均使用 `defineV2Handler`，以下是入口映射，入口存在不构成通过证据：

| HTTP | 路径 | 服务函数 / 路由源 |
| --- | --- | --- |
| POST | `/api/v2/auth/otp` | `v2CreateOtp` / `server/api/v2/auth/otp.post.ts:1-4` |
| POST | `/api/v2/auth/otp/verification` | `v2VerifyOtp` / `auth/otp/verification.post.ts:1-4` |
| POST | `/api/v2/auth/registration` | `v2Register` / `auth/registration.post.ts:1-4` |
| POST | `/api/v2/auth/tokens` | `v2Login` / `auth/tokens.post.ts:1-4` |
| POST | `/api/v2/auth/two-factor/challenges`、`.../challenges/{id}` | `v2CompleteTwoFactorLogin` / `auth/two-factor/challenges.post.ts:1-4`、`auth/two-factor/challenges/[id].post.ts:1-14` |
| PATCH / DELETE | `/api/v2/auth/tokens/current` | `v2RefreshCurrentToken` / `v2LogoutCurrent`；`auth/tokens/current.patch.ts:1-4`、`current.delete.ts:1-4` |
| POST | `/api/v2/auth/password-reset` | `v2PasswordReset` / `auth/password-reset.post.ts:1-4` |
| GET | `/api/v2/auth/sessions` | `v2ListSessions` / `auth/sessions/index.get.ts:1-4` |
| DELETE | `/api/v2/auth/sessions/{id}`、`.../sessions/others` | `v2RevokeSession` / `v2RevokeOtherSessions`；对应`[id].delete.ts:1-6`、`others.delete.ts:1-4` |
| POST | `/api/v2/users/me/two-factor/setup`、`.../confirm` | `v2StartTwoFactorSetup` / `v2ConfirmTwoFactorSetup`；对应`server/api/v2/users/me/two-factor/setup.post.ts:1-4`、`confirm.post.ts:1-4` |
| DELETE | `/api/v2/users/me/two-factor` | `v2DisableTwoFactor` / `server/api/v2/users/me/two-factor.delete.ts:1-4` |

表中缩写 `auth/...` 均为 `server/api/v2/auth/...`。

## 兼容需求与验收场景

### AUTH-001 输入、输出与错误包装

已观察：成功正文 `{code:200,message,data,meta}`；无内容业务仍返回 `data:null`。业务错误HTTP/正文code对应400/40001、401/40101、403/40301、404/40401、409/40901、422/42201。`v2Body`要求JSON对象；`v2RequiredString`把字符串/数字/布尔转换为字符串后trim，再拒绝空串，密码也被trim，不能宣称只接收严格字符串或保留首尾空白。布尔 `remember_me`、`agree_to_terms` 只接受字面true。来源：`server/utils/v2.ts`上述范围，`auth.ts:515-523,1396-1425,1507-1516`。

- AUTH-S001：对必填字段缺失、空白、数组JSON提交请求，断言400及包装；数字/布尔转换的现状另做兼容样例，不擅自强化类型规则。
- AUTH-S002：成功重置、当前退出和定向吊销返回HTTP成功且 `data:null`；吊销其他会话返回 `{revoked_count:number}`；列表带meta，其他通常meta为null；错误不泄露密码、hash或密钥。

### AUTH-002 受保护接口身份验证

已观察：`access_token` Cookie非空时优先于Authorization；否则中间件去除可选的Bearer前缀并trim（并非严格要求Bearer）。v2要求userId正安全整数、type=access、非空sessionId/jti，按accessSecret验证JWT。Oracle更新匹配userId/sessionId/access_jti、未吊销且access过期时间仍有效的唯一会话，并autoCommit更新last_accessed_at，恰好一行才建立auth上下文。try块内的校验、连接获取及会话更新异常变401 `Token无效或已过期`；finally中的connection.close异常位于catch外，可能覆盖原成功或401。此处未检查n_users状态。公开认证路径按正则跳过中间件，不受过期access Cookie阻挡；公开posts GET无凭据可访问，有凭据则须校验。来源：`server/middleware/auth.ts:65-100,132-187,213-257`。

- AUTH-S003：有效Cookie与另一有效Bearer同时提供时，使用Cookie所属身份；失效Cookie加有效Bearer仍401。
- AUTH-S004：错误签名、到期、refresh类型、无jti、无sessionId、不安全userId、已吊销或DB access过期均401；有效请求仅更新对应会话last_accessed_at。
- AUTH-S005：过期access Cookie不阻挡登录、refresh、logout、OTP、注册、重置或challenge入口；公开posts有无凭据两种路径分别验证。

### AUTH-003 OTP创建与投递

已观察：account/type必填；type仅register/password_reset/change_email，channel默认email，仅email/sms。6位十进制随机码（当前Math.random），有效300秒；生成 `otp_`+UUID与序列ID，bcrypt成本10持久化code hash。先插入Oracle后发邮件；email使用SMTP secure=true，sms分支没有发送实现。响应只含account/verification_id/expires_at，不含code。没有在服务内观察到频率/尝试次数限制或发送前账号存在性校验。来源：`auth.ts:49-55,64-84,164-175,495-591`。

- AUTH-S006：默认email创建一条OTP并调用邮件投递，核对300秒、hash可验证且无明文code存库/响应；非法type/channel400。
- AUTH-S007：模拟邮件失败，核对请求失败但已自动提交的OTP仍存在；sms仅记录不实际发送的现状标记为AUTH-901，不据成功响应宣称短信可用。

### AUTH-004 OTP验证与用途隔离

已观察：按account/type/verification_id且expires_at>DB当前时间取最新一条，bcrypt验证；缺失/过期400，错误code401；正确则按verification_id更新verified_at并返回时间。没有consumed字段或 `verified_at IS NULL` 条件，允许有效期内重复校验。注册门槛另要求相同email、register用途、未过期且verified_at非空。来源：`auth.ts:593-702`。

- AUTH-S008：错误account、用途或ID及刚好到期均不通过；正确值返回verified=true并记录verified_at。
- AUTH-S009：有效期内相同code重复验证仍可成功；先验证后过期无法注册。此现状不得误写为一次性消费。

### AUTH-005 注册

已观察：必填email/username/password/confirm_password/display_name/verification_id；必须agree_to_terms=true、两密码相等且已验证register OTP。按email或username查重，命中409；序列生成用户，密码bcrypt成本10，空可选bio/location/phone/birth_date存NULL；非空birth_date由Oracle按YYYY-MM-DD解析；email_verified_at设当前时间、status=active，is_active等采用DB默认。返回 `{user:V2SelfUser}`，不创建session、不签token/写Cookie、不消费OTP。应用此处无密码长度、邮箱语法或大小写规范化规则。来源：`auth.ts:1396-1505`，`app/types/v2.ts:144-156`及用户DDL。

- AUTH-S010：正确OTP和输入创建用户，hash验证成功、原文密码不存储，响应无token；条款false/密码不一致400，未验证OTP422，已有邮箱/用户名409。
- AUTH-S011：并发同邮箱/用户名注册以Oracle唯一约束防止重复，但检查到插入的竞争错误是否映射409尚未证明；不能把预查询当作并发幂等。

数据库脚本另定义 `trg_users_init` 在用户INSERT同一语句内生成stats/settings以及like、comment、reply、follow、mention、system、group_invite、group_post默认通知偏好；`trg_users_audit`刷新updated_at/updated_by、按status派生is_active并补默认avatar。三套后端共用同一Oracle时不能再各自重复插入这些初始化行；是否实际安装需独立核对。SelfUser响应经数据库view和关系函数构造，映射包括email/phone/birth_date/email_verified_at/is_active/status/created_at/updated_at及公共资料，不含password_hash（来源见上表）。

### AUTH-006 密码登录与会话签发

已观察：account匹配email或username；未知账号/密码错401相同消息，is_active!=1或status!=active先403；bcrypt通过后检查two-factor就绪。未启用2FA或受信设备命中时生成 `sess_`+UUID、UUID access_jti、两token，session只存refresh的SHA256小写hex与access_jti，不存token原文。记录设备headers、IP、UA、两个到期时间，更新用户last_login_at，设置Cookie并返回 `{two_factor_required:false,user,tokens}`。基础登录device_info/fingerprint并未调用200字截断helper；缺省unknown。remember_me不改变普通会话TTL。来源：`auth.ts:1019-1143,1507-1597`。

- AUTH-S012：邮箱与用户名均能登录；禁用账户403，未知/错密码401；成功会话hash对应返回refresh、jti对应access、last_login_at更新。
- AUTH-S013：缺设备头使用unknown；开启/关闭remember_me不改变普通token生命周期；重复登录各建新会话，无账号单会话限制。

### AUTH-007 Token编码、Cookie与跨客户端

已观察：两JWT均含userId/userName/sessionId/type，库补iat/exp/jti；access使用accessSecret，refresh使用refreshSecret且每次随机jti。应用未设置issuer/audience/算法allowlist；本地jsonwebtoken9.0.2默认签HS256，对称密钥默认验HS256/384/512，不能宣称只接受HS256。access秒数为Number(config)||900，refresh为Number(config)||2592000；没有此处正值校验。Cookie名access_token/refresh_token，HttpOnly、SameSite=Lax、Path=/、Max-Age分别对应TTL，Secure仅COOKIE_SECURE字符串严格等于true，不设置Domain。删除仅给Path=/。HTTP tokens同时返回session_id、两原始token、两个ISO到期时间，移动端可使用Bearer/body refresh。来源：`auth.ts:363-493`、`auth-token-response.ts:9-34`。

- AUTH-S014：解码并验证签名/claims/TTL/jti，Cookie和响应token完全相同；跨语言发行的token必须能由另外两后端校验并匹配共享session。
- AUTH-S015：COOKIE_SECURE=true时两Cookie带Secure，其余值不带；Cookie都有HttpOnly/Lax/Path和正确Max-Age；正文返回原始token满足Flutter独立凭据存储需求。

### AUTH-008 2FA设置、确认、关闭

已观察：setup须登录且当前账号可用、密码正确，已enabled拒绝422；生成20随机字节Base32 secret，返回secret及NekoTribe issuer的otpauth URI（SHA1/6位/30秒）。AES-256-GCM存密文/12字节IV/auth tag（各Base64），key为SHA256(refreshSecret || accessSecret ||固定fallback)。MERGE清除confirmed/enabled，删除恢复码/受信设备，设置settings.two_factor_enabled=0。confirm需已有secret，规范化code后校验TOTP当前步±1；删除旧恢复码，生成10个15字符Base32分为5-5-5的恢复码，规范化后bcrypt成本10存库，设置confirmed_at/enabled_at和settings=1，明文码仅本次响应。confirm未拒绝已enabled状态，可再次生成恢复码。disable须密码及有效TOTP或恢复码，enabled_at清NULL、删除恢复码/受信设备、settings=0，保留加密secret/confirmed_at。不吊销session。来源：`auth.ts:177-361,704-827,1145-1394`。

- AUTH-S016：setup返回URI可由独立TOTP实现使用；库内不见明文secret；已启用setup422，密码错误401，缺secret确认422，错误TOTP401。
- AUTH-S017：确认生成10个可校验hash并双标记启用；再次confirm可重发恢复码，旧码失效；关闭后双标记关闭、恢复码/设备移除，既有session仍存活。

### AUTH-009 2FA登录挑战与恢复码消费

已观察：settings.two_factor_enabled与secret.enabled_at同时真才要求2FA；未命中受信设备时只建 `2fa_`+UUID挑战，300秒，记录remember_me、原请求设备/IP/UA；响应无token/Cookie。完成可从path ID或body challenge_id取值（path优先），要求未消费/未过期且账号active；规范化code去空白/连字符转大写，TOTP优先，允许恢复码。恢复码排除纯6位候选，遍历未使用hash；更新used_at条件IS NULL且恰好一行才算消费。挑战UPDATE同样条件未消费/未到期且恰好一行；之后可建立信任，再签发session。TOTP本身没有跨挑战防重放记录。来源：`auth.ts:273-288,748-827,963-1017,1599-1662`。

- AUTH-S018：需2FA登录不创建session、不更新last_login、不发token/Cookie；错误code401；正确码完成一次挑战，重复/过期完成401。
- AUTH-S019：同挑战并发完成，条件更新仅允许一个请求继续发会话；同恢复码并发完成两个挑战，只一请求消费成功。需真实Oracle竞争验证，隔离SQL替代测试不证明数据库运行态结论。
- AUTH-S020：恢复码已消费后重放失败；TOTP允许当前±1时间步；恢复码消费后若挑战消费/发session失败，码仍可能已提交，见AUTH-903。

### AUTH-010 受信设备

已观察：密码通过后仅凭userId+客户端x-device-fingerprint匹配未吊销/未过期设备即可跳过2FA；unknown/空不能信任。helper将fingerprint/device_info截至200字符。命中仅更新last_used_at及当前设备/IP/UA，不顺延expires_at。挑战remember_me=true时按挑战记录MERGE设备，有效30天、清revoked_at；不存在时用序列ID插入。会话仍按完成挑战的当前请求headers/IP/UA生成，不固定使用挑战元数据。来源：`auth.ts:829-961,1043-1050,1649-1651`。

- AUTH-S021：已知fingerprint密码登录可跳过2FA；到期/吊销/unknown必须挑战；remember_me=false不建信任，true建30天记录，同设备再次信任更新记录。
- AUTH-S022：验证挑战创建后更换设备header，信任目标来自原挑战而session设备来自完成请求；该行为作为AUTH-902待统一，不假设挑战绑定当前请求。

### AUTH-011 Refresh轮换

已观察：refresh Cookie优先，否则读body.refresh_token并trim；正文解析失败按空对象，缺凭据401。验refreshSecret签名并取sessionId；匹配user/session/SHA256(refresh)/未吊销/DB refresh未到期，生成新access_jti和两token，UPDATE再次匹配旧hash及上述状态，恰好一行才写Cookie并返回token数据。更新时间/两个过期时间，采用滑动refresh期限；sessionId保持。旧refresh不再匹配，旧access因jti变更立即失效；随机refresh jti避免同秒token重复。无refresh失败时自动清Cookie或吊销整族逻辑；此处不读取用户active状态，type检查不严格，见AUTH-904。来源：`auth.ts:1664-1756`。

- AUTH-S023：有效Cookie可无JSON刷新；无Cookie时body字符串刷新；失效Cookie+有效body仍401；无/非字符串/过期/错签名refresh401且无会话写入。
- AUTH-S024：连续同秒刷新产生不同refresh，sessionId不变，旧access/refresh均失败，新token可访问；旧hash并发刷新条件更新仅一请求成功，失败者不发新Cookie。跨三后端轮换需各方向验证。

### AUTH-012 退出当前凭据

已观察：公开入口自行解析凭据：refresh Cookie > body refresh；只要有refresh就不回退access；无refresh时access Cookie > 严格Bearer头。refresh须type=refresh，access须type=access且jti；UPDATE按session/user、未吊销及当前refresh hash或access jti精确匹配。未知/过期/错签名/陈旧凭据不更新但通常仍清两Cookie返回logout success；DB异常会抛出，不能宣称无条件成功。来源：`auth.ts:1758-1798`。

- AUTH-S025：分别通过refresh Cookie、body refresh、access Cookie、Bearer退出，当前匹配session被吊销、两Cookie删除、之后access/refresh401；无凭据重复退出200。
- AUTH-S026：轮换前旧access/refresh及失效refresh Cookie+有效body不能吊销当前session；无效refresh加有效access亦不回退，仍清Cookie返回200。

### AUTH-013 密码重置

已观察：email/verification_id/code/new_password必填，直接调用password_reset用途OTP校验，不要求先独立verification；bcrypt成本10更新email对应用户，0行404，否则返回null。没有确认密码、密码强度、消费OTP、吊销会话、清Cookie/受信设备或发送重置通知。OTP verified_at在查无用户或后续失败前可能已提交。来源：`auth.ts:1800-1838`。

- AUTH-S027：正确OTP重置后旧密码登录失败、新密码成功；错码401/过期400，OTP正确但用户不存在404；已有session和受信设备保持现状，不能写成已自动吊销。
- AUTH-S028：同一有效OTP可再次重置（现状）；将一次消费和会话撤销要求作为AUTH-901/905统一决策后再升级验收规则。

### AUTH-014 会话查询与定向吊销

已观察：仅登录用户自己的未吊销session；列表未排除已到期会话，按last_accessed_at降序分配ROW_NUMBER后筛选分页成员，外层查询无ORDER BY，响应行顺序未显式保证；分页缺省1/20，上限10000/100；输出session_id/device_info/ip_address/last_accessed_at/created_at/is_current及meta。也没有同时间戳稳定次序。定向吊销仅匹配自身未吊销session，0行404（含重复调用、他人session），吊销当前时清Cookie；others排除当前session并返回rowsAffected，无匹配返回0。来源：`auth.ts:1840-1953`、`v2.ts:497-511`。

- AUTH-S029：两个用户各两session，用户A只能列出/吊销自身；他人和不存在ID404；已吊销ID再次请求404，不能统一描述为所有退出幂等。
- AUTH-S030：吊销当前session清Cookie；others保留当前、不清Cookie，首次正确计数、重复为0；被吊销会话下一次访问/refresh失败。
- AUTH-S031：未吊销但到期记录仍显示，is_current按sessionId；核对分页边界及同时间戳排序未保证的现状。

### AUTH-015 登录提醒、Redis与缓存副作用

已观察：签发会话前按相同fingerprint的全部历史session计数（含到期/吊销，unknown也参与），0视为新设备；login_alerts默认开，创建high/login_alert通知含session/device/IP/UA元数据；通知type preference控制存储，push preference控制本地WS及Redis `ws:user:{userId}` 的notification_created，带server_id/timestamp。email_notification_enabled默认开，存在email则发邮件。整个提醒异常被登录catch记录，不回滚session/Cookie。Redis不是OTP/session真值库，但存在通知与通用响应缓存副作用。Redis不可用发布函数跳过/捕获错误。

会话GET经通用API缓存，按用户+session隔离，基础TTL20秒、最高120秒；middleware先校验Oracle会话才进入缓存读取。成功变更按tag失效：OTP/verification、challenge完成、PATCH refresh列为cache neutral；其他auth变更失效auth tag，sessions另带account/user，registration另带users。登录/退出是公开入口没有auth上下文，因此只按能得出的tag失效。challenge完成可创建session但不失效列表缓存，可能短暂陈旧。来源：`auth.ts:95-162,1051-1063,1118-1130`及本节来源表。

- AUTH-S032：新fingerprint且提醒启用时按偏好检查通知存库/WS/Redis/邮件；关闭login_alerts全跳过；邮件或Redis故障不改变成功登录结果；不得承诺可靠恰好一次投递。
- AUTH-S033：两session列表缓存不能互相误标is_current；吊销后凭据即使缓存命中也401；分别核对成功mutation tag和neutral例外，2FA完成后可能短时列表旧值作为AUTH-906记录。

### AUTH-016 共享结构、就绪与提交边界

已观察：用户email/username唯一，OTP verification_id唯一；会话access_jti/refresh hash唯一，refresh过期时间必须晚于access，session外键用户；2FA secret按user主键、trusted(user,fingerprint)唯一、各表外键级联删除。2FA schema通过SELECT-only readiness检查，不在请求内建表；缺失转503/50301。认证服务写入均使用默认autoCommit=true的v2Execute，无包裹整段业务的commit/rollback。连接在finally close；middleware自己的last_access更新也autoCommit。结构文件是安装期意图，不等于已验证运行态DDL；基础doc/data SQL存在副本，需迁移权威统一。

- AUTH-S034：隔离schema中核对上述约束及2FA缺失503；缺失结构请求不执行DDL。服务不能静默创建与另一后端冲突的结构。
- AUTH-S035：对OTP发信、注册响应映射、setup/confirm/disable各写步骤、恢复码/挑战消费、session插入后更新用户等逐点注入失败，记录已提交行与返回/Set-Cookie行为；不得据单行条件更新宣称整个流程事务原子。

## 待统一修复或决策的缺口

这些ID不改变上述已观察行为；三套实现的共同规则必须通过版本化变更确定，不能某一语言单独“顺便修好”。

| ID | 现存缺口与决策 | 关联场景/来源 |
| --- | --- | --- |
| AUTH-901 | OTP使用Math.random、无此服务内限流/尝试次数/消费机制；sms接受但不发送。决定验证码安全随机源、限流存储、一次性语义、短信能力与失败响应。不可假设已经Redis限流。 | S006-009/S028；auth:164-168,526-675 |
| AUTH-902 | 受信凭据只有客户端fingerprint，无服务器签发设备秘密；挑战完成没有绑定请求设备/IP；决定共享信任凭据与挑战绑定规则。 | S021-022；auth:843-961,1599-1662 |
| AUTH-903 | 多语句autoCommit导致setup/confirm/disable及恢复码→challenge→信任→session流程部分完成；单行消费防重放不等于全流程原子。决定事务边界、外部邮件/WS/Redis投递时机、失败恢复。 | S007/S020/S035；v2:263-273 |
| AUTH-904 | service token verifier仅要求type为access或refresh，refresh流程不强制refresh；userId规范化比middleware宽松，refresh及受保护请求未重新检查账号可用；JWT验算法未固定allowlist且无iss/aud。决定统一校验、停用生效及密钥兼容策略。 | S004/S014/S024；auth:405-493,1664-1697；middleware:78-100,237-250 |
| AUTH-905 | 重置密码不吊销session或受信设备，不消费OTP；注册/新密码缺少后端强度/格式规则，必填密码trim。决定安全基线及兼容迁移；不可未经决策重写成现状。 | S010/S027-028；auth:1396-1505,1800-1838 |
| AUTH-906 | session列表含过期记录、外层查询无ORDER BY且同时间戳无稳定排序；challenge完成被缓存视为neutral，新增会话列表可能陈旧。决定列表定义、响应排序和跨后端缓存失效协议。 | S031/S033；auth:1840-1905；api-cache:563-569 |
| AUTH-907 | TTL配置缺正值/大小关系预检，DB却要求refresh>access；2FA key派生有固定fallback，改secret后旧密文可无法解密；基本schema双副本及注册并发唯一错误映射未统一。决定配置拒绝条件、密钥轮换/版本、迁移权威和并发错误契约。 | S011/S014/S034；auth:290-337,363-371；DDL:304-306 |

## 验收记录要求

所有AUTH-S001至AUTH-S035当前为 `not-run`。每个场景分别记录Nuxt/Rust/Go提交、规则版本、运行模式、隔离Oracle/Redis身份、输入/HTTP/Cookie、数据库前后状态及事件证据；跨后端token签发/验证/轮换/吊销必须覆盖三个发行者与三个接收者，不可只做各自闭环。Flutter与Web分别验证Cookie和Bearer/body refresh路径。条件更新竞争必须真实Oracle执行；失败注入需检查逐语句提交副作用。已有测试源码只作为可复用测试设计来源，本轮未执行，且不覆盖真实Oracle/Redis/mail/部署。未经这些证据不把任何路由标为accepted。
