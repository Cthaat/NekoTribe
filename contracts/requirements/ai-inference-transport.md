# AI 推理传输组件 v1

AI-MODEL-SWITCHING 的非流式 HTTP 子组件，三套后端原生实现；不是公开 AI 业务接口、权限实现或实际模型验收。模型配置/选择格式沿用 `ai-model-configuration.md`。支持文本历史、工具调用提议和结果回传、JSON schema 请求；流式输出、实际工具执行、图片、向量/索引、真实引擎能力探测仍在后续切片实现。

## 服务端边界

- 调用者传入一次 router.select 取得的内部选择快照；调用开始先复制本次需要的字段，配置变更/原对象变更不改变在途请求。普通客户端不得提供 selection、URL、模型或凭据引用。
- 凭据仅通过服务端注入的同步 resolver 按 apiKeyEnv 取值；没有引用则不调用 resolver、不发送 Authorization。有引用时缺失/空/含不可见或非 ASCII 字符（凭据必须匹配可见 ASCII `^[\x21-\x7E]+$`，不含空格）报 MISSING_CREDENTIAL；resolver 异常同样映射此错误。只发送 `Authorization: Bearer <value>`，不转发用户 Cookie/Authorization，不在错误/日志返回密钥或引用。
- 每次只发送一次 POST，不重试、不回退、不跟随任何重定向。提供方来自管理员受控配置；此组件的 URL 语法校验不能代替部署网络授权。HTTPS 使用系统正常证书验证，不禁用校验。v1 提供方入口须支持 HTTP/1.1；Go 显式使用 HTTP/1.1 与不可回放的请求正文，防止标准库协议自动重试，Rust 显式禁用 reqwest 协议重试。只接受 HTTP/2 的端点尚不在三端共同支持范围。
- timeoutMs 默认 30000，允许整数 1..300000；超时覆盖发请求和读完响应。支持调用者取消（TS AbortSignal、Go context、Rust 异步取消信号/丢弃 future）；不取消其他请求。
- HTTP 请求 JSON 和成功响应交给 JSON 解析器的字节各最多 1048576 bytes；按读取流累计限制，不能仅相信 Content-Length。发送 `Accept-Encoding: identity`，成功响应 Content-Encoding 只接受缺省或去除首尾 ASCII 空白、转小写后恰为 identity；其他编码一律在读取正文前拒绝为 INVALID_PROVIDER_RESPONSE，不依赖三种库不同的自动解压行为。内部采用原始 JSON 字节输入的实现也在解析前限制输入为 1048576 bytes；对象输入的 TypeScript 在复制/编码时校验。Go 请求编码关闭默认 HTML 字符转义，避免普通 &/</> 文本被无谓扩成六倍字节。请求超限报 INVALID_REQUEST，响应超限报 RESPONSE_TOO_LARGE。不记录提示词/原始提供方响应。非 2xx（包括 3xx）不读取/暴露错误正文。

## 公共请求 JSON

只允许 `messages`、可选 `tools`、可选 `responseSchema`。未知键拒绝，不偷偷传给提供方。JSON 序列化必须成功，拒绝非 JSON 值/非有限数、循环、稀疏数组或带自定义序列化的对象（普通 JSON 数据的 toJSON 键允许，函数/访问器不允许）。请求 JSON 整体、独立解析的工具 arguments 与结构化 text 最大容器深度64；字符串和 object 键必须是 Unicode scalar：有效 UTF-8/合法成对的 UTF-16 转义允许，未配对的代理项拒绝，不能替换成 U+FFFD 或原样保留。根 object/array 计为1，每层 object/array 加1，标量不增加。编码后的 HTTP 请求及提供方 JSON 整体最多70层，给不同协议包装留出空间；检查必须有深度边界，不能先无界递归。

- messages 长度 1..128；普通 system/user/assistant 文本项只能有 `{role,content}`，content 必须是字符串（允许空）。完整工具调用及结果历史格式、顺序验证和两种提供方转换见 `ai-tool-history.md`。
- tools 缺省为空数组，最多32个。每项且只能有 `{name,description,parameters}`；name 匹配 `^[A-Za-z_][A-Za-z0-9_]{0,63}$` 且唯一；description 是字符串；parameters 是 JSON object 且 `type:"object"`。发送的 schema 不在传输层完整验证或解释。
- responseSchema 若提供必须是 JSON object 且 `type:"object"`，不允许 null/boolean。工具和 responseSchema 不可同时出现（首期跨引擎组合能力未验证）。
- 有 tools 或工具历史时快照须有 tools capability；有 responseSchema 时须有 structured-output capability，否则 UNSUPPORTED_CAPABILITY，且不得发网络请求。无凭据也应在请求和能力校验之后才处理，保证错误优先级一致。

## 提供方编码

baseUrl 是 API 基地址，移除尾随 `/` 后追加路径，保留现有前缀；不得使用会丢掉 `/prefix` 的 URL 根路径拼接。管理员配置 OpenAI 兼容服务为 `https://host/v1`，Ollama 为 `http://host:11434`（可有反向代理前缀）。

| adapter | 追加路径 | 必需 JSON |
| --- | --- | --- |
| openai-compatible | /chat/completions | model、messages、stream:false、n:1、max_tokens=快照 maxOutputTokens |
| ollama | /api/chat | model、messages、stream:false、think:false、options:{num_predict:maxOutputTokens,num_ctx:contextWindowTokens} |

Ollama 请求关闭思考输出，把 `num_predict` 预算留给正文、工具调用或结构化结果。隔离验收使用 Qwen 3.5 4B 复现了默认思考耗尽输出预算并返回空正文。

有工具时两者 tools 都编码为 `{type:"function",function:{name,description,parameters}}`。有 responseSchema 时 Ollama 使用 `format:schema`；OpenAI 兼容使用 `response_format:{type:"json_schema",json_schema:{name:"output",strict:true,schema}}`。不同引擎/模型可能不接受这些能力或 schema；拒绝须返回安全错误，不降级为普通文本成功。本切片不声称覆盖所有云厂商扩展参数。

## 归一化成功响应

返回 `{text,toolCalls,finishReason,usage}`，不透传其他字段（包括 thinking/reasoning、供应商诊断、URL、凭据、原始 response）。结果是内部组件值，业务接口仍需鉴权与字段选择。

- toolCalls 是 `{id,name,arguments}` 数组，最多32；name 必须在本次已声明 tools 中，arguments 必须是 JSON object。OpenAI arguments 是 JSON 字符串，需解析；Ollama 是 object。两种都只产生提议，传输层绝不执行。
- OpenAI 要求 choices 恰好1项、index:0、message.role:assistant。content 是字符串或 null；null 仅在存在工具提议时允许。工具项要求 type:function 和非空、唯一的 id（最多128字符），function.name 和 arguments。无工具时 tool_calls 可缺省/null/空数组；有工具时 finish_reason 必须是 tool_calls。finish_reason 只接受 stop/length/tool_calls/content_filter，归一化 tool_calls 为 tool-calls、content_filter 为 content-filter。
- Ollama 要求 done:true、message.role:assistant、content 为字符串。tool_calls 可缺省/null/空数组；有调用时每项 function.name/arguments 有效，type 若存在必须为 function（允许 Ollama 的 function.index）。归一化 id 按数组顺序生成 `ollama-0` 等；不采用外部执行标识。done_reason 必须是 stop/length，有调用时须为 stop；有调用则 finishReason:tool-calls，否则保持 stop/length。
- 非工具成功必须有非空文本（空串拒绝，但不 trim，空白是文本）。JSON schema 模式仅当 finishReason:stop，且 text 能完整解析为 JSON object 才成功；截断/拒绝/无效 JSON 报 INVALID_PROVIDER_RESPONSE。**JSON object 通过不是 JSON Schema 验证**；业务层必须用自己的类型/规则验证后再展示或操作，不能以传输成功赋予工具或审核权限。
- usage 固定 `{inputTokens,outputTokens}`；缺省字段归一化 null；提供则必须是 0..9007199254740991 的整数（数值相等的 1.0/1e0 接受，字符串/null 拒绝），否则拒绝。OpenAI 来自 usage.prompt_tokens/completion_tokens（usage 缺省/null 可接受）；Ollama 来自 prompt_eval_count/eval_count。允许额外提供方字段，不能返回它们。finishReason 不认识/未完成、多 choices、未知工具、无效 JSON、非对象 arguments 等均 INVALID_PROVIDER_RESPONSE。

## 稳定错误与验证

错误只包含固定 code/安全固定消息，不包含底层 cause 或请求/响应数据：INVALID_REQUEST、UNSUPPORTED_CAPABILITY、MISSING_CREDENTIAL、PROVIDER_UNAVAILABLE（连接失败等）、PROVIDER_REJECTED（非2xx）、INVALID_PROVIDER_RESPONSE、RESPONSE_TOO_LARGE、TIMEOUT、CANCELLED。取消发生在发请求前时不得调用 resolver/HTTP；请求校验优先于 resolver。HTTP 成功但无效/非 UTF-8 JSON 同样拒绝；UTF-8 BOM 不静默移除，按无效 JSON 拒绝。

公共 `scenarios/ai-inference-transport.json` 在三种语言执行相同编码、响应和拒绝断言。额外用临时 loopback 假提供方验证真实 HTTP 路径/头/body、重定向零跟随、超时/取消、流式读取体积限制、失败一次且无密钥泄漏、旧快照切换目标隔离。这是适配器单元/边界验证；不启动 Docker、应用、数据库或真实模型，不计 MODEL-S001..008/AI 产品场景验收。

## 官方协议来源（2026-10-27 核对）

- [Ollama Chat](https://docs.ollama.com/api/chat)、[工具调用](https://docs.ollama.com/capabilities/tool-calling)、[结构化输出](https://docs.ollama.com/capabilities/structured-outputs)：非流式、tools、format 与回复字段。
- [Ollama API 类型](https://github.com/ollama/ollama/blob/main/api/types.go)：选项/工具参数形态。
- [vLLM OpenAI 兼容 Chat 协议](https://github.com/vllm-project/vllm/blob/main/vllm/entrypoints/openai/chat_completion/protocol.py)：兼容服务的消息、choices、finish_reason 和输出格式；服务能力以实际配置和后续实测为准。
