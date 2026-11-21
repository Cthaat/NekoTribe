# 登录客户端范围审查与重复提交修复

2026-11-01。AUTH-LOGIN 客户端范围已从 unreviewed 改为 required，登记 Nuxt Web/Flutter 实际页面、API、状态/令牌存储与测试入口；两端保持 in-progress，未进行真实后端/数据库验收。

## 复现与修复

Flutter 登录页的键盘提交可在 busy 时再次调用网络层；双因素回调也可被先前持有的按钮 callback 重入。Nuxt 的 onValidSubmit / handleTwoFactorSubmit 同样缺少回调内部的 loading 检查。两个客户端都仅在按钮层限制用户操作，不能保证一个在途提交。

两端四个回调增加内部 guard，保留 finally 清除状态和用户主动重试；不自动重放网络结果未知的登录或可能已消费的挑战，不提供服务端幂等性保证。

Flutter 新增两个 widget 测试先观察到每次调用2次而非1次；修复后 auth_screens_test.dart 共6项通过。Nuxt 测试从实际 SFC 的 script AST 提取两个回调，隔离网络/UI边界，先复现两次请求，再验证修复后一次请求和显式重试；2项通过。这些测试不验证完整模板/路由、真实会话或模型服务。

Nuxt typecheck exit 0；Flutter analyze 无问题/exit 0；contracts/parity check 通过。AUTH-LOGIN revision 4→5，三个后端 targetRevision 与两个客户端均更新为5；共同需求 auth-login.md 的新增客户端边界同步 Rust/Go/Flutter。没有修改三后端登录语义或运行源码，未重编译 Rust/Go。

## 已核实的剩余缺口

- Nuxt 登录表单要求密码至少6字符，但当前后端兼容需求没有登录密码最小长度；Flutter 只检查非空。应审查并统一，不能锁住已有合法短密码账号。
- Flutter AuthRepository._persistTokens 在 token 缺失时直接 return，调用方仍可将结果视为登录成功；parseLoginResult 也使用宽松转换。需要严格的成功/挑战响应校验、持久化失败测试和错误恢复；本轮未修复这一层。
- Flutter 双因素输入用数字键盘，但后端还支持恢复码；设备指纹/信任、挑战过期/重载恢复、认证状态与实时连接、跨后端令牌/撤销仍需深入审查及真实联测。
- Nuxt 尚缺完整登录页面/浏览器用例，Flutter 原有 tests 主要覆盖注册/重置和布局；新增回调回归不能代表完整登录/2FA产品验收。

当前客户端范围 required=4、unreviewed=151；accepted=0、ready=false。下一步优先修复上述输入与登录结果/令牌持久化边界，再继续其他客户端范围和完整业务/AI路线。没有启动 Docker/真实依赖，没有提交或覆盖此前改动。
