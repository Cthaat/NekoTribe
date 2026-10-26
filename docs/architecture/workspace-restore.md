# 四目录源码恢复入口

这是已确认的跨机器交付方案的恢复层：使用一个 Git bundle 保留共同历史，恢复 `nuxt/master`、`rust/Rust`、`flutter/Flutter`、`go/codex/go`，避免复制失效的 linked worktree。它不安装框架、不启动服务、不读取私有配置或迁移运行数据。

套件根目录包含 `restore-workspace.mjs`、`manifest.json`、manifest 指定的 bundle，以及 `management/README.md`、`management/NekoTribe.code-workspace`、`management/docs/plans/2026-09-08-workspace-reorganization.md`。manifest 固定 schemaVersion 1，记录 bundle 文件名、SHA-256 和四个源分支的精确提交。

运行 `node restore-workspace.mjs [新的目标目录]`。默认创建套件内的 NekoTribe 子目录；目标父目录须已存在。任何已有文件、目录或符号链接均拒绝覆盖，Git/哈希/来源验证失败时不启动应用。恢复中途失败会保留现场，不自动递归删除。

步骤为：检查目标与 Git、流式校验 SHA-256、核对 bundle 四分支头、原子创建新目标、克隆 Nuxt、建立另外三个 worktree、核对各 HEAD、在新仓库执行 bundle verify、复制三份明确的管理文件、从 Nuxt 目录运行离线契约检查。所有 Git 参数均通过参数数组传递，不经过 shell 拼接。

恢复出的 origin 仍指向套件 bundle。本地尚未发布的提交不会因此上传到 GitHub；后续协作由使用者明确配置真实远程。四个目录共享 Nuxt 的 Git 元数据，恢复后不要单独搬走其中一项。Windows/Linux 启动、依赖、端口、迁移与部署仍遵照部署手册。
