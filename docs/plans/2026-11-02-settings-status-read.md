# 设置响应与安全状态读取

对照Nuxt/Rust/Go当前映射，GET/PATCH设置成功均提供完整14字段快照。原客户端缺字段可回退false，安全页读取失败后仍展示关闭状态。本阶段闭合两客户端完整设置响应与安全页未知状态，不把它当作三后端所有GET事务/错误边界已完成。

设计：GET及PATCH响应校验完整成功envelope与全部快照字段：正安全整数user_id、九个显式布尔、字符串profile_visibility/updated_at、必有可空字符串model_id、1..10整数top_k。保留当前映射允许的旧空字符串时间/未知privacy字符串，不凭本步伪造数据迁移或新枚举。实际传输工厂不再做Map/布尔/整数默认回退；本地测试构造模型可有明确默认值。兼容附加字段。旧情感分析字段本阶段保留线协议，退役仍属于总计划。

安全页以null/unknown阻止setup/confirm/disable，初次读取及重读失败不伪装未启用；支持显式重读，入口防重复。重读前清除旧setup/恢复码，旧owner/迟到结果守卫继续适用。确认仅在当前未启用且持有setup时可发起，关闭仅在确认启用后可发起。账号其他操作不因2FA状态读取失败被误禁用。

- [x] 写共同GET/PATCH响应向量及两客户端真实API/页面失败回归。
- [x] 实现严格快照DTO及安全页加载/未知/重试，更新受影响夹具；重读后旧复制回调同样失效。
- [x] 同步共同需求、OpenAPI、两设置feature客户端范围与接手记录，运行必要回归/静态检查。

三后端GET现仍有需后续统一的错误/事务/cache细节：Nuxt缺用户404而Go/Rust存储错误500、Nuxt无显式成功no-store且受全局cache wrapper影响、Rust错误响应no-store范围待核对、旧小数top_k读取映射边界。登记这些缺口，不据客户端绿灯标accepted。仅静态/隔离，不启动真实依赖、迁移、提交或更换分支。

局部结果与下一步见 [检查点](../audits/2026-11-02-settings-status-read.md)。两个设置feature整体review仍unreviewed，客户端scope已经明确为required；整体目标仍in-progress。
