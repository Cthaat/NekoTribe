# 两客户端安全动作成功响应解码

继续已授权的统一接口及客户端开发，复用改邮箱的完整响应边界模式。当前2FA和注销仍有类型断言/Map回退，坏响应可能显示密钥、误判启用/关闭或进入注销成功路径。

设计：建立共同成功响应向量与需求；四类操作均校验code数字200、非空message、必有meta(null或对象)、meta.has_next布尔/空、data对象，error字段若存在只能false。保留未知附加字段以允许兼容扩展。setup密钥必须32位Base32，OTP URI须为同secret的NekoTribe TOTP/SHA1/6位/30秒；解析后验证必需查询键不重复，拒绝坏编码/其他协议/片段/空账号。confirm须enabled字面true与10个5-5-5 Base32恢复码，disable须enabled字面false，注销须deleted字面true和正安全整数user_id。错误用固定文本，不包含响应密钥或URL。

复用现有API传输与身份/401/认证队列策略。Nuxt在v2Request完整envelope上解码；Flutter在ApiClient成功envelope回调和数据工厂解码，API→仓储→页面使用不可变类型，取消宽松Map过滤回退。恢复码不增加去重承诺，三后端当前随机生成没有唯一性保证；不借本步改动事务/密码学或真实数据。

- [x] 生成共同向量并在两客户端真实API边界观察失败。
- [x] 实现严格解码与Flutter类型贯穿页面，更新原有合成测试数据为契约格式；重新setup前清除旧密钥/URI/码，失败不显示旧配置。
- [x] 完成相关回归、类型/静态检查、共同需求/OpenAPI/登记同步及交接记录。

已显示秘密在身份切换时即时清除仍是后续生命周期任务；本次先闭合响应边界。实际OTP应用、浏览器/跨标签页/设备存储、真实Oracle/六组合/部署留在总验收，整体仍in-progress。保持静态开发，不启动Docker、真实数据库、模型、SMTP，不提交或移动分支。

静态/隔离结果及范围见 [检查点](../audits/2026-11-02-security-response-decoding.md)。
