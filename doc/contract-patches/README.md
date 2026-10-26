# 本次字段审核的来源材料

这里保存 39 项接口字段审核和 PATCH 兼容改造的审计输入，不是另一套权威契约。日常开发只更新 `../v2.openapi.json`，通过 `scripts/contracts.mjs` 同步副本。

四个分组记录了审核时的完整 operation、来源路径及拟新增组件；后续迁移重构、错误封装和规范整理已继续修改权威文件。不要将这些历史补丁直接覆盖回权威规范。

`build-sentiment.py` 仅在显式提供 `--upstream-root` 时以 Python AST 读取上游源码并生成审计材料，不导入应用、不加载模型、不训练、不连接网络。快照对应 SentimentFlow 提交 `744b7a448588266f1c54b1d1db38e07ae7e0894e`；具体文件哈希在 JSON 中。上游 login、admin/users、stats/overview 的占位行为被如实记录，不能据此声称业务已完成。

最终审核记录见 `../../docs/audits/2026-10-25-contract-payloads/evidence.json`，当前模块边界见 `../../docs/architecture/shared-api.md`。
