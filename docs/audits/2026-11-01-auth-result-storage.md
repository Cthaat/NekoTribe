# 登录输入、响应和持久化边界检查点

2026-11-01。延续登录审查，仍仅静态开发和隔离测试。

Nuxt 登录表单取消额外的6字符门槛，保留非空校验，将已有短密码交给后端兼容规则验证；实际 SFC 的 schema 回归先失败再通过。Flutter 登录本来只要求非空，没有放宽服务端密码策略。

Flutter 新增严格成功/挑战解码：密码登录开关必须布尔；挑战需非空 challenge_id/account 和带时区可解析到期时间；成功需有效用户身份、完整会话/双令牌及到期时间。挑战完成共享成功解码，允许省略开关，但若存在只能 false。登录仓储在保存前再次校验 typed tokens，缺令牌不再静默 return；保存失败传播到调用方，挑战不改旧令牌。

TokenStore 之前先发布 _cached 再写持久化，失败后仍可能表现为新登录。现在先清缓存并删除 sessionId 标记，写令牌/到期数据，最后写 sessionId 并发布缓存；没有新到期值时删除旧值。隔离故障注入验证顺序写入在 access/refresh/session 写入前失败时，同实例和新实例都不读取混合令牌。该改动不是平台事务，也没有声称跨进程或并发写入原子性。

验证：Flutter auth_result/auth_screens/api_contract/api_client 四文件69项通过；Nuxt 实际 SFC schema/回调3项通过，typecheck exit0。Flutter analyze 初次发现测试替身 if 缺大括号，修正后重新检查。contracts/parity 一致，AUTH-LOGIN revision6，三后端和两客户端目标版本同步；共同需求副本同步 Rust/Go/Flutter。没有重跑或重编译未改动的 Rust/Go 服务。

仍需：并发 token replacement/refresh/logout 的协调与旧会话失效、存储“写入成功但返回错误”的不确定结果、实际设备 secure storage、Nuxt 完整响应/HttpOnly Cookie/浏览器流程、挑战过期/恢复码/设备信任、三后端真实六组合。日期校验目前验证带时区可解析格式，不是完整日历规范/模型健康验证；用户资料非身份字段仍沿用既有映射。两客户端和整个 AUTH-LOGIN 保持 in-progress、无真实验收 receipt，accepted=0/ready=false。

测试中的存储、网络和用户对象为合成数据，不访问真实密钥、数据库或模型；没有启动 Docker。
