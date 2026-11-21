# 三后端双因素管理

共同操作为POST `/api/v2/users/me/two-factor/setup`、POST `/api/v2/users/me/two-factor/confirm`、DELETE `/api/v2/users/me/two-factor`。Nuxt/Rust/Go均独立访问共享Oracle，无Nuxt业务转发。均先校验access Cookie/Bearer/session，支持JSON及form对象；不签发会话或改认证Cookie，成功响应明确 `Cache-Control: private, no-store`。readiness使用既有只读two-factor schema/账本规则，不在请求中建表或迁移。

1. setup按v2标量/JS trim读取password，空400；按鉴权user_id取当前密码/active状态，不存在404、禁用403、错误密码401 `密码错误`，旧短密码兼容。随后检查readiness/现存密钥，已启用422 `双因素认证已启用，请先关闭后再重新设置`，再读取当前资料用于URI。生成20字节安全随机值，Base32无填充32字符；AES-256-GCM使用SHA-256(refreshSecret)、随机12字节IV、独立16字节tag，三者分别Base64保存，与既有登录兼容。URI包含NekoTribe issuer、账号label、secret、SHA1、digits6、period30；不同语言百分号转义可不同，解析后字段须相同。
2. setup单事务MERGE密钥（匹配旧记录时仅enabled_at为空可覆盖，confirmed_at/enabled_at清空）、删除旧恢复码/受信设备、MERGE设置two_factor_enabled=0。密钥更新零行409 `双因素设置已变更，请重试`，多行500。并行未启用setup可最后提交者生效，不承诺两份返回密钥同时可确认；实际Oracle并发/约束仍需验证。
3. confirm将code按v2String转文本、JS trim、移除所有JS空白和连字符、转大写；缺失/null/非标量变空，继续查readiness和密钥，不存在422 `请先生成双因素认证密钥`。已启用422，不能重复confirm悄悄替换恢复码，这是对旧Nuxt行为的有意收紧。AES认证失败安全500；仅6位ASCII数字走TOTP，SHA1/30秒/6位、允许±1步，非法Base32400 `双因素密钥格式错误`，错误code401 `双因素验证码错误`。
4. confirm预生成10个安全随机恢复码，每个取10字节Base32的前15字符，显示为5-5-5；规范化后bcrypt成本10，只存哈希。单事务按读取的密文/IV/tag及enabled_at为空条件启用密钥，零行409；删除旧恢复码、插入10行（共享seq_2fa_recovery_code_id）、MERGE设置flag=1。失败回滚，不部分启用或部分替换恢复码。返回`{enabled:true,recovery_codes:[...]}`，恢复码明文仅本次成功响应提供。
5. disable先验证password，再要求code非空，查readiness及已启用密钥，不存在/未启用422 `双因素认证尚未启用`。优先TOTP；非6位数字的失败code可与未使用恢复码哈希比较，验证阶段不消费。单事务按原密文/IV/tag及enabled_at非空关闭密钥；如使用恢复码，同时条件消费used_at为空的该ID，零行401并回滚。再删除全部恢复码/受信设备，将已有设置flag置0；返回`{enabled:false}`。关闭保留密文记录，不批量注销既有session/挑战。
6. 每次管理写入一次提交，失败尝试回滚；提交或连接关闭报错可能发生在真正提交后，不能承诺未修改或自动重放。关闭双因素时，恢复码的条件消费同时绑定账号和恢复码 ID。密钥关闭先提交后，使用旧密钥完成验证码验证的登录在事务中返回 401。序列取值可能出现空洞，不承诺回滚序列。数据库/密码/密钥/哈希/底层异常不回显或写日志；只有setup的当前明文secret和confirm的当前恢复码属于成功交付字段。三个Nuxt路由使用safeAuthEntry固定安全错误。

`scenarios/auth-two-factor-management.json`为57项共同权威输入；setup/confirm/disable三个auth-factor-*.json为生成的操作视图，Nuxt回归验证视图等于权威子集，三后端实际路由消费权威集合。生成密文可由既有AES解码器读取，恢复码哈希可由既有bcrypt/规范化规则验证；Go实际OracleSessions满足管理接口有编译断言。额外事务隔离测试执行生产SQL/事务流程，覆盖逐步失败和密钥/恢复码条件更新零行。

单事务及禁止重复confirm共同替换旧逐条提交行为，不改变存储/登录格式。两客户端完整成功响应按auth-security-client-response.md，owner/秘密失效/重开按auth-security-client-lifecycle.md，设置快照及未知状态按user-settings-snapshot.md。原生设置事务/错误/cache仍待统一。页面单测不替代真实OTP应用或设备验证。AUTH-901限流/尝试次数、AUTH-905在途登录/挑战/实时撤销、异常Unicode等边界及Oracle锁/驱动/六组合/多机部署仍待完成；不得标accepted。
