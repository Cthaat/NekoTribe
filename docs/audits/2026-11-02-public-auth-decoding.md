# 公开认证响应严格解码

2026-11-02，接续 [账号流程](2026-11-02-public-account-flows.md)，按 [计划](../plans/2026-11-02-public-auth-decoding.md) 实现。

Nuxt auth service与Flutter AuthApi现在在实际API边界校验：OTP创建account/verification_id非空字符串、expires_at为带时区真实日历日期；验证要求account、verified字面true及合法verified_at，拒绝强制转换的开关。响应账号与捕获请求trim后账号匹配。注册检查安全正整数user_id、非空username/email，并与捕获请求匹配；没有要求登录token或新增会话写入。合法附加字段允许，不按当前客户端时钟拒绝过去日期。

复用既有纯日期/身份校验，未给每个端点另建校验框架。Nuxt捕获映射后的payload再等待响应，避免读取等待期间改变的form；用户profile仍用原mapper，异常变成固定安全错误。Flutter公开DTO使用严格字段，登录与注册复用身份检查。未统一所有非认证profile字段/缺省兼容、HTTP envelope或浏览器Cookie行为，不据此宣称完整接口一致。

新增AUTH-PUBLIC-RESPONSES共同JSON46项，使用完整profile基准和有序path变更，只有合成身份。Nuxt实际service、Flutter实际AuthApi/ApiClient/Dio隔离adapter消费同一份；Flutter逐项断言仅一次传输、没有TokenStore.write。样例复制Rust/Go/Flutter并登记SHA，后端运行源码未变。

首轮新共同样例两端各6项通过、40项未按要求拒绝或返回安全错误；修复后46项通过。Nuxt再加3项等待期间修改form仍按原payload校验。最终Node12文件209项、Flutter6文件191项通过；Nuxt typecheck exit0，Flutter analyze最终无问题，3处if语句块风格已修正；Dart format及相关已跟踪文件whitespace检查通过。

日志：`.codex-logs/public-auth-decode-{red,green,node-green,flutter-red,flutter-green}.log`。不运行真实网络、Oracle/SMTP或模型；Flutter使用已有SDK缓存写权限，不升级SDK/新增依赖。

contracts/parity workspace check exit0：155 features、171 operations、60 scenarios、127 sharedFiles、131 sourceAudits；required=10/unreviewed=145、accepted=0、ready=false。OTP创建/校验/注册revision4，密码重置revision5（共同依赖变化），三后端/两客户端targetRevision对齐；登录14/刷新9/退出7不变。密码重置并未因此增加服务端行为或变成完成。

下一步：Flutter密码重置成功后的原会话凭据/全局状态条件清理，禁止清理较新登录；安全页change_email/修改密码的OTP版本/销毁/失败不退出；共同输入规则及服务端AUTH-901/905、并发登录/重置/实时撤销。然后继续其他145项客户端及完整业务/知识/上下文/Skills/Agent路线。

没有Docker、真实依赖/日常迁移、Rust/Go重编译或大型target重建、提交/推送。C3真实组件/缓存跨账号、Cookie/SSR、六组合和多机器部署仍须集中验收。原交接快照及zip不变，整体目标未完成。
