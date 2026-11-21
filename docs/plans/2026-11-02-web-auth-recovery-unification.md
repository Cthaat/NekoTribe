# C2c：统一 Web 认证恢复

目标：消除 C2b 发现的全局401插件及历史useApiFetch独立恢复。继续按原app/版本恢复，保持Nuxt useFetch的响应式数据、显式refresh、options及hooks接口，不引入依赖，不启动真实服务。原业务/Agent/部署目标不缩减。

实施：

1. 先为实际全局插件写未知身份401、已处理401经过vue:error/app:error的回归；它不应再发网络或clearError。插件仅有这项职责，没有独立保留价值；确认没有未提交修改后退役，Git保存历史，移除当前parity源码引用。
2. useApiFetch改为薄适配器：useFetch注入绑定创建时app的apiFetch，保留server默认false、调用方options/hooks及Nuxt内部refresh/watch生命周期。内部$fetch由适配器持有，不能被options覆盖。移除轮询、错误watcher和二次认证策略。
3. 对ofetch四种请求/响应hook增加版本/取消守卫。传输返回后的检查不能阻止hook先收到旧内容；运行hook前和异步返回后均核对，每个数组hook也独立核对。合法当前hook按原顺序执行。
4. 隔离Nuxt上下文/useFetch与网络，测试真实适配器→apiFetch行为、延迟执行仍用原app、当前一次恢复/认证入口不重放、过期响应、options保留、显式新请求与无额外watcher。真实安装ofetch用createFetch({fetch})验证hook时序，无外网请求。已有实际Pinia/service/API串联测试继续验证。
5. 相关测试、typecheck、contracts/parity、共享需求副本及revisions、最新交接清单。还不能证明真实useFetch缓存跨账号清除、HttpOnly Cookie、多页签、SSR转发；随后严格响应映射与C3浏览器验证，再回到完整业务和Agent路线。

选择适配器而不是重写Nuxt响应式fetch，避免增加另一套生命周期；不保留无身份的“最后再试一次”，因为全局异常无法证明对应哪个请求/会话。回滚可从Git恢复插件及旧适配器，不触碰数据。

检查点：插件退役、适配器及四种hook身份接线已完成，相关10文件99项测试/typecheck/contracts/parity通过。见 [审计](../audits/2026-11-02-web-auth-recovery-unification.md)。下一步严格响应映射及C3实际组件/缓存/Cookie/SSR行为，当前不宣称整体验收。
