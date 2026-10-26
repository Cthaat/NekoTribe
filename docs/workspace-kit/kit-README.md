# NekoTribe Windows / Linux 源码恢复套件

解压到本机，准备 Git 和 Node 22。恢复到**不存在的新目录**，其父目录须已存在：

```text
node restore-workspace.mjs ../NekoTribe
```

Windows 可运行 `restore.cmd 新目录`，Linux 可运行 `sh restore.sh 新目录`。不指定目录时，在套件内新建 `NekoTribe`。已有目录、文件或符号链接均拒绝覆盖；失败现场保留，不自动删除。

恢复器会验证 bundle SHA-256、四个分支提交、完整历史及离线接口契约，然后生成 nuxt/rust/flutter/go 四个工作区和编辑器工作区文件。源快照见 `manifest.json`，本套件实际恢复验证见 `verification.json`。

它不安装框架、不启动 Docker、不初始化数据库、不读取旧机器配置，也不发布 Git 提交。恢复后进入新工作区，按根 README 和 Nuxt 部署手册配置和启动。源码与历史均在 bundle；私有配置、依赖、构建、数据库和上传文件没有随工作树打包，Git 历史中已跟踪的文件仍随历史保留。

恢复目标应直接选最终使用位置。生成后四个目录共用 Nuxt Git 元数据，不要再单独搬走 linked worktree。原始 bundle 可另外留存备份。
