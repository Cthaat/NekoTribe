# 2026-10-28 公开用户资料原生切片

三后端提供 `GET /api/v2/users/{id}`：验证访问会话，按查看者和目标用户查询公开资料，返回关系、在线状态及头像；Rust 和 Go 使用原生 Oracle 查询。隐藏在线状态时不返回最后活动时间，返回模型不包含邮箱、电话、生日或认证信息。Nuxt 增加安全错误边界和私有响应缓存控制，并绕过公开用户资料的内部响应缓存。非十进制、前导零、小数及超过安全整数范围的 ID 从原有宽松 `Number()` 解析改为 400；普通正整数不变。

共同需求及 21 个合成场景见 `specifications/requirements/user-public-profile.md` 和 `specifications/scenarios/user-public-profile.json`。隔离 HTTP 测试覆盖三端认证、目标与查看者、拒绝和资料缺失；Nuxt 真实映射函数、Rust/Go 数据库替身核对 SQL 绑定和隐藏状态。Go 全套 test/vet 通过，Nuxt 全套 508 通过、2 跳过。未运行真实 Oracle/Redis、客户端或跨机测试；更新时间、数据库时区、用户名/头像的非常规数据、URL 编码边界以及屏蔽关系的产品政策仍需验证。不会以隔离测试标记三后端共同验收。

本轮继续使用默认共享模式绕过 Nuxt 两层结果缓存。此前缓存保护的 Windows Nuxt 生产构建 `yarn build --dotenv .env.example` 已成功，构建输出确认 `NEKO_CACHE_MODE` 从运行时环境读取；这次公开资料增量尚未重新执行生产构建。
