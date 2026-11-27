# AI 写作接口开发配置

Nuxt、Go、Rust 均提供写作对话生成。写作与知识问答、群运营和审核共用模型配置。真实模型与 Oracle 的联调留待统一验收。

需要运行时切换时，把配置保存为 JSON 文件并设置 `AI_MODEL_CONFIG_FILE`。部署手册提供预检、发布、回退与容器挂载的步骤。固定配置也可通过 `AI_MODEL_CONFIG_JSON` 注入进程。将示例中的模型名替换为推理服务已安装的模型。 [模型热切换部署](deployment.md#ai-模型热切换)

```json
{"schemaVersion":1,"revision":1,"providers":[{"id":"local","adapter":"ollama","baseUrl":"http://127.0.0.1:11434"}],"models":[{"id":"local-model","providerId":"local","model":"replace-with-installed-model","modelVersion":"local-build-1","capabilities":["tools","structured-output"],"contextWindowTokens":4096,"maxOutputTokens":512}],"bindings":{"knowledge":"local-model","writing":"local-model","agent":"local-model","moderation":"local-model"}}
```

能力字段是配置声明，须通过真实模型验证，示例不代表模型已支持工具或结构化输出。可将 provider 的 adapter 配置为 `openai-compatible` 并配置对应服务地址；需要密钥时仅设置 `apiKeyEnv` 为服务端环境变量名称，再向进程提供该变量。不要把实际密钥写进 JSON、客户端或代码仓库。更换模型需要修改受控服务端配置并增加 revision；在途请求使用已选的配置快照。切换生效及模型能力仍需实测。

登录后先通过 `POST /api/v2/ai/conversations` 创建 `purpose=writing` 会话，再通过该会话的 `messages` 接口追加用户消息，最后调用 `POST /api/v2/ai/conversations/{id}/generate`。生成成功返回助手消息 ID 和序号，客户端可通过消息历史读取正文。生成期间会释放数据库连接；若有新消息改变会话，写入返回冲突，避免把旧上下文的回复接到新消息后。该接口不执行工具、不检索知识库，也不发布内容；输出仅为待用户审阅的草稿。

Flutter 已有写作页面，从首页按钮进入；使用当前配置的后端地址，支持提交、查看草稿、刷新状态、重新生成、确认删除及从历史列表恢复写作会话。消息提交结果不确定时要求先刷新，避免客户端自动重发；删除结果不确定时不假定删除成功。历史列表按 UUID 分页，跨设备恢复及三套真实后端的端到端验收仍待完成。

Nuxt Web 新增侧边栏「写作助手」入口，支持相同的写作对话、分页历史、恢复和删除确认，使用现有后端地址配置和登录会话。客户端使用隔离契约与状态测试；浏览器、真实模型、Oracle 和多后端端到端验证仍待完成。

Nuxt Web 和 Flutter 的写作页面提供起草、润色、标签建议和讨论总结。起草按原样提交用户输入。其他模式在用户点击发送后，将该模式的指令与用户输入一起保存为同一条写作消息。消息上限包括指令，失败重试沿用已保存的消息。讨论总结使用用户粘贴的讨论文本，客户端不会主动读取帖子或群聊。

> **vNext 增量补充（已合入源码）**：当前写作生成已支持 SSE 流式增量返回、个人 OpenAI-compatible 提供方配置（`/account/ai-provider`，需配置 `AI_USER_PROVIDER_SECRET_B64` 等，见 [个人 AI 服务连接](deployment.md#个人-ai-服务连接)）、以及声明 `vision` 能力时的图片描述接口 `POST /api/v2/ai/media/describe`；同时服务端生成前会校验受控 Skill `writing-draft` 已发布并启用（见 [Skill 启用配置维护](ai-skill-maintenance.md)）。
