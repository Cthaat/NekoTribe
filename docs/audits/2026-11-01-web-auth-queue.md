# Nuxt Web 认证网络队列：C1检查点

2026-11-01。实际 v2 登录、2FA完成、刷新和当前退出四个API入口已接入 app/services/auth-request-queue.ts。队列按 Nuxt app 对象存于 WeakMap；异步任务执行时通过捕获的 app.runWithContext 恢复上下文，不能让另一app/SSR用户进入同一队列。登录/2FA输入在排队前复制，避免等待期间表单修改改变请求。失败传给调用方，后续操作继续，不自动重放或取消已发请求。

回归实际打包 app/api/v2/auth.ts，隔离网络与Nuxt上下文边界。修改前四个请求并行发送、排队所有者隔离用例失败；修改后4项新测试通过：四入口顺序、失败后继续、输入快照、不同owner不阻塞与上下文恢复。配合已有登录回调/schema和契约payload测试共24项通过；Nuxt typecheck exit0。esbuild测试最初遗漏@ alias，修正测试解析配置后通过，没有通过把新模块external来绕过真实代码。

contracts/parity check通过：登录revision10、刷新revision5、退出revision3，三后端与适用客户端targetRevision同步。退出补充required范围，现required=6、unreviewed=149；两客户端和三后端均无完整accepted凭据，ready=false。共同auth-login/auth-logout规则及Flutter副本同步，刷新通过共享依赖同步版本。一次contracts命令从父目录运行时被cwd校验拒绝，随后在Nuxt根按正确参数重跑通过。

## C2/C3仍未完成

这一步只保证所包装四个v2入口的同app网络promise顺序。Pinia.refreshAccessToken仍未绑定身份，旧结果/失败清理/finally、login.vue状态发布、四个退出调用方的reset/清理/跳转，以及useApi旧响应与重试仍需会话意图守卫。NavUser当前在退出网络前resetToDefaults，不能因队列存在就假定状态安全。

JS忽略旧响应不能阻止浏览器自动处理HttpOnly Set-Cookie；即使请求promise顺序正确，超时/取消、真实浏览器、多页签与SSR/多后端仍须验收。没有运行浏览器或真实服务/Docker，也未修改Rust/Go运行源码。旧v1及任何绕开四个v2包装的调用不在本步已覆盖结论内。

下一步按 [协调计划](../plans/2026-11-01-web-auth-coordination.md) 的C2：每app会话版本和状态提交/清理守卫，随后接入useApi身份、有界重试，再做C3浏览器测试。完整业务、Agent与部署目标全部保留。
