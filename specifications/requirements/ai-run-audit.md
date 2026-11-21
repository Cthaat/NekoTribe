# AI 运行审计

Nuxt、Go、Rust 对通过首轮会话、权限和 Skill 检查的群运营草稿与审核建议，使用现有服务日志输出一条 `ai.run` 运行摘要。两个工作流沿用原有接口、错误响应和保存事务。

三个后端记录相同字段，原生日志的外层格式由各自部署方式决定。

| 字段 | 取值 |
| --- | --- |
| `event` / `version` | `ai.run` / `1` |
| `operation` | `group_draft`、`moderation_advice` |
| `stage` | `validation`、`configuration`、`quota`、`proposal`、`evidence`、`inference`、`persist` |
| `outcome` | `generated`、`insufficient_evidence`、`quota_exhausted`、`quota_unavailable`、`cancelled`、`failed` |
| `config_revision` | 本次固定的模型配置版本，配置尚未选定时为 `0` |
| `skill_generation` | 首轮检查时采用的 Skill 配置代数 |
| `skill_selection` | `explicit` 表示群草稿请求明确选择了技能，`purpose-default` 表示按会话用途选择 |
| `tool_count` | 通过参数校验、权限复核并取得资料的群工具数量，范围 0～2 |
| `elapsed_ms` | 首轮检查通过后至运行结束的单调时钟毫秒数 |

- `proposal` 表示第一次模型提议，`evidence` 表示工具资料与权限复核及处理，`inference` 表示生成阶段，`persist` 表示提交阶段。审核建议不经过模型工具提议和工具资料阶段。
- 提交阶段遇到连接中断时，以会话历史及数据库提交状态确认是否已有生成结果。`cancelled` 记录请求处理被取消；日志不能确认在途事务的最终状态。进程退出可能影响日志送达。
- 日志载荷只包含表中列出的字段。用户与群标识、会话、资料标识、提供方地址、凭据、模型原始错误及正文不进入事件。成功群草稿的实际工具名和引用仍通过受权限约束的会话历史提供。
- 部署环境按既有方式收集服务日志，并限制为具备运维权限的人员读取。Rust 可在默认 `info` 级别采集，若部署自定义 `RUST_LOG`，需覆盖 `nekotribe_backend::ai::run_audit`。
