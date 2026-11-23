# SentimentFlow 只读协同

三后端可以配置独立的 SentimentFlow 推理地址。`AI_SENTIMENTFLOW_ENABLED=1` 启用，`AI_SENTIMENTFLOW_URL` 为运维设置的完整预测地址，例如部署中的 `/predict/`。如上游要求认证，可配置 `AI_SENTIMENTFLOW_TOKEN`。客户端与模型都不能指定地址或凭据。

适配器调用既有预测接口，对每条样本发送 `POST {text,model:"lstm",return_probabilities:false,include_metadata:false}`。在返回数据中读取 `prediction.label` 和 `prediction.confidence`，兼容旧版顶层 `label`、`score` 与 `confidence`。支持原服务六级标签和 `positive`、`neutral`、`negative`，统一归并为这三类。旧版缺少标签时，以整数分值 0–5 分别归并为负、负、负、中、正、正。每个预测最多读取 16 KiB 响应。每批最多八条及 1.2 秒总超时，拒绝重定向。连续三批失败后，30 秒内快速降级。禁用、超时、网络失败、无效响应与熔断均省略附加信号，保留业务流程。旧 `/api/v2/integrations/sentiment-flow/*` 响应保持退役协议。

已授权的公开群运营 Skill 在启用插件时提供可选只读工具 `community_sentiment_summary`，只接受空对象。群 ID、当前窗口与选定的检索词从会话运行时取得。使用既有公开群证据查询，从当前窗口及其紧邻的等长上一个窗口各取前四条可见样本。工具向模型返回 `status:"available"`、`current`、`previous` 以及 `negative_share_change`。两个窗口的对象各含 `window_start`、`window_end`、`sample_size` 和三类计数。对比值为负面占比之差，任一窗口无样本时为 null。插件失败时返回 `{status:"unavailable"}`。模型应把统计说明为样本趋势。会话只有实际取得样本统计时记录工具名和 `sentiment_source_digest`。摘要来源校验和是 `sha256(groupEvidenceDigest(current) + "\n" + groupEvidenceDigest(previous))`，两个证据对象先将 examples 限为四条。保存和历史读取复核这两份资料，历史复核无需推理服务。使用样本统计的草稿在保存复核通过后交付正文。

审核人员可在 `GET /api/v2/moderation/content` 请求 `sentiment_signal=1`。当前分页最多八条当前可见的公开帖子可获得独立信号 `{label,confidence}`，并维持原分页、排序和权限。该信号用于人工浏览和复核。私密目标、空正文和不可用插件省略该字段。Nuxt Web 与 Flutter 显示该信号以及群运营草稿中成功取得统计的工具。
