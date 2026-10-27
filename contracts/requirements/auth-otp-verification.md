# 认证验证码校验

`POST /api/v2/auth/otp/verification` 是公开接口。其目标是让 Nuxt、Rust、Go 可校验共享 Oracle 中由任一后端创建的 OTP；不能代理 Nuxt。发送、注册和密码重置属于关联功能，不因本接口存在就视为已完成。

请求体按既有 `v2Body` / `v2RequiredString` 规则解析 `account`、`type`、`verification_id`、`code`；字段逐项依次验证，字符串去 JavaScript 首尾空白，数字与布尔值按现有规则转换，其他值当空字符串。`type` 仅允许 `register`、`password_reset`、`change_email`，其他返回 400 `type 参数错误`。不增加六位数字格式限制，HTTP body 及错误封套与现有公开认证接口一致。

按 account、用途、verification_id 和 `expires_at > CURRENT_TIMESTAMP` 查询最新验证码哈希；无记录、过期或用途不符返回 400 `验证码不存在或已过期`。使用共享 bcrypt 规则验证，错误码 401 `验证码错误`。验证成功先按 verification_id 更新 `verified_at = CURRENT_TIMESTAMP`，再按 verification_id 读取该时间；缺失或空时间时使用服务当前 UTC 时间。返回 `{account, verified:true, verified_at}`，不会产生登录会话或 Cookie。SQL 使用绑定参数，哈希、验证码、账号和内部错误不得写入日志或错误响应。

与 Nuxt 现状一样，验证并不消费 OTP，未过期的同一码可重复验证；校验与更新等步骤分别提交，并非原子事务。读取、更新或读取回写时间失败均返回安全 500；失败可能发生在更新已提交之后。校验过期按数据库时钟而非应用时钟。已知的验证码随机性、尝试次数、使用次数与 SMS 缺口仍列于 `authentication.md` 的 AUTH-901，不借本切片声称修复。

共同隔离样例见 `scenarios/auth-otp-verification.json`；真实 Oracle 时间、驱动、并发、邮件创建及注册/重置链路必须最后集中联测。低成本 bcrypt fixture 仅用于测试，不是生产参数。
