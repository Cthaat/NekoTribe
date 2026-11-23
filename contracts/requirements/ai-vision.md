# 图片描述与图文审核

发帖编辑器对已上传的 JPEG、PNG、WebP 图片提供描述和话题建议。编辑器沿用发帖可见性决定上传范围，保留已有的手动编辑、删除和发布流程。发起建议只传媒体 ID 和语言。后端只从配置的媒体存储读取目标对象，使用当前写作模型的 `vision` 能力和账号 AI 配额。请求和响应按会话隔离。

| 操作 | 输入 | 成功数据 |
| --- | --- | --- |
| `POST /api/v2/ai/media/describe` | `{media_id,locale}`，语言为 `zh` 或 `en` | `{media_id,alt_text,tags}`，描述为 1–500 UTF-8 字节，话题至多 5 个且不带 # |
| `PATCH /api/v2/media/{id}` | `{alt_text}`，0–500 UTF-8 字节 | `{media_id,alt_text}`，空描述保存为 null |

描述使用当前账号就绪的图片，允许公开上传和私密发帖上传。缺少权限、媒体或有效对象返回 404，超出受支持的类型、大小或不合法文本返回 400，未配置视觉模型或推理故障返回 503，超出配额返回 429。描述和话题在用户确认后回填。PATCH 仅允许上传者更新未被关联到帖子或聊天的图片，已关联返回 409。

输入字节由存储后端读取和核对。单张最多 4 MiB，同一推理最多 4 张且累计最多 8 MiB。媒体类型、字节数和文件签名须一致。OpenAI-compatible Chat Completions 的最后一条用户消息用文本和内联 base64 data URL，Ollama REST Chat 在同条消息使用 base64 `images` 数组。原有文本、流式与工具调用契约保留。发送到提供方的提示内容、图片字节及凭据不进入日志。[OpenAI](https://developers.openai.com/api/docs/guides/images-vision) · [Ollama](https://docs.ollama.com/capabilities/vision)

审核建议为公开可见的目标帖子加载就绪且使用公开存储的自有图片附件。评论和不可用的图片沿用文字分析。审核模型支持 `vision` 且至少读到一张符合限制的图片时纳入图文分析，包含仅有图片的目标帖子。历史回复返回可选 `analysis_mode` 字段，取值 `text_only` 或 `text_and_images`。既有历史未携带此字段，客户端按纯文本标注。

新的文字建议可沿用版本 1 存储。图文建议使用版本 2，在原有记录字段之外保存 `image_sources`，每项包含 `media_id` 与 `version`。版本是按 UTF-8 计算的 SHA-256，输入为 `media_id + "\n" + storage_key + "\n" + mime_type + "\n" + file_size`。已存储对象按既有媒体规则不可原位替换。图文建议提交和读取时复核记录中的每张图片仍属于该公开目标且版本未变。受保护媒体及不可见目标不会作为输入。
