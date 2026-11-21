# 认证验证码校验

`POST /api/v2/auth/otp/verification` 是公开接口。其目标是让 Nuxt、Rust、Go 可校验共享 Oracle 中由任一后端创建的 OTP；不能代理 Nuxt。发送、注册和密码重置属于关联功能，不因本接口存在就视为已完成。

请求体按既有 `v2Body` / `v2RequiredString` 规则解析 `account`、`type`、`verification_id`、`code`；字段逐项依次验证，字符串去 JavaScript 首尾空白，数字与布尔值按现有规则转换，其他值当空字符串。`type` 仅允许 `register`、`password_reset`、`change_email`，其他返回 400 `type 参数错误`。不增加六位数字格式限制，HTTP body 及错误封套与现有公开认证接口一致。

按 account、用途、verification_id 和 `expires_at > CURRENT_TIMESTAMP` 查询最新验证码哈希；无记录、过期或用途不符返回 400 `验证码不存在或已过期`。使用共享 bcrypt 规则验证，错误码 401 `验证码错误`。验证成功先按 verification_id 更新 `verified_at = CURRENT_TIMESTAMP`，再按 verification_id 读取该时间；缺失或空时间时使用服务当前 UTC 时间。返回 `{account, verified:true, verified_at}`，不会产生登录会话或 Cookie。SQL 使用绑定参数，哈希、验证码、账号和内部错误不得写入日志或错误响应。

Oracle 确认存在尚未过期的记录后，三个后端使用共享 Redis 为该标识原子预留一次 bcrypt 比对。公开校验、直接密码重置和改邮箱共用 `neko:auth:otp-attempt:v1:<verification_id 的 SHA-256 十六进制摘要>`。每次预留都计入五次预算，包括随后匹配成功或写库失败的请求。首次计数后保留 3600 秒，覆盖五分钟的验证码有效期，增加计数不延长保留时间。预留耗尽时返回 429/42901「验证码尝试次数已用完，请重新获取验证码」，不写库，不返回 Retry-After。Redis 缺失、超时、异常或返回无效状态时返回 503/50301，停止比对和写入。Oracle 查不到有效记录时不占用额度。生产部署三后端必须使用同一 Redis 逻辑库，运行时应防止活动额度键被驱逐。

公开校验成功只标记 verified_at，消费仍由注册、重置密码或改邮箱的业务事务完成。查询、标记和回读分别执行，Oracle 时钟决定记录是否过期。读取、更新或读取回写时间失败时返回安全 500，失败可能发生在更新已提交之后。

共同隔离样例见 `scenarios/auth-otp-verification.json`；真实 Oracle 时间、驱动、并发、邮件创建及注册/重置链路必须最后集中联测。低成本 bcrypt fixture 仅用于测试，不是生产参数。
