# 个人 AI 服务连接

登录用户可在账户设置保存一个 OpenAI-compatible 连接，用于本人 AI 写作。可以选择默认地址 `https://api.openai.com/v1`，或部署管理员通过 `AI_USER_PROVIDER_URL` 提供的地址。应用端只提交预设 ID、模型 ID、启用状态与用户自己的 API 密钥。两端显示当前预设 URL，并提供保存、试连与移除。现有写作 Skill 权限、账号及服务配额、生成与保存流程共同生效。

| 操作 | 结果 |
| --- | --- |
| `GET /api/v2/users/me/ai-provider` | 读取功能是否可用、当前预设列表与本人连接元数据 |
| `PUT /api/v2/users/me/ai-provider` | 保存 `{preset, model, enabled, api_key?}` 后返回与 GET 一致的数据 |
| `POST /api/v2/users/me/ai-provider/test` | 对已保存连接读取 `GET {base_url}/models`，检查所选模型 ID，成功返回 `{verified:true}` |
| `DELETE /api/v2/users/me/ai-provider` | 移除本人连接，返回 null，可重复操作 |

GET 和 PUT 数据为 `{setup_available,presets,config}`。预设对象含 `id` 和 `base_url`。连接对象含 `preset, model, enabled, key_configured, revision, reconnect_required`，无记录时为 null。返回值、日志、导出和审计记录均省略密钥及密文。更换预设或现有预设地址变化时必须重新填写密钥。省略密钥只保留同一预设和地址的旧凭据。任意输入 URL 不属于请求契约。试连接在四秒内完成，限 1 MiB 响应正文，拒绝重定向。对外统一返回脱敏错误。测试可用于已保存但尚未启用的连接。[模型列表 API](https://developers.openai.com/api/reference/resources/models/methods/list/)

部署侧通过同一个 `AI_USER_PROVIDER_SECRET_B64` 为三后端开启功能。它是标准 base64 编码的 32 字节共享加密密钥。保留配置需要保留此值。Oracle 只存标准 base64url 无填充编码的 `nonce || ciphertext || tag`，采用 AES-256-GCM，随机 12 字节 nonce 与 16 字节 tag。附加认证数据是以下内容的 UTF-8 编码，字段间用换行相连。

```text
nekotribe.ai-provider.v1
<decimal owner user ID>
<default or provided>
<saved normalized base URL>
```

预设 URL 使用 HTTP(S)，排除用户信息、查询串、片段、内部空白和反斜杠。归一化移除首尾空白和末尾斜杠，保留其余 ASCII 拼写及显式端口。保存时绑定这个地址。试连及推理只向仍与保存记录匹配的预设发送密钥。写作使用已启用且可解密的连接，有权限的其它 AI 用途沿用平台配置。个人写作回复保存配置代数，模型档案 ID 为 `personal-writing`。未设置共享部署密钥时，普通写作沿用平台配置。连接启用后遇到地址变化或解密错误时，写作返回脱敏服务不可用，以便用户重新连接。可用性将已启用且可解密的个人写作连接计入写作推理。

通过 Nuxt 显式迁移创建 `n_ai_user_providers`。凭据保存先锁定当前用户行，对同一用户逐次递增配置代数。删除账号时由关联约束清理配置。三个后端共享加密格式和 Oracle 数据。
