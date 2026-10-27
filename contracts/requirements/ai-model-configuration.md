# AI 模型配置组件格式 v1

这是 AI-MODEL-SWITCHING 的配置/选择子组件规范，不是推理、索引或产品功能已完成声明。Nuxt、Rust、Go 必须分别消费同一份 `specifications/scenarios/ai-model-config.json` 组件样例；本阶段不访问模型、网络或环境变量。

## 输入

顶层只允许 `schemaVersion`、`revision`、`providers`、`models`、`bindings`。schemaVersion 必须为 1；revision 为正 JavaScript 安全整数。providers/models 为非空数组，ID 在各自集合内唯一。

Provider：`id`、`adapter`、`baseUrl`，以及可选/可为 null 的 `apiKeyEnv`。adapter 当前允许 `openai-compatible`、`ollama`，仅代表后续传输适配器标识，本组件不实现 HTTP 传输。baseUrl 必须以小写 `http://` 或 `https://` 开头，包含合法 host 和可选 1..65535 端口，不能有 userinfo、query、fragment、反斜杠、ASCII控制字符或空白；尾随 `/` 去掉，其余原文保留。apiKeyEnv 缺省、null、空字符串均归一化为 null，其他值须匹配 `^[A-Z_][A-Z0-9_]*$`，全空白字符串无效。仅保存服务端凭据引用，不读取/返回真实密钥；额外 plaintext apiKey/token 等字段一律拒绝。

为避免三种 URL 库的隐式改写差异，host 明确支持 ASCII DNS/服务名、规范点分十进制 IPv4 和方括号 IPv6。DNS/服务名总长最多253字符（包含可选的末尾DNS点），每标签1..63，首尾为字母/数字/下划线，中间可含连字符。Unicode域名须配置为ASCII punycode，不自动改写。末标签纯数字或0x十六进制形式时必须是规范四段IPv4，各段0..255且无多余前导0，不允许短地址、八/十六进制IPv4或尾随点；999.999.999.999不能当作DNS名放行。IPv6不支持zone-id；端口冒号出现时必须有十进制数字，不接受空端口。

本格式的空白集合统一为 Unicode White_Space 属性加 U+FEFF，包含 U+0085；不要直接依赖各语言不一致的 trim/正则默认集合。model 及其他文本字段的首尾禁止该集合中的字符，URL任意位置禁止它们。

Model：`id`、`providerId`、`model`、`capabilities`、`contextWindowTokens`、`maxOutputTokens`。providerId 必须存在。model 为首尾无空白的非空字符串，长度最多 256 个 Unicode 字符，可使用自定义品牌/名称/标签，不限定 Qwen。capabilities 为无重复的字符串数组，允许 `tools`、`structured-output`、`vision`，存储/选择结果按字母排序。contextWindowTokens/maxOutputTokens 均为正整数且不超过 2147483647，maxOutputTokens 必须小于 contextWindowTokens。这是声明限制，实际推理仍需后续核对真实能力、token 数与资源。

所有 id/providerId/adapter 标识匹配 `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`。除 model 外其余文字字段按上述格式，不能额外 trim 或静默改写非法输入。未知顶层、Provider、Model、binding 字段均拒绝。

bindings 必须且只能包含 knowledge、writing、agent、moderation 四个键，其值为存在的 Model ID；agent 的模型须声明 tools，moderation 的模型须声明 structured-output。knowledge/writing 不要求这些额外能力。所有绑定在配置应用前一起验证，不能带着错误配置替换已有配置。

## 选择与切换

- `select(role, requiredCapabilities=[])`：role 仅允许上述四个用途，额外能力参数仅为三个合法 capability 的无重复数组；模型不支持所需能力时拒绝，不自动回退。配置本身可被多个用途共用同一模型。
- 返回内部选择快照：configurationRevision、role、profileId、providerId、adapter、baseUrl、model、apiKeyEnv（缺省/空为 null）、capabilities、contextWindowTokens、maxOutputTokens。快照和调用者的原输入、其他选择结果、后续配置独立；外部修改不得改变路由内部状态。这不是可直接向普通用户公开的响应格式。
- `replace(next, expectedRevision)`：先核对 expectedRevision 与当前版本；不符报 STALE_CONFIGURATION。再完整验证 next；next.revision 必须严格大于当前 revision，否则 REVISION_REUSED。成功一次性替换全部配置；失败保持原配置。旧快照保留旧模型，新 select 使用新配置。回退内容也发布为更高 revision，不复用旧版本号。
- 并发读取与替换由实现保证无部分状态：Go/Rust 使用适当锁或等价快照机制。此组件不控制已开始的 HTTP 流；后续推理调用必须传入一次选择的快照，才能完成整条在途请求。

## 错误与范围

错误使用稳定 code：INVALID_CONFIGURATION、UNKNOWN_ROLE、UNSUPPORTED_CAPABILITY、STALE_CONFIGURATION、REVISION_REUSED。错误正文不含原始配置、URL、token 或凭据。构造错误和替换错误不能造成 panic 或将无效状态安装进路由。

URL 解析不等于 SSRF 或访问授权防护：提供方来自受控的服务端配置，前端不得提交任意推理 URL；实际传输层还需网络策略、认证、超时和取消。本组件不证明模型真的支持声明能力，不连接推理引擎，不实现向量模型/索引切换；完整 MODEL-S001..008 仍保持未验收。
