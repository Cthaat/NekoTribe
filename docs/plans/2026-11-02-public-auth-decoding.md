# 公开认证响应解码

目标：在两客户端实际API边界拒绝无效OTP/校验/注册data，沿用既有日期和身份校验，不引入依赖或真实服务。

OTP创建要求非空字符串account/verification_id和带时区有效expires_at；验证要求account、verified字面true和有效verified_at。两者account必须匹配捕获请求的trim后账号，不能读取await后变更的form。注册要求安全正整数user_id、非空username/email，且与捕获请求的trim后username/email相同；不要求登录token，也不新增会话写入。可兼容未知附加字段，不因客户端时钟拒绝过去的合法日期。

以完整合法profile基准和显式路径变更构造共享JSON样例；Nuxt实际auth service、Flutter实际AuthApi+ApiClient+Dio隔离adapter消费同文件。先运行失败样例，再接入纯decoder及API方法，验证原输入/输出映射和错误不含原响应。完整profile其他字段与HTTP envelope、Cookie及真实服务验收仍另有任务。

完成相关测试、typecheck/analyze、contracts/parity，共享需求/场景SHA与依赖功能版本同步，更新当前接手状态。下一步仍包含安全页OTP/失败退出、Flutter重置条件清理及共同输入/服务端策略；不能把本步作为整组完成。

检查点：46项共同样例两端通过，Node209项、Flutter191项相关测试及typecheck/analyze/contracts/parity通过。见 [审计](../audits/2026-11-02-public-auth-decoding.md)。下一步从Flutter重置条件清理与安全页消费者继续。
