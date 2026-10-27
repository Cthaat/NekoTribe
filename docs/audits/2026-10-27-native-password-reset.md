# 2026-10-27 原生密码重置检查点

后续事务改动见 [密码重置事务检查点](2026-10-27-password-reset-transaction.md)；本文件保留改动之前的历史验证范围。

Go 与 Rust 原生模式新增 `POST /api/v2/auth/password-reset`，根据共同规格使用当前后端的 OTP repository、bcrypt 和 Oracle 绑定更新，不经过 Nuxt；Nuxt 入口将内部异常收口为安全错误。共同规格和 17 条合成场景分别位于 `specifications/requirements/auth-password-reset.md` 和 `specifications/scenarios/auth-password-reset.json`。

隔离场景验证必填字段、验证码不存在/过期/错误、数据库错误、先标记 OTP 后更新用户、用户不存在、密码哈希、长 UTF-8 密码、空白裁剪和不设置 Cookie。生产 repository 的 SQL 与命名绑定由替身数据库驱动或执行器检查；三种语言均未因此证明真实 Oracle、事务或跨后端登录可用。OpenAPI 补齐必填输入、两种错误传输与合成示例，并同步到 Flutter 和原生后端。

本轮继承原业务兼容行为：验证码可重复使用、密码重置不撤销其他已登录会话，OTP 标记与用户密码更新分别提交。这些是**尚待三端统一修复的安全缺口**，不能把此次切片称为生产安全验收。最终还需真实 Oracle 并发、共享会话、限流和跨机器验证。本轮没有启动 Docker、真实应用、数据库、邮件服务器或模型。
