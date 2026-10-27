# 原生会话撤销与独立运行入口

承接总体 P2/P3。上一切片已提交统一模型传输，但原生业务服务/鉴权尚缺；本次推进真实 HTTP → token → Oracle 条件更新 → 撤销的完整路径，保留全认证/业务/AI目标，不把两条端点当完整后端。

1. 从实际 Nuxt 路由、middleware、Oracle/缓存包装还原撤销契约，纠正历史缓存观察，形成共同场景和测试数据。
2. Go建立可编译、可注入测试仓储的实际服务入口、固定官方Oracle驱动和生产仓储，路由只实现本切片；Rust新增明确native模式，接线同样两条原生端点，默认compat不变。未知能力不回退Nuxt。
3. Nuxt复用实际HTTP路径做参考测试；关闭session列表响应缓存、收口middleware close失败，更新opaque session id的错误OpenAPI类型；不顺便变更列表到期筛选、分页、日期或用户状态规则。
4. 三端共享合成场景；分别验证生产SQL/bind、关闭/错误、CORS、Cookie、自身撤销后失效与native上游零访问。按先失败后通过实施，独立规范/质量审查。
5. 更新源基线、公共副本、撤销功能的三端状态/任务；用单一 `AUTH-SESSION-REVOCATION` 覆盖两条操作，共用一份完整场景，旧登记ID保留supersedes。Node全套/类型、Go测试/vet/Windows与Linux编译、Rust WSL测试/格式、契约检查。保留真实Oracle/Redis/应用/模型/Docker测试到集中阶段。
6. 分别提交固定分支、更新部署/启动说明与检查记录。后续继续登录/刷新/会话列表/完整业务和AI产品；本切片不改成只交付撤销接口的缩小目标。
