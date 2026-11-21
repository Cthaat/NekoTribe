# Nuxt Web 认证协调分步实现

目标：修复已审查的登录/2FA/刷新/退出、状态及 Cookie 顺序问题，最终仍需真实浏览器和三后端矩阵。当前不启动 Docker/真实服务。

1. 本步先在实际 v2 API 四个入口使用按 Nuxt app 身份索引的串行协调器，覆盖直接 API 和 service/store 调用。排队前捕获 app/context 和请求数据，执行时恢复该 app 上下文；不同 app/SSR请求不共用队列。旧请求 promise 完成后才发下一认证变更，避免同一页面中并行认证响应互相覆盖 Cookie。失败向原调用方传播，后续任务继续，不取消已发请求或自动重放。
2. 下一步增加会话意图版本，将 Pinia 刷新状态发布/失败清理、登录页与退出调用方、useApi 旧响应/重试全部绑定身份。只有队列不能阻止旧JS回调覆盖新状态，不能把第1步当整个方案完成。
3. 浏览器验证 HttpOnly Set-Cookie、取消/超时、多页签，以及 SSR 会话隔离；JS promise 顺序本身不能证明平台和跨进程行为。

先对实际 API 入口写异步网络替身测试：刷新阻塞后来的登录/退出、失败不毒化队列、四入口顺序、不同 app 无串扰、延迟任务恢复原 app 上下文。按现有 esbuild + Node test 风格，不引入依赖。实现纯协调器与 API 接线，运行针对性测试、Nuxt typecheck、contracts/parity check，再记录部分完成和下一步。

2026-11-02 接续：C1已有网络队列；C2a已接入意图版本、Pinia/页面/退出守卫及默认偏好隔离。C2b已接入apiFetch原请求身份、条件清理与一次重试，相关84项测试通过；新发现全局401插件和旧useApiFetch仍有绕行路径，下一步C2c先统一，再做C3浏览器验证。见 [最新API审计](../audits/2026-11-02-web-api-identity.md)；[C2a审计](../audits/2026-11-02-web-auth-state.md)保留历史依据。
