# 一般设置页生命周期计划

本轮复用现有身份版本与严格设置响应，不新增认证协议。按TDD和incremental-implementation流程顺序执行；不启动真实依赖，不提交/切换已有分支。保持完整业务与AI目标。

1. [x] Nuxt增加一般设置动作回归：初次读取失败不允许保存，重复回调不重复请求，只发送变更字段，采用服务端快照，保存失败必须显式重读，旧身份/卸载响应无副作用。
2. [x] 拆出AccountSettingsPreferences.vue保持偏好状态独立；以现有authQueue版本实现AccountSessionGate.vue，换身份卸载旧组件、显式重开。SecurityPage留在存活父页面，保留账号操作后的导航责任。未知旧privacy可读取但不可作为新值提交；其他修改不顺带覆盖旧privacy。
3. [x] Flutter增加真实widget回归，采用AuthRepository会话通知与repository实例守卫；加载及保存互斥、失败后显式读取，隐藏过期设置。禁用保存中的远程控件，捕获owner与单调视图版本，旧控件回调不能写入重开后的会话；移除新输入followers，未知旧privacy显示兼容占位项。
4. [x] 两端不自动重放保存，结果不确定时不声称回滚成功。补中英文状态与窄屏检查；本地主题/语言不作为远程写入。
5. [x] 更新共同客户端需求与场景、settings GET/PATCH revision/两客户端targetRevision和任务。运行Nuxt动作/模板/认证相关回归及typecheck，Flutter相关widget/完整测试和analyze，contracts/parity及四工作树diff检查。
6. [x] 写审计与机器状态，更新最新接续入口和可粘贴提示词，capture后verify --check-only。整体保持accepted0/readyfalse；真实浏览器/设备/六组合和部署留待集中验收。
