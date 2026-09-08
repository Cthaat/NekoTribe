# Nuxt 启动与初始化安全基线（T06）

此入口默认连接已配置的 Oracle、Redis，不重启依赖、不重置数据库。完整启动/停止/日志管理属于 T14，Compose 项目名、卷和外部部署整理属于 T15。

## 配置与启动

使用 Node 22.12 或更新的 Node 22，以及项目锁文件对应的 Yarn。首次入口会以排他复制创建 `.env`，已有文件保持不变；权威样例为 `.env.example`，`.env.nuxt.example`、`env.example` 为内容一致的兼容副本。样例默认关闭 SentimentFlow，真实凭据需自行填写。

| 操作 | Windows PowerShell | Linux Shell |
| --- | --- | --- |
| 安装依赖并开发启动 | `./scripts/dev.ps1` | `sh scripts/dev.sh` |
| 显式启动 Compose Redis/Oracle 后开发 | `./scripts/dev.ps1 -Dependencies` | `sh scripts/dev.sh --dependencies` |
| 运行已构建应用 | `./scripts/start.ps1` | `sh scripts/start.sh` |
| 显式构建并启动 Compose 全栈 | `./scripts/start.ps1 -Compose` | `sh scripts/start.sh --compose` |

开发入口调用 `yarn install --frozen-lockfile` 和 `yarn dev`；构建产物入口调用 `yarn start`，请先 `yarn build`。所有子命令失败均中止。入口不自动安装 Node/Yarn，不自动开启 Corepack。自定义监听地址/端口可直接使用 `yarn dev --host 127.0.0.1 --port 31001`；样例 `APP_PORT` 是 Compose 映射端口。

显式 Compose 选项可能操作当前 Compose 项目的服务。执行前核对项目名、端口与数据卷；本轮验收不对原开发服务执行这些选项。

## 数据库初始化

`scripts/init-db.ps1` 与 `scripts/init-db.sh` 统一委托 `scripts/init-db.mjs`。它先读取 `.env`，再应用进程环境变量覆盖，使用 Node dotenv 解析器，不执行文件里的 shell 代码。

默认执行本机 SQLPlus，连接 `ORACLE_HOST`、`ORACLE_PORT`、`ORACLE_SYS_SERVICE_NAME`。使用容器内 SQLPlus 时必须显式设置 `ORACLE_CONTAINER_NAME`；不扫描或自动选择已有 `oracle19c` 容器。它不创建或启动数据库。

权威基线是 `data/neko_tribe-oracle-v2.sql`。当前脚本只支持其固定的 `ORCLPDB1`、`NEKO_APP`、`N_USERS`，以及 SQL 中固定的表空间路径和示例用户密码；这不是通用迁移器。外部环境应预先由管理员配置兼容 schema，不应直接运行该开发基线。

初始化判断：

1. 若已有 `NEKO_APP.N_USERS`，跳过整个基线。此标记仅防止重跑，**不代表所有 schema 对象完整**。
2. 若标记不存在，但任一基线用户或表空间存在，拒绝执行；部分初始化需要人工检查，不能自动 reset。
3. 查询失败、输出不可识别、目标不匹配时拒绝执行。
4. 只有确认空目标且显式配置 `DB_INIT_ALLOW_EMPTY=true`，才执行基线；同一 SQL 会话在基线前再次检查空目标。

例如，仅在确认独立空测试数据库后设置该变量，再运行 `./scripts/init-db.ps1` 或 `sh scripts/init-db.sh`。在 Compose 模式可显式执行 `docker compose run --rm -e DB_INIT_ALLOW_EMPTY=true db-init`。Compose 普通启动不会把此开关传给初始化服务，空库会等待人工显式初始化；已有标记的库仍正常跳过。

SQLPlus 通过 stdin 接收登录信息，密码不进入 argv；SQL 输出被捕获，失败时仅输出通用错误，避免失败 CONNECT 回显凭据。密码目前不支持双引号或换行。SQL 会话配置 SQL/OS 错误退出，Docker 复制/执行/清理退出码也会检查。无自动 reset、PDB OPEN 或 SAVE STATE 操作。

基线仍包含开发样例清理与创建语句，必须只用于新的隔离环境。SQL DDL 不能靠事务完整回滚：如果初始化中途失败，入口会报错并在下次拒绝有残留的目标，需管理员检查。

`reset-db.ps1` 保留原有 `RESET` / `-Force` 显式危险操作入口，默认启动和初始化不会调用它。目标 PDB 切换失败会立即中止，不能继续 DROP；本轮仅生成 SQL 检查保护逻辑，未执行 reset。

## 可重复验证

```powershell
node --test tests/startup-safety.test.mjs tests/startup-powershell-safety.test.mjs
$env:NEKO_TEST_SHELL_CONTAINER='true'
node --test tests/startup-shell-safety.test.mjs
```

Shell 测试只使用本地已有 `container-registry.oracle.com/os/oraclelinux:9-slim` 镜像；`--pull=never --network=none`，不挂载宿主目录，stdin 注入脚本与假 SQLPlus，容器退出即删除。覆盖已存在、残留、查询失败、未知响应、空库未授权、空库成功、基线失败和错误 PDB；Windows 分别使用 PowerShell 5.1 和 7 解析语法并单独生成 reset SQL，不执行入口。

这些测试证明控制流、错误退出与参数传递，不代替 Oracle 实际 SQL 验证、Linux 完整构建或业务联调。原开发 Oracle/Redis、上传存储均不作为测试目标。
