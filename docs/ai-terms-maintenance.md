# 平台规则版本维护

该命令维护共享 Oracle 中的规则目录版本标记；规则已接入开发中的精确检索，真实 Oracle 并发与完整问答仍未验收。源码工作区需要锁文件对应的开发依赖。Nuxt Dockerfile 会在构建阶段打包维护组件，并将入口和规则目录放入运行镜像；该镜像构建与执行仍需实际验收。

执行前使用显式迁移工具检查或创建 `ai-terms` 表，确认配置指向需要维护的数据库。迁移只建表，不发布规则。配置文件必须明确指定；进程环境变量优先于配置文件，与现有迁移工具一致。凭据只通过环境或配置文件提供，不放进命令参数。

在 Nuxt 根目录运行：

```text
node scripts/ai-public-terms-maintenance.mjs --plan
node scripts/ai-public-terms-maintenance.mjs --status --dotenv /path/to/config.env
node scripts/ai-public-terms-maintenance.mjs --publish --expected 0 --dotenv /path/to/config.env
node scripts/ai-public-terms-maintenance.mjs --disable --expected 1 --dotenv /path/to/config.env
```

`--plan` 默认离线，显示本地经过校验的目录摘要，不读取配置、不连接数据库。`--status` 只读，显示数据库中当前代数、启用状态和摘要，以及本地摘要；未初始化时显示 `initialized:false`。首次发布需确认未初始化并指定 `--expected 0`；后续发布或停用必须先读取当前代数，再将实际代数替换示例中的数字。执行成功后代数递增，停用不会删除目录或历史资料。

镜像中使用相同的 `node scripts/ai-public-terms-maintenance.mjs` 命令；连接操作需要在容器中显式提供可读取的配置文件，并保证容器内的数据库地址可达。勿把凭据写进镜像；不要假定宿主机的 `localhost` 在容器内指向同一服务。

并发维护时，期望代数过期会失败；首次并发插入也只允许一方成功。遇到 `TERMS_AUTHORITY_COMMIT_UNCERTAIN` 或连接关闭失败，不要立即重试：先运行 `--status` 读取实际状态，确认操作是否已提交，再决定下一步。数据库和驱动错误不会原样输出，以免暴露敏感信息。运行结果、真实并发和故障恢复仍需在隔离数据库验证。
