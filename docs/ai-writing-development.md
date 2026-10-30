# AI 写作接口开发配置

当前仅 Nuxt 实现写作对话生成；Rust、Go 还需实现同一接口。模型和 Oracle 的真实联调、知识库、Skills、群运营和审核助手均未完成。本页不代表生产部署验收。

由服务端运维人员向 Nuxt 进程注入 `AI_MODEL_CONFIG_JSON`。示例为单行 JSON（将模型名替换成推理服务已安装的模型）：

```json
{"schemaVersion":1,"revision":1,"providers":[{"id":"local","adapter":"ollama","baseUrl":"http://127.0.0.1:11434"}],"models":[{"id":"local-model","providerId":"local","model":"replace-with-installed-model","capabilities":["tools","structured-output"],"contextWindowTokens":4096,"maxOutputTokens":512}],"bindings":{"knowledge":"local-model","writing":"local-model","agent":"local-model","moderation":"local-model"}}
```

能力字段是配置声明，须通过真实模型验证，示例不代表模型已支持工具或结构化输出。可将 provider 的 adapter 配置为 `openai-compatible` 并配置对应服务地址；需要密钥时仅设置 `apiKeyEnv` 为服务端环境变量名称，再向进程提供该变量。不要把实际密钥写进 JSON、客户端或代码仓库。更换模型需要修改受控服务端配置并增加 revision；在途请求使用已选的配置快照。切换生效及模型能力仍需实测。

登录后先通过 `POST /api/v2/ai/conversations` 创建 `purpose=writing` 会话，再通过该会话的 `messages` 接口追加用户消息，最后调用 `POST /api/v2/ai/conversations/{id}/generate`。生成成功返回助手消息 ID 和序号，客户端可通过消息历史读取正文。生成期间会释放数据库连接；若有新消息改变会话，写入返回冲突，避免把旧上下文的回复接到新消息后。该接口不执行工具、不检索知识库，也不发布内容；输出仅为待用户审阅的草稿。
