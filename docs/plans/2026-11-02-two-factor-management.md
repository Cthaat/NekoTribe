# 三后端原生双因素管理计划

复用现有AES-256-GCM密钥格式、Base32/TOTP校验、bcrypt旧密码及恢复码模型，补齐setup/confirm/disable。行为以Nuxt为来源，同时共同修正逐条提交、重复confirm重建恢复码与并发旧密钥覆盖问题：每次管理写入单事务；setup不覆盖已启用密钥，confirm/disable按读取的密文/IV/tag条件更新，零行409；disable恢复码消费与关闭一起提交，零行401并回滚。

- [x] 共同合成HTTP场景覆盖输入、鉴权、schema、AES/TOTP/恢复码、失败/提交后报错；三个实际路由先观察失败。
- [x] Nuxt事务及安全错误；Go原生管理服务、AES封装和Oracle事务；Rust原生服务、复用登录密码学函数、repository/executor/Oracle事务。随机密钥20字节，恢复码10个且每个5-5-5 Base32；服务器只存哈希，响应不泄露加密材料。
- [x] 跑必要原生回归和真实事务适配器下的隔离测试，确认生成密钥/恢复码可被已有登录校验消费；更新OpenAPI、共同需求、三feature和接手状态。两客户端已有入口及归属守卫，完整响应解码和Cookie/并发另步继续。

setup校验当前密码和active账号后检查schema/既有启用状态；confirm规范化code再查schema/密钥，不存在422，已启用422；disable先验证当前密码，再要求code与已启用密钥，优先TOTP，否则规范化恢复码。readiness只读且不缓存成功，不自动迁移。登录/发挑战并发撤销、限流、模型/数据/部署仍在总计划，不据此缩小目标。

仅静态开发与隔离依赖，不启动Docker/真实Oracle/Redis/模型/SMTP，不操作真实账号/迁移/分支或提交。

勾选只表示本次静态/隔离步骤完成，真实OTP应用、数据库、完整客户端和部署尚未验收，详见 [检查点](../audits/2026-11-02-two-factor-management.md)。整体in-progress。
