# 多框架接口边界与兼容规则

目标是让 Nuxt Web、Flutter 对接同一套接口，同时保留 Nuxt、Rust、Go 的独立工程与固定分支。Nuxt/Nitro 是当前业务实现基准；Rust 通过配置上游代理业务，Go 尚未实现。新增路由或文档不能代替原生业务完成度。

## 单一规范入口

`doc/v2.openapi.json` 定义路由、请求、响应及权限。`doc/runtime-addresses.md` 定义 API、WS 和文件地址差异。Rust、Flutter、Go 只持有版本化副本，不在各自分支另立标准。更新规范正文后提交，再显式同步来源清单与副本，使清单能指向已经提交的真实字节。

```text
node scripts/contracts.mjs check
node scripts/contracts.mjs sync --workspace-root ..
node scripts/contracts.mjs check --workspace-root ..
```

独立克隆只需第一条命令，不要求兄弟源码、Git 或数据库。规范检查包含路由方法与路径、参数、引用、Schema Object 及快照哈希，不是运行时业务验收。源代码审核、模拟边界测试、真实部署验证分开记录。

## 成功与错误

Nuxt v2 正常成功体为 `{ code, message, data, meta }`，通常 HTTP 200 且业务 code=200。分页信息在 meta，不能把当前页长度当总数。SentimentFlow 代理保留上游原始 JSON/状态，不自动套此封套；相关 schema 明确标注 pinned upstream 及 stub。

请求默认应发送 `Accept: application/json`。现有 Nitro 生产错误响应有外壳 `{ error, url, statusCode, statusMessage, message, data? }`，业务错误封套放在该 data 内；未处理/敏感异常可省略 data。不能把 v2Throw 的 data 对象误当完整 HTTP 错误体。两个前端的请求工具提供 JSON 默认协商，但保留调用方显式 Accept。修改错误序列化属于公开契约变化，需同时迁移前端和回归，不能只改文档猜测。

## 帖子部分更新

`PATCH /api/v2/posts/{id}` 是部分更新的规范入口。原 PUT 行为一直是部分更新，因此保留为 deprecated 兼容入口，直接导出同一 handler，避免两套校验、鉴权和写入逻辑逐渐分叉。两前端 updatePost 使用 PATCH，既有客户端继续使用 PUT。

- 未传字段保留原值；空对象对已有有效帖子不产生更新写入。
- 显式传入空关系数组可清空对应关系，不影响未传关系。
- 内容、媒体等原有合法性与所有权规则不变。null、非数组及别名优先级按实际规范描述，不能统一猜成“null 就是清空”。

不在此次重构中删除旧 PUT，也不将 PUT 改成全量替换，以免破坏现有客户端。

## 服务与数据层

路由层负责 HTTP 参数和统一边界，service 负责权限及业务，serializer 负责公共对象。兼容别名复用 handler，前端 JSON 协商复用 header helper，数据结构定义与迁移执行收拢到数据库层。前端通用 fetch transport 使用 ofetch 的稳定选项类型，具体 v2 模块保留显式 DTO，使外部后端调用无需递归依赖所有本地 Nitro 返回类型。避免把完整兄弟工程复制到分支来取得一个公共工具。

结构迁移由显式迁移命令管理，业务请求只读检查 readiness，缺少必要结构时返回 503；用户设置、群组关系、令牌和帖子等普通业务 DML 仍归对应 service。完整 SQL 基线含开发样例，仅用于新环境，不能通过重跑它升级已有数据库。详见 [schema-migrations.md](schema-migrations.md)。

## 外部集成的可验证边界

SentimentFlow schema 依据明确提交和源码文件哈希生成，不声称任意 latest 镜像都兼容。本地上游的 login、admin/users、stats/overview 当前是占位返回，契约如实保留，不伪造 token、用户列表或真实统计。预测、训练与模型接口仍须在最终阶段用隔离模型、文件和服务验证，不能在静态审核时触发训练或删除模型。

## 本轮允许变更与最终测试

用户已允许按需要增补、拆分、合并和重构接口，要求可扩展、易理解和易接手。本轮选择兼容增量：完善实际字段、纠正错误外壳、增加 PATCH 别名、统一请求头和显式迁移。它们保持已有成功业务语义，并明确保留兼容入口。

最终仍需执行干净克隆构建、隔离 Oracle 升级与恢复、两前端对 Nuxt/Rust 的登录刷新/权限/帖子/媒体/实时矩阵，以及另一台 Windows/Linux 部署。本轮只静态开发，不启动 Docker、应用或训练服务。
