# 三后端原生修改邮箱计划

沿用已确认的auth-email-change.md。复用既有鉴权、OTP查询/bcrypt和密码重置事务风格，不新增依赖/数据库迁移；先测试后实现。保持Windows/Linux部署、完整业务与Agent的整体目标，不以本切片代替验收。

1. 新增共同auth-email-change场景，覆盖鉴权优先、标量/空字段、新邮箱/用途绑定、重复邮箱、错误OTP、事务claim/update/read/commit/rollback失败、行数异常、唯一性竞争与重放。
2. Nuxt现有v2ChangeEmail改为条件消费OTP和邮箱更新/读回同一事务；错误安全包装，提交/关闭失败不伪造成功。
3. Go接原生PATCH路由、最小repository边界和Oracle事务。Rust同样接router/repository/executor/Oracle事务；复用现有会话Touch，拒绝未认证请求。
4. 共同HTTP场景、各实际事务SQL隔离测试、契约/类型/格式检查。Rust离线编译禁用增量与debug信息，限制构建体积；不启动Docker或真实Oracle/Redis/模型。
5. 同步共享规范、场景、parity任务/源码绑定及交接文档。真实Oracle锁/唯一性/未知提交结果、SMTP、Cookie与六组合最后集中验证；不得报告整体完成。

本切片1–5已接线并完成隔离检查，详细结果见[原生邮箱检查点](../audits/2026-11-02-native-email-change.md)。真实依赖与完整功能验收仍未完成。
