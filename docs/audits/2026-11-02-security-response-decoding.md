# 两客户端安全响应解码检查点

2026-11-02：接续注销认证队列，补齐两客户端2FA setup/confirm/disable与注销的完整成功响应解码，保持原完整业务/AI/多框架目标及静态开发边界。没有启动Docker、真实Oracle/Redis/模型/SMTP，没有操作真实账号或日常数据，也没有提交、移动分支或额外清理文件。

## 实现及共同契约

Nuxt新增 `app/api/v2/security-response.ts`，四类接口通过完整v2Request响应解码，再由既有service映射VM。严格检查数字code200、非空message、必有meta、error标记、data对象和各操作字段；setup核对32字符Base32和OTP URI中相同secret/NekoTribe/SHA1/6/30及唯一必需查询键，confirm检查字面true和10个完整5-5-5恢复码，disable检查字面false，注销检查字面true及正安全整数ID。支持合法附加字段和参数顺序变化，拒绝坏URI编码/协议/片段/重复关键参数；固定安全错误，不附带外部响应。

Flutter新增不可变安全动作DTO及严格工厂，ApiClient成功envelope回调先校验根结构，API→仓储→页面贯穿强类型，去掉四类动作的Map回退、真值判断和恢复码过滤。恢复码复制且不可修改。不新增恢复码唯一性承诺：当前三后端随机生成没有该保证，10个重复但格式有效的合成码仍是合法测试样例。

Nuxt/Flutter重新setup前先清除旧secret、URI、确认码和恢复码，失败后也不恢复旧显示；这避免服务端已轮换未启用密钥而客户端继续展示旧配置。两页面新增回归均先失败再修复。身份切换时已显示秘密的即时失效仍是独立待办，不把本次清理扩大为已解决该问题。

共同规则见 `specifications/requirements/auth-security-client-response.md`；238项共同向量由两客户端实际API边界消费。同步三后端/Flutter共同需求、OpenAPI和四feature revision4（2FA三项及注销）；三后端运行时代码未改。OpenAPI增强可表达的字段/整数/附加字段约束，URI跨字段语义由共同规则与向量补足，不宣称JSON Schema能独立证明所有URI语义。

OpenAPI SHA256：`37e6337b103b64a9c827fff763889dd31c502c07253a6b759d5dc4daa37d8f98`。

## 验证证据

- 初始232项共同向量在Nuxt和Flutter各通过16、失败216（`security-response-node-red.log`、`security-response-flutter-red.log`），证明宽松解析缺口；最终增加6项JS trim/换行边界后238项全部通过。Nuxt经service检查VM，Flutter检查DTO字段及恢复码不可变，且每项只发起一次HTTP、不写/清token。
- 重生成显示各新增1项先失败回归（`security-regeneration-node-red.log`、`security-regeneration-flutter-red.log`）；修复后Nuxt相关249项通过，Flutter最终完整804项通过。
- Nuxt最终19文件796项通过，fail/cancelled/skipped均0；typecheck exit0。日志 `security-response-node-final.log`、`security-response-typecheck.log`。
- Flutter最终完整804项通过，analyze无问题。日志 `security-response-flutter-full.log`、`security-response-flutter-analyze.log`。早期7条括号风格info已修正；既有API夹具缺meta/无效OTP样例及老Schema夹具缺query已按真实成功响应修正，没有放宽生产解析以迎合夹具。
- contracts/parity检查：171 operations、0 schemaGaps、4527 schemas；155 features、68 scenarios、144 sharedFiles、131 sourceAudits；required15/unreviewed140，accepted0/readyfalse。Go/Rust运行时本轮未重跑，旧原生2FA事务/HTTP结果保留为历史。

以上仅证明本轮实现与隔离检查。解析失败不代表后端未提交，特别是注销响应的Cookie可能已清除；客户端保留本地状态且不自动重放，须主动重新核实。实际浏览器Cookie/跨标签页/SSR、OTP应用、Oracle锁/驱动、设备存储、六组合和部署均未验收。

## 继续工作

下一步补齐两客户端身份变化时已显示secret/URI/恢复码/表单的即时失效和页面重开、状态读取字段及归属审查；然后继续AUTH-901/905、资料输入、140项客户端范围与完整业务同步。RAG索引、持久化上下文、版本化Skills、有界Agent、问答写作/群运营/审核、可切换模型、旧情感分析退役及Windows/Linux本地/Docker/混合/多机部署仍属于原目标。不要将安全响应小项当作整个项目完成。
