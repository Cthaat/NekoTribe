# T11 最小契约补齐

补充 27 个明确 Nuxt v2 method/path，以及客户端使用的 12 个有限 SentimentFlow 代理 operation。27 项中 25 项有 Flutter 或 Nuxt 前端直接调用；另两项是 roles 兼容别名与无 path-id 的 2FA 完成入口。来源路径附在各 operation 的 x-implementation-source。

新增显式路由只声明已确认的方法、路径、认证入口与响应说明，未经逐字段审查的 query/body/response 不编造 schema，使用 x-schema-audit-status 标明缺口。代理项仅证明 Nuxt 有转发入口，不保证上游部署或业务可用，未将通用 404 catchall 计为实现。

认证修正来自 server/middleware/auth.ts、server/services/v2/auth.ts、server/utils/auth-token-response.ts：公开登录/OTP等不要求已有 access 凭证；refresh 支持 refresh cookie 或 JSON，声明实际返回 token 字符串；logout 说明凭证优先级和无凭证清 cookie 行为；补充已证实的 2FA challenge 字段。没有改变业务代码。

Flutter 未读数原来使用不存在的 GET notifications/read-status，客户端另行改用现有分页通知接口的 unread_only 查询和 meta.total；本契约没有伪造新 GET 路由。

前次记录声称本地引用可解，但本轮复查实际发现三个悬空的 WebSocket payload 引用。已依据 `server/routes/_ws.ts` 的 parseClientMessage、channelIdFromData 和消息分发补充 WsJoinChannelPayload、WsLeaveChannelPayload、WsPingPayload；这些定义记录常见 JSON 帧，不穷举 JavaScript 数值转换边界或 legacy 文本 ping。

本轮静态验证：161 个 operationId 唯一、所有本地引用可解、路径参数声明齐全；148 个明确 v2 源码路由均覆盖，另有 12 个有限代理 operation 与 1 个 WebSocket 协议说明。两个 catchall 不扩展为任意业务路由。原有客户端调用审计记录在父目录 docs/audits/2026-09-10-t11；调用扫描有动态表达式限制，源码存在不等于运行验收。

本次 LF SHA-256：`78588fabac8e6c0c7077e4f4f838aa984e4ab1c3a0d94aa456de18cd83fd2b5d`；Git blob：`4c89ee26638998af98fd0c8bbf4f5caa621382ff`。API 版本保持 `2.0.0`，清单修订为 `t11-route-audit-2026-09-10`。规范正文已提交到 `311f930b42dbbf2cfa64d5d858fab0be4c72739c`，随后重新同步四份清单：两个文件的实际快照与该提交 Git blob 完全一致，全部 `differsFromCommittedSource=false`。`doc/contracts.manifest.json` 仍区分快照与已提交来源，避免未来把未提交修订归到旧 HEAD；Rust manifest.json、Flutter source.json、Go manifest.json 使用同一结构并记录相同来源。三个工作区的 OpenAPI 与 runtime-addresses.md 均逐字节同步。

工具：在 Nuxt 项目执行 `node scripts/contracts.mjs check`，仅依赖 Node 内置模块和本项目文件，可以离线、无 .git、无兄弟目录运行。只有 `check --workspace-root C:/Code/NekoTribe` 才检查四目录；`sync --workspace-root C:/Code/NekoTribe` 才写入来源规范化副本与清单，sync 需要本地 Git 以记录基线。缺失文件、哈希漂移、错误来源/版本、未覆盖路由、重复 operationId、悬空 ref、缺失路径参数或 CRLF 均退出非零。`node --test tests/contracts.test.mjs` 使用临时仓库验证故障及离线路径。

另修复遗留的 79 处无效 `type: "null"`。逐项源码审查后：24 处改为 number+nullable，32 处改为 string+nullable；21 处原有只 null 响应保持严格只 null，使用 type:object、nullable:true、enum:[null]，其中 enum 排除所有非 null 对象；notification metadata 按 V2Json 定义覆盖各 JSON 类型；last_message 改为原对象 ref 或只 null 分支，避免 allOf 内的非 nullable ref 独立排除 null。Logout 原有只 null 定义另补显式基类型。标准依据为 [OAS 3.0.1 Schema Object](https://spec.openapis.org/oas/v3.0.1.html#schema-object) 的 nullable、enum 和类型集合规则。每项前后定义、JSON pointer 与源码依据见同目录 `2026-09-10-t11-null-schema-repair.json`。

校验器现在遍历 3171 个 Schema Object，拒绝无效 type（含 null 和数组类型列表）、array 缺少对象 items、无效 nullable/组合结构，且不会把 example.type 当作 schema。9 项零第三方依赖回归测试覆盖错误来源、版本、哈希/副本漂移、文件缺失、路径参数/ref/operationId、非法 Schema Object、无效 UTF-8、显式同步与无 .git/兄弟目录的离线检查。另执行 `node --test tests/contracts/null-schemas.test.mjs`，使用现有 Nuxt 依赖树中的 Ajv 6.12.6 nullable 模式，验证 79 个修复 schema 的 304 个 null/非 null 值断言全部通过；该可选语义审计需要已安装依赖，核心 check 与9项回归仅依赖 Node 内置模块。

尚未完成的 schema 审核：39 个新增 operation 保留 x-schema-audit-status，query/body/response 未逐字段穷举；SentimentFlow 上游业务仍未验证。本工具是拓扑、引用、参数、已实现 Schema Object 结构规则及快照来源检查，不能当作完整 OpenAPI 规范验证器。运行集成验收按用户要求留到最终全面测试，本轮没有启动服务或 Docker。
