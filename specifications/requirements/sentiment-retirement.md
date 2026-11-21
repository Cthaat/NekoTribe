# 旧情感分析退役与新 AI 入口

Nuxt、Go 和 Rust 对平台旧情感分析入口采用相同的退役协议。旧配置接口返回固定的 `enabled: false` 和 `baseUrlConfigured: false`，供旧客户端隐藏入口。旧预测、训练、模型管理及统计共 12 个操作返回 HTTP 410 与平台错误码 `41001`。同路径下未登记的操作返回 404。响应为固定状态，无需连接 Oracle、Nuxt 或 SentimentFlow，且禁止缓存。

Nuxt Web 的帖子菜单及 Flutter 的帖子菜单、编辑器、账号页和设置页指向已有的知识问答、AI 写作入口。Flutter 的旧 `/sentiment` 页面地址跳转到知识助手。打开新助手只导航，提交正文由用户在助手中触发。助手继续检查登录、服务可用性、内容权限和对话所有权。

Nuxt Web 和 Flutter 的关于页介绍知识问答、写作、群运营与审核辅助，并提供问答及写作入口。群运营与审核功能仍从原有业务入口按角色授权。

SentimentFlow 的独立 Python 服务、源码、模型、训练资料和旧设置记录保留。平台的旧预测及训练路由停止向 Python 转发。新 AI 服务通过配置和适配器独立接入模型。群运营 Agent 与审核辅助仍按各自需求推进。

Nuxt 的镜像及源码 Compose 入口将独立 Python 服务和它的前端放入固定的 `sentimentflow-legacy` profile。普通平台启动不选择该 profile，旧环境开关不再选择这两个容器。三种 Nuxt Compose 模式均向应用传递关闭标志。显式选择旧 profile 或服务名仍可启动独立服务，沿用已有模型存储。

当前 Nuxt 源码已删除旧代理实现和运行时配置映射。升级时可以从平台环境文件移除 `SENTIMENTFLOW_ENABLED`、`SENTIMENTFLOW_BASE_URL` 与对应的 `NUXT_*` 开关。仍使用独立旧前端的部署可以继续使用 `SENTIMENTFLOW_TIMEOUT_MS` 设置旧前端请求后端的超时。

验收需覆盖旧客户端的停用识别、各后端统一响应、Rust 兼容模式的本地退役处理和两端新入口。真实模型与部署组合按 AI 验收矩阵复核。
