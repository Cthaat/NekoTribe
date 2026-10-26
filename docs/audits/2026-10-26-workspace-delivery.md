# 四目录恢复套件交付记录

此快照完成本机 Windows / Linux 恢复入口验证，不代表另一台实际服务器已部署。核心运行、数据隔离和未测范围见 [集中验收](2026-10-26-runtime-verification.md)。

| 项目 | 值 |
| --- | --- |
| 套件 | `NekoTribe-2026-10-26-workspace.zip` |
| 字节数 | 113058164 |
| ZIP SHA-256 | `962d41a34848e185e2c8f1506ba37d360b2ca0ef723080e7a2fe426dce61c4e8` |
| bundle | `NekoTribe-2026-10-26-verified.bundle` |
| bundle SHA-256 | `4dae5b5f775e0ddf495e36d9ae76d46bcf2796b924a92f4ff3e7cb7d600b9ff1` |
| Nuxt/master 快照 | `a848119aab52d7d7d08954e2564bcb74e9c24990` |
| Rust 快照 | `0261ffe3feb6b0e8b4ca317a44e189dfcac16dac` |
| Flutter 快照 | `448e2a519ea94d83e3cf11362244280c5f75174f` |
| Go 快照 | `f2a886623ce55b9d58aa9c976ce74e8be102abad` |

文件位于工作区父目录 `.workspace-exports`，旧导出保留。ZIP 共 10 个文件，包含源码 bundle、manifest、验证记录、恢复入口和三份管理文件；已重新读取 ZIP 内的 bundle 流并校验 SHA-256。没有复制工作树中的私有 env、依赖、构建和运行数据库；已提交的 Git 历史按快照保留。

Windows 实际执行 `restore.cmd` 恢复到含中文/空格的新目录，四工程根文件、离线契约、无私有 env/依赖及已有目标保护通过。Linux 在新的 Node 22 Alpine 容器以只读方式挂载套件，实际执行 `sh restore.sh`，同样验证中文/空格路径和已有目标保护；5 项恢复保护测试、四目录契约检查通过。

入口不会启动服务或初始化数据库。已有目标一律拒绝；损坏包、路径越界、缺少分支或提交不符在创建目标前拒绝。新机器按套件 README 先恢复，再配置本机环境，选择部署方式。origin 指向本地 bundle，未自动推送任何远程提交。

该发行快照在验证后保持不变；后续仅补充验收记录的提交不会冒称已在此 ZIP 中。套件自身包含 `manifest.json`、`verification.json` 和恢复 README，作为精确来源与验证范围的依据。
