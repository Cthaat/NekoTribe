# 设置快照与安全状态读取检查点

2026-11-02：完成两客户端GET/PATCH完整设置响应校验及安全页未知/加载/显式重读。仅静态开发及隔离检查；没有启动Docker、真实Oracle/Redis/模型/SMTP，没有操作账号、日常迁移、分支/提交或额外清理缓存。

## 已实现

Nuxt新增settings-response解码模块，GET/PATCH均在完整envelope上验证14字段，再由service直接映射，不再做真假值/缺省强制。Flutter将V2UserSettings移到独立user_settings域模块并由旧user_models重导出，API先校验envelope再用严格工厂，不再toMap/toBool/toInt回退；所有设置布尔/整数快照属性非空，model_id仍可null。仅移除相应调用方已无意义的空值回退，没有实现或冒称旧情感分析退役。

共同规则见 `specifications/requirements/user-settings-snapshot.md`：九布尔、正安全整数user_id、1..10整数top_k、必有可空model_id等；兼容附加字段及当前后端允许的旧privacy/时间字符串，不进行隐式迁移。167项共同向量分别通过两个操作的真实客户端API消费，每客户端334项。OpenAPI同一组向量全部验证，并修正旧PATCH输入schema对既有标量转换的错误收紧，禁止直接设置two_factor_enabled；原生PATCH16类输入/副作用及追加检查继续通过。

安全页状态以null为未知，加载、失败均不显示“未启用”，setup/confirm/disable入口拒绝未知状态。确认还须本页setup，关闭还须已确认开启。显式重读防重复，管理pending时禁用；重读前移除旧密钥/URI/恢复码，旧复制回调检查当前显示数据而非只检查会话。Flutter在状态卡内提供刷新按钮，保留其他账号操作；320px未知状态检查通过。Nuxt实际模板SSR验证加载/未知/开/关及三语言文案，初始误把未知文案放入class的临时实现已被该回归发现并修正。

GET/PATCH设置feature revision2、clientScope required，两客户端均in-progress；**整体requirement review仍unreviewed**，因为原生GET事务/错误/cache的共同业务场景尚未补齐。2FA三项revision6，其他原生2FA业务未改。client required17/unreviewed138；不是把两个完整设置功能标为已验收。

## 实测

- 初始Nuxt334项通过54/失败280；Flutter首次仅GET167项通过27/失败140（`settings-response-node-red.log`、`settings-response-flutter-red.log`）。两安全页失败状态回归各先失败；SSR未知模板、OpenAPI快照/输入和旧复制回调也各有先失败证据。最终相应检查通过。
- Nuxt最终23文件1171项通过，fail/cancelled/skipped均0；typecheck exit0。日志 `settings-status-node-final.log`、`settings-status-typecheck.log`。
- Flutter完整1156项通过，analyze无问题。日志 `settings-status-flutter-full.log`、`settings-status-flutter-analyze.log`。初次新增整行刷新按钮使800×600测试中的确认按钮移出视口，改为状态卡刷新图标后回归通过；没有关闭命中测试或绕过断言。非空模型引发的8项分析提示已修正。
- contracts/parity exit0：171 operations、0 schemaGaps、4531 schemas；155 features、68 scenarios、146 sharedFiles、131 sourceAudits，required17/unreviewed138，accepted0/readyfalse。四工作树作用域diff检查通过。
- 当前OpenAPI SHA256：`0f626331ea72848d43e711c1a65d4633dbc7f9ff67867490e326dfe3747c7085`。三后端/Flutter契约及共同需求副本一致；Go/Rust运行时代码未改，本轮未重跑其运行时回归。SSR内存/模板与widget检查不等价浏览器/真实设备验收。

## 接下来

先为三后端GET设置建立共同原生HTTP场景，统一初始化/事务、缺用户404（当前Go/Rust存储500差异）、schema/关闭/提交后错误、private/no-store及Nuxt cache wrapper，并核对旧小数top_k读取。所需入口在共同规则中；不要重复实现已完成的客户端快照和未知状态。

再完成一般设置页owner/保存/回滚并发、AUTH-901/905、资料输入和138项客户端范围，继续完整业务/AI路线。真实Oracle/Redis/模型/OTP/SMTP、跨端点凭据存储和刷新、Cookie/cache/SSR/跨标签页/设备、六组合及Windows/Linux多方式多机部署仍未验收。原可切换模型、RAG/上下文/Skills/有界Agent、问答写作/群运营/审核和旧情感分析退役目标全部保留。
