# NekoTribe 多框架工作区

| 目录 | 分支 | 用途 |
| --- | --- | --- |
| nuxt | master | 主项目，Nuxt 前端和 Nitro 后端 |
| rust | Rust | Rust 业务兼容入口，目前依赖 Nuxt 上游 |
| flutter | Flutter | Flutter 客户端 |
| go | codex/go | Go 预留，尚无运行服务 |

可分别用编辑器打开四个目录，或打开 `NekoTribe.code-workspace`。根目录是管理目录；在各子目录执行 Git 命令。四个 worktree 共用 `nuxt/.git`，不要单独移动或删除其 Git 元数据。

本套件包含源码与历史，不包含依赖、生产构建、私有配置、数据库或上传数据。恢复成功仅表示源码工作区已建立。新机器先按 [Windows/Linux 部署手册](nuxt/docs/deployment.md) 准备依赖、环境和地址，再选择本地、混合、完整 Docker 或外部依赖方式启动。

Nuxt 需要 Node 22.12 以上的 Node 22 和 Yarn 1.22.22。进入 `nuxt` 安装锁定依赖，复制 `.env.example` 为本机私有 `.env` 并填写真实目标配置，使用 `yarn build --dotenv .env.example` 构建，再运行 `yarn start`。Windows 也可使用 `start.cmd` / `dev.cmd`，Linux 使用 `sh scripts/start.sh` / `sh scripts/dev.sh`。启动入口不会自动重置数据库；已有库只能使用显式增量迁移。

Flutter 通过 API/WS/文件三个根地址配置切换。Rust 当前没有 `/_ws` 路由；直接使用 Rust API 时 WS 另指 Nuxt，或配置共同网关获得单一公共入口。共同规范与校验命令见 [地址及接口约定](nuxt/doc/runtime-addresses.md)。Go 按后续任务逐步实现，不提供占位假服务。

origin 暂指向恢复套件中的 bundle。本地新提交尚未自动发布到远程；需要协作时自行明确设置真实远程地址。进度见 [实施计划](docs/plans/2026-09-08-workspace-reorganization.md) 和 Nuxt `docs/audits`。Oracle 19c 与另一台真实机器的验收状态以对应记录为准。
