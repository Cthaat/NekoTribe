# 模型工具调用历史 v1

此能力是三后端内部非流式推理传输的增量，不执行工具、不建立知识库、不代表 Agent 或真实模型验收。已有 55 项传输行为继续有效；新的 `AI-TOOL-HISTORY` 公共样例验证调用与结果的序列化和拒绝条件。

- 原 `{role,content}` 的 system/user/assistant 文本消息保持不变。工具提议使用 `{role:"assistant",content:string,toolCalls:[{id,name,arguments}]}`，调用数量 1..32；ID 为非空 Unicode scalar 字符串、最多 128 个 Unicode 字符，同一批唯一；name 遵循既有工具名称格式，arguments 必须为 JSON object，且符合原有深度/大小/Unicode 约束。
- 后续每项结果为 `{role:"tool",content:string,toolCallId:string}`，必须按调用列表顺序各出现一次，完成整批后才能出现其他消息或结束请求。禁止孤立、缺失、重复、未知或错序的结果；相同 ID 可以在已完成的后续批次重新出现，以兼容 Ollama 每轮生成的临时 ID。历史工具名允许不在当前启用工具列表，以便恢复已停用技能的历史；这不赋予调用或执行权限。
- 转换为 OpenAI 兼容 Chat Completions 的 `assistant.tool_calls`（function arguments 为 JSON 字符串）和 `tool.tool_call_id`；Ollama 使用 `assistant.tool_calls` 的对象参数及序号、`tool.tool_name`。按原顺序输出结果，以支持同批多次调用同名工具。工具返回文本仍是不可信数据，不能覆盖系统指令或直接触发新工具。
- 存在工具历史或当前工具声明时，所选模型配置必须声明 `tools` capability；不支持的模型在发网络请求前返回 `UNSUPPORTED_CAPABILITY`。无工具历史的普通对话与既有行为一致。能力配置不证明真实模型支持，真实服务仍须联测。
- 输入有未知字段、异常调用 ID、非对象参数、无结果或有未完成批次时返回 `INVALID_REQUEST`，不调用凭据解析器或网络；原 128 消息、32 工具、1 MiB 和 JSON 深度限制继续生效。工具提议与结果由更高层负责权限验证、参数校验、调用限制和人工确认；传输层不能自动执行提议。

协议对照：[Ollama 工具调用](https://docs.ollama.com/capabilities/tool-calling)、[OpenAI 函数调用](https://developers.openai.com/api/docs/guides/function-calling)。共同样例和本机 loopback 测试不代替真实模型的多轮兼容、授权、并发、取消或性能验收。
