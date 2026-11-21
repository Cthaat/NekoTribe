# C2c：统一 Web 认证恢复与 hook 身份

2026-11-02，接续 [C2b](2026-11-02-web-api-identity.md)，按 [迁移计划](../plans/2026-11-02-web-auth-recovery-unification.md) 完成静态接线。完整业务、Agent和部署目标仍未完成。

## 实现

- 删除 `app/plugins/error-handler.client.ts` 的历史全局401恢复插件。它唯一的职责是在vue:error/app:error中再次刷新并clearError，无法知道原请求身份。删除前 `git diff --quiet -- app/plugins/error-handler.client.ts` exit0，没有覆盖此文件未提交改动；Git保留旧实现。没有删除其他开发文件、数据、模型或配置。Nuxt重新生成类型后不再引用该插件。
- `useApiFetch` 从独立轮询/watch/两次恢复实现改为薄适配器：保留useFetch调用方式、Nuxt响应式数据/refresh/options/hooks、server默认false，内部$fetch绑定创建时app后委托apiFetch。调用方$fetch不能覆盖此内部传输，统一处理JSON Accept、凭据、设备头、身份版本及一次恢复。Nuxt安装版本的useFetch源码在 `node_modules/nuxt/dist/app/composables/fetch.js` 调用注入$fetch的可调用部分；适配器只在这个内部位置使用，不暴露通用raw/create接口。
- apiFetch对onRequest/onRequestError/onResponse/onResponseError执行前与异步返回后检查版本及取消，数组hook逐个检查。修复“ofetch先把旧响应交给hook，外层Promise随后才拒绝”的缺口；请求hook等待时身份变化也会阻止发送。合法当前hook保持原顺序。

## 验证

修复前真实全局插件的4项回归都复现额外refresh/clearError；真实ofetch的2项hook回归复现旧内容进入hook或异步等待后继续调用；旧适配器6项中3项失败（无统一恢复、调用方传输绕行、旧成功交付）。修复后通过，不通过跳过测试掩盖退役。

最终10个文件99项测试通过、0失败/跳过：新增全局插件退役4项、适配器6项，apiFetch身份/hook26项；其余为Accept、实际Pinia/store/service/API组合、登录页、队列、状态、退出调用方与payload契约。测试实际运行产品模块和真实ofetch/Pinia/Vue，隔离Nuxt上下文/useFetch与网络；**不是实际Nuxt组件或浏览器验收**。日志在 `.codex-logs/web-auth-unification-red.log`、`web-use-api-fetch-red.log`、`web-auth-unification-green.log`。

Nuxt typecheck exit0；contracts/parity workspace check exit0。171 operations、0 schema gaps、155 features、58 scenarios、124 sharedFiles、131 sourceAudits；required=6/unreviewed=149，accepted=0、ready=false。登录revision13、刷新revision8、退出revision6；共同登录需求和SHA-256同步Rust/Go/Flutter，三后端与两客户端targetRevision对齐。当前parity移除已退役插件的源码引用，保留退役回归。相关已跟踪文件diff whitespace检查通过。

没有运行Docker、真实Oracle/Redis/模型或日常迁移；未重编译Rust/Go、重测未改的Flutter、提交/推送。未重建大型Rust target。

## 下一步

优先补Nuxt `app/services/auth.ts` 登录/挑战/刷新响应的严格运行时解码，与既有Flutter严格模型及共用需求对齐。随后C3验证真实useFetch组件与缓存跨账号生命周期、HttpOnly Cookie、超时/取消、多页签、实际SSR Cookie/Authorization转发及六组合。移除重复认证恢复不代表这些平台行为自动正确；已渲染/缓存的旧页面数据也没有因此全量失效。

继续其余149项客户端范围审查、完整Rust/Go原生功能、知识索引/持久化上下文/版本化Skills/真实Agent、群运营/审核、旧情感模块退役及Windows/Linux多机器部署路线。不从局部测试推算完成率。
