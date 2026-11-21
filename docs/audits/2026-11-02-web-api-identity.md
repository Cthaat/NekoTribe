# Nuxt C2b：apiFetch 原请求身份与一次重试

日期：2026-11-02。接续 [C2a](2026-11-02-web-auth-state.md) 和 [实施计划](../plans/2026-11-02-web-api-identity.md)。本步改动实际 `app/composables/useApi.ts`，不新增依赖，不修改 Rust/Go/Flutter 运行源码。

## 已实现

每次 apiFetch 捕获原 Nuxt app/认证意图版本。首次/重试响应发布、错误处理、获取 store 后、刷新前后均检查身份；旧成功和旧错误以安全 AbortError 拒绝，不返回旧响应体或记录其错误细节，不为新身份刷新/清理。无 app 时普通传输继续，但不借用此后出现的 app 自动恢复认证。

当前401仅对非认证入口/刷新/退出路径恢复，使用捕获 app 上下文及 store 的同版本刷新任务，成功后至多显式重试一次。动态 import 放到进入 app 上下文之前，避免 await 后 store 获取失去上下文。移除100ms等待。底层 retry 固定0，包括调用方显式 retry，避免隐藏网络重试扩大次数；已经取消或刷新期间取消时不再重试。当前重试仍401才清理对应本地状态，其他状态不新增清理。刷新失败仍由 store 的版本守卫负责。

此处“原请求”沿用该次构建的 options/body；没有把任意流式 body 变为可重放，也没有服务端幂等保证。网络不确定结果、Cookie提交时序和真实库副作用均仍需验收。

## 证据

- `web-api-identity.test.mjs` 21项：实际 transport/队列，隔离 store/网络；覆盖旧成功和401/403/500、刷新/重试期间身份变化、动态加载期间失效、取消、认证入口不重放、无app与app隔离、401和其他错误策略。真实安装的 ofetch 通过 `createFetch({fetch})` 注入隔离网络，验证请求没有底层自动重试。
- `web-api-session-integration.test.mjs` 5项：实际 transport、Pinia/Vue、store、认证 service、v2 API/client及队列串联，只隔离 Nuxt上下文/Cookie和网络。两个并发401只有一个PATCH刷新，分别重试；实际刷新成功/失败晚到不污染新身份；当前刷新失败只清理一次，重试401不再次刷新。
- 加上已有 Accept、登录页、队列、状态、退出调用方和payload契约，共8文件84项通过、0失败/跳过。Nuxt typecheck exit0。contracts与parity工作区检查exit0，171 operations、0 schema gaps、155 features、58 scenarios、124 shared files、131 source audits；accepted=0、ready=false，required=6/unreviewed=149。
- 登录需求及共享SHA-256同步Rust/Go/Flutter；登录revision12、刷新revision7、退出revision5，三后端与两客户端targetRevision对齐。相关已跟踪文件diff whitespace检查通过。

首次19项新回归中14项失败，包含旧响应交付、缺失身份守卫/清理及动态import后的app上下文丢失。首轮ofetch替身参数位置错误，修正为安装版本提供的createFetch入口后，单项明确复现旧实现3次底层调用而非1次；修复后通过。最终隔离测试不启动服务，不把早期测试替身问题算产品缺陷。

## 新发现与下一步 C2c

`app/plugins/error-handler.client.ts` 同时监听vue:error/app:error，收到401后另行刷新且无原请求版本。它可能在apiFetch已经恢复/失败后再启动认证动作，故**尚未证明整个Web链路只有一次恢复**。优先统一兜底职责，避免对已处理或无法确认身份的错误自动刷新；写插件与transport串联回归。

`app/composables/useApiFetch.ts` 仍保留旧轮询、watcher及两次刷新机制。当前app源码搜索只发现定义/注释，没有实际调用证据；不能据此保证未来不会使用。下一步决定统一接入新传输或明确退役，避免保留第二套认证策略。不要为了通过窄测试保留已知绕行路径。

之后再处理Nuxt严格响应映射、C3浏览器HttpOnly Cookie/超时/取消/多页签和真实SSR HTTP（包括刷新后转发Cookie/Authorization）、三后端双客户端矩阵。没有启动Docker、真实Oracle/Redis/模型或迁移日常库，没有重编译Rust/Go、重测未改的Flutter、提交/推送。完整原生业务与Agent/部署目标继续保持未完成。
