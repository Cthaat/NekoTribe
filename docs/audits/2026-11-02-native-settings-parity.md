# 三后端设置原生一致性检查点

2026-11-02。本轮在空间复查后继续静态开发，修复GET/PATCH /api/v2/users/me/settings的原生差异，完整项目目标保持不变；未启动Docker、真实Oracle/Redis/模型/SMTP，未操作真实账号或日常迁移，也未提交/切换分支。

## 行为变化

- Nuxt的MERGE/UPDATE从隐式autoCommit=true改为false；schema检查之后父用户行锁、初始化、可选更新、读取快照处于同一事务，只提交一次。PATCH在初始化前校验输入；空PATCH仍返回快照。失败回滚，提交失败也尝试清理；未把提交后错误解释为写入已撤销。
- Go/Rust将缺父用户与缺设置行区分为两个固定404，固定中文消息分别为“用户不存在”“用户设置不存在”。三后端校验读取的user_id，错误行不向客户端返回。Go用NullFloat64读取NUMBER标志，原值严格等于1；Rust不再通过整数转换把1.9误读为true。
- 旧top_k先检查原始范围，再截断：3.9→3、1.9→1、10.9→3。Rust同时覆盖真实Oracle行适配使用的数字字符串表示。该读取规则不改变PATCH历史输入截断10.9→10，不迁移日常数据。
- Nuxt在鉴权之前、Rust在外层业务中间件、Go在处理入口保证设置业务成功及鉴权/存储错误private,no-store。Nuxt设置GET绕过响应缓存，设置路径SELECT绕过查询缓存；n_user_settings查询在其他路径也不缓存。没有静默禁用其他普通接口的可选缓存。初始化/修改后的缓存失效通知仍可能访问Redis。
- Nuxt设置路由使用既有safeAuthEntry重建公开固定错误，避免日志和错误响应回显合成驱动细节。共用封装只增加设置400/404白名单，不扩大任意消息透传。
- 修正文档和OpenAPI：PATCH privacy精确public/private，不支持followers或首尾空白；模型ID转换/trim后最多128个UTF16单元。原始输入向量由16项扩至20项，加入两种非法privacy和Emoji长度边界。

## 共同规范与测试

新增specifications/scenarios/user-settings-native.json，7个HTTP场景由三套实际组装HTTP路由分别覆盖GET和PATCH：成功、未登录、无效token、schema503、存储500及两个404。6个NUMBER映射场景由Nuxt服务、Go真实repository/隔离SQL驱动和Rust事务mapper消费。Rust额外将数字值转换为Oracle数字字符串验证。它们不借用Nuxt代理，也不将路由stub当成数据库事务证明。

Nuxt另覆盖锁/初始化/更新/读取/提交/rollback、连接获取/关闭、错用户行失败、撤销/不可用鉴权、非法输入不初始化；Go使用生产applyUserSettings和database/sql驱动夹具验证事务；Rust直接执行生产Transaction编排并覆盖提交及rollback失败。Nuxt缓存测试使用实际两层缓存代码，确认single-backend模式仍绕过设置读取。真实Oracle的连接清理、唯一键/锁并发和删除竞争仍不在隔离证据范围内。

首次回归：Nuxt45项中33项预期失败；Go小数读取及两个缺行区分失败；Rust小数映射及提交失败清理3项失败；后续新增Oracle缓存和privacy schema回归29项中2项失败。修复后结果：

| 本轮最终检查 | 结果 |
| --- | --- |
| Nuxt 30个相关测试文件 | 1368通过，失败/取消/跳过均0 |
| Nuxt typecheck | exit0 |
| Go离线test ./...、vet ./... | 均exit0；未变化的ai/auth包使用Go缓存 |
| Rust离线lib及5个integration目标 | 125通过：lib99、AI availability2、AI conversation4、readiness13、settings PATCH3、settings HTTP4 |
| contracts workspace check | exit0，171 operations、0 schema gaps、4557 schemas |
| parity workspace check | exit0，155 features、69 scenarios、147 sharedFiles、131 sourceAudits；required17/unreviewed138，accepted0/readyfalse |
| 四工作树本轮相关tracked diff --check | 通过；不把全部既有WIP当本轮修改 |

原始日志在父目录.codex-logs/settings-native-*.log及settings-native-contracts.json、settings-native-parity.json。共同输入扩至20项后的首次全量Go/Rust回归发现旧测试硬编码16；已将断言同步为20后重新运行通过，并未放宽业务预期。Rust当前离线工具链缺rustfmt组件，本次未联网安装；尝试未改文件，未宣称格式检查通过。所有运行中的测试句柄均已确认结束。

OpenAPI仍为2.0.0，本次x-contract-revision为2026-11-02-native-user-settings，SHA256为6bd504861fa2608fc875b5006d3e227d1b81d4433bbd8bcbfacd3d3fd71bc9ea。设置GET/PATCH revision3；GET需求reviewed、PATCH整体仍unreviewed（完整presence生命周期待审），三实现和两客户端targetRevision同步3，状态仍in-progress。共同规范/场景复制到Rust/Go/Flutter；客户端运行时代码本轮未改，没有重新运行Flutter完整1156项，旧结果保留为历史。

## 未验收边界与接续

database/sql在Commit返回错误时Tx也已结束，之后Rollback只会返回ErrTxDone；显式调用清理不能证明底层驱动已回滚。Rust连接由池管理，本轮没有模拟证明真实驱动close失败；Nuxt连接获取/关闭失败有HTTP隔离覆盖。提交/关闭或提交后presence查询失败都可能对应已提交数据，不自动重放PATCH。拒绝CORS/预检/未知子路径不属于本轮共同业务场景。

接下来审一般设置页的owner、加载、保存/回滚、并发与迟到结果，完成PATCH presence完整共同场景，再推进AUTH-901/905、资料输入与其余138项客户端范围。完整原生业务、群组/实时/管理、模型可切换、公开数据RAG、持久化上下文、版本化Skills、有界Agent、问答写作/群运营/审核、旧情感分析退役和Windows/Linux多方式多机器部署仍继续，不缩减目标。真实依赖、浏览器/设备、端点切换、两客户端×三后端和部署保留集中验收。

后续接手先读docs/handoff/LATEST.md及START-HERE-PROMPT.md，再按需读取本审计与user-settings-snapshot.md。本轮机器状态和文件哈希记录于docs/handoff/2026-11-02-native-settings-state.json；初始795份快照和两个旧zip保留原样。
