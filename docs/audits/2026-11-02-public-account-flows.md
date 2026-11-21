# 公开账号流程修复

2026-11-02，已核对共同OTP/注册/重置需求、三后端原生实现及两客户端消费者，按 [计划](../plans/2026-11-02-public-account-flows.md) 修复客户端。

Nuxt注册/找回密码与Flutter两屏增加函数级重复发码/提交守卫、失败释放与显式重试。OTP绑定trim后的账号/请求版本，账号变化清除标识与输入，改走再改回仍拒绝旧响应；Nuxt卸载清理定时器并使版本失效，timer回调也检查版本，Flutter用控制器监听/mounted守卫。修复Nuxt注册发码失败后按钮不恢复。

注册在校验OTP前捕获整份资料、ID和code；验证必须严格true且account匹配，账号版本改变/页面销毁不得继续第二阶段，之后只提交快照。Nuxt找回密码仅成功后执行原版本受控的退出/跳转，失败不再在finally退出；旧账号/身份/卸载页面不执行结果副作用。服务端未知提交结果语义保持，不声称网络失败一定没修改密码。

验证：新Nuxt首轮5项全失败、旧Flutter4项Widget回归全失败；修复后补Vue真实reactive/watch、ABA/卸载、错误恢复和显式重试等测试。最终Node12文件160项通过（新流程10项），Flutter四文件106项通过（auth_screens11项）。SFC测试执行实际函数及声明的watch/卸载回调，隔离表单/API/路由；Flutter执行实际Widget并替换仓储，不是实际Nuxt/浏览器/真实服务验收。

Nuxt typecheck exit0；Flutter analyze最终无问题，初次3处if缺大括号已修正；Dart format及相关已跟踪文件whitespace检查通过。contracts/parity workspace check exit0：155 features、171 operations、59 scenarios、126 sharedFiles、131 sourceAudits；required=10/unreviewed=145，accepted=0、ready=false。四功能required/in-progress，OTP创建/校验/注册revision3、重置revision4；三后端和两客户端targetRevision及新共同客户端需求SHA同步。登录14/刷新9/退出7未改。

日志在 `.codex-logs/public-account-{red,node-green,flutter-red,flutter-green}.log` 与 `public-account-parity-2026-11-02.json`。Flutter使用既有SDK缓存写权限，没有删锁/升级依赖。Rust/Go运行源码未改，没有重编译或重建大型target；没有Docker、真实Oracle/Redis/模型、日常迁移、提交或推送，旧交接快照/zip保持不变。

下一步：严格OTP/verification/registration运行时解码和输入规则；安全页change_email/修改密码的OTP版本、销毁和失败不退出；Flutter重置后已有凭据/全局登录状态条件清理（不得清理较新登录）。服务端AUTH-901限流/尝试/消费、AUTH-905输入、并发登录/重置/实时撤销仍未完成。不能从公共两页修复推断全部消费者或服务端完成。

继续其他145项客户端、资料/内容/群组/管理/实时、知识/上下文/Skills/真实Agent及旧情感模块退役；C3实际组件/缓存跨账号、Cookie/SSR、六组合和Windows/Linux跨机器部署留待集中验收。完整最终目标未完成。
