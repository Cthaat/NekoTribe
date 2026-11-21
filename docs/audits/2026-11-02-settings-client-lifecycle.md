# 一般设置页身份与保存生命周期检查点

2026-11-02。在原生设置事务检查点之后继续两个客户端，保持四工程、独立等价后端、统一需求、完整业务及AI/部署目标。本轮仅静态开发和隔离验证，未启动Docker或真实Oracle/Redis/模型/SMTP，未操作真实账号、日常迁移、Git分支/提交或旧交接包。

## 修复的行为

Nuxt原设置页直接展示默认值、首次读取失败后仍可保存；重复函数调用不互斥，保存不采用返回快照，也不校验旧身份/卸载结果。现在偏好状态独立于AccountSettingsPreferences.vue，初次读取成功前不显示可编辑默认表单，读取/保存互斥并在实际函数入口拒绝重复。批量保存仅提交相对当前快照修改的字段，无变化不派发，不顺带覆盖其他后端改变的未编辑字段；成功采用服务端完整快照。

AccountSessionGate.vue复用现有每app AuthRequestQueue，同账号重新登录等身份意图也使旧偏好组件卸载；意图结束后显式重开新实例。旧请求与旧控件只持有已失效实例。普通同会话刷新和另一个app不影响当前页面。实际Vue内存renderer发现v-if两分支的key可能冲突导致更新错误，已用明确不同的expired/内容key修复，并验证卸载/重建。SecurityPage放在存活页面父级，继续由它接收会话清理后的导航回执，没有把安全父级一起卸载。

Flutter复用AuthRepository会话通知，核对会话版本、AuthRepository和UsersRepository实例，并使用单调视图generation。加载、保存、重开及会话变化会使旧回调失效；旧frame回调在repaint前或显式重开后都不能派发新的PATCH。保存互斥，远程开关/下拉禁用且函数再次校验；返回完整快照更新页面。取得设置之后、发起旧Python配置/模型/统计请求之前也检查owner，避免旧请求链在新身份下继续。本地主题/语言不写远程设置。

两端保存失败都不声称回滚成功，不自动重放，标记状态未确认并提供显式重新读取。新身份不继承旧身份的不确定提示。Flutter原通用ErrorView会把普通字符串改成泛化错误，新增文字断言发现此问题后，改用既有EmptyView明确显示固定中英文提示和重试按钮，而非向用户显示原始异常。

三后端只接受public/private。Flutter已移除可新选的followers；遇到旧未知privacy时提供禁用的当前值，不崩溃、不默改public。Nuxt也不归一化旧字符串，修改其他字段不提交该旧privacy。Flutter下拉使用有界宽度，未知值与保存不确定提示在320px中英文widget布局均不溢出。Nuxt保留现有响应式样式，真实DOM视觉检查仍未进行。

## 本轮验证

首次Nuxt动作回归10项全部按预期失败，修复后增加身份意图前派发守卫，共11项通过；另3项实际AccountSessionGate模板/生命周期测试通过。Flutter最初5项widget回归复现重复请求、身份变化和未知privacy错误，随后扩至11项，覆盖repository替换、首次读取失败/重复重试、旧读取不再发起旧服务请求、卸载、同身份新意图、旧响应、旧控件和中英文320px提示。完整检查如下：

| 检查 | 结果 |
| --- | --- |
| Nuxt 32个相关测试文件 | 1382通过；失败/取消/跳过均0 |
| Nuxt typecheck | exit0 |
| Flutter完整隔离测试 | 1167通过 |
| Flutter最终设置widget复核 | 11通过（静态风格整理后） |
| Flutter analyze | 无问题、exit0 |
| contracts workspace check | 171 operations、0 schema gaps、4557 schemas，exit0 |
| parity workspace check | 155 features、70 scenarios、149 sharedFiles、131 sourceAudits；required17/unreviewed138，accepted0/readyfalse，exit0 |

日志位于父目录.codex-logs/settings-lifecycle-node-final.log、settings-lifecycle-typecheck.log、settings-lifecycle-flutter-full.log、settings-lifecycle-flutter-related.log、settings-lifecycle-flutter-analyze.log、settings-lifecycle-contracts.json和settings-lifecycle-parity.json。完整Flutter测试后仅修复3处花括号/1处测试字符串插值风格，随后analyze和11项widget再次验证；没有把第一次失败的检查当成最终通过。

两客户端消费同一USER-SETTINGS-CLIENT-LIFECYCLE场景的请求计数与允许值，其他生命周期断言执行实际组件逻辑。规范7项场景登记不等于所有验收环境通过，更不能把内存renderer当真实浏览器。Go/Rust运行时代码本轮未变，未重复运行其运行时回归；上轮Go全量test/vet、Rust125项属于上轮证据。

设置GET/PATCH revision4，三后端和两客户端targetRevision同步4；GET需求reviewed、PATCH整体仍unreviewed（presence全生命周期待审），实现与客户端仍in-progress。新增共同需求及场景已复制到Rust/Go/Flutter。API协议本轮未改变，OpenAPI SHA256仍6bd504861fa2608fc875b5006d3e227d1b81d4433bbd8bcbfacd3d3fd71bc9ea，x-contract-revision仍2026-11-02-native-user-settings。

## 仍需继续

下一步补齐PATCH settings presence的共同HTTP、查询及事件发布/降级场景，再处理AUTH-901/905、资料输入和其余138项客户端范围。完整原生业务、群组/实时/管理、模型可切换、公开数据RAG、持久化上下文、版本化Skills、有界Agent、问答写作/群运营/审核、旧情感分析退役，以及Windows/Linux本地/Docker/混合/多机器部署均保持原范围。本轮仅为保留的旧字段修复页面安全性，没有执行旧情感分析退役。

真实浏览器/Cookie、平台存储、完整端点与认证范围切换、两客户端×三原生后端、Oracle并发/驱动清理、真实模型与部署留待集中验收。任何已发出的PATCH都可能已经提交，UI不能撤销，也不自动重放。机器状态与文件哈希见docs/handoff/2026-11-02-settings-lifecycle-state.json；接手入口为docs/handoff/LATEST.md及START-HERE-PROMPT.md，原始795份快照与旧zip保持原样。
