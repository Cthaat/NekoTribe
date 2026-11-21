# Flutter HTTP 刷新与请求身份检查点

2026-11-01。ApiClient 的受保护请求在发送前记录并核对 TokenStore 意图版本；401恢复、刷新Future、条件凭据写入、失败清理均绑定原版本。不同版本不能共用旧刷新Future；每个原请求最多重试一次，第二次401终止并仅清理仍匹配的会话。迟到的受保护非401响应在会话变化后取消，避免将旧用户数据交给新用户。重试的Dio异常按实际异常传递，不因普通重试网络失败再次清理已刷新的凭据。

退出回调只在清理版本仍有效时调用；providers 中回调等待实时断开后再次核对版本，才清空徽标/标记退出。此处不声称实时连接建立/断开的完整竞态已通过测试。

先用可控异步Dio响应复现四个失败：旧401触发新会话刷新，迟到刷新成功覆盖新会话，迟到刷新失败清理新会话，多次401导致继续重试。修复后还验证并发请求共享刷新、Dio错误分支保护。另单独复现旧私有200响应仍交付数据的问题，修复后取消该响应。

Flutter 四文件 auth_result/auth_screens/api_contract/api_client 共81项通过；analyze 无问题。contracts/parity check 通过；登录 revision8、刷新 revision3，三后端与两客户端目标版本同步；共同 auth-login/auth-refresh 需求副本同步 Rust/Go/Flutter。刷新功能已登记 required，Nuxt Web 与 Flutter 均 in-progress；Nuxt 的 useApi/store 有实现，但客户端测试仍未登记，不能据此算验收。当前 required=5、unreviewed=150、accepted=0、ready=false。

测试使用替身验证请求/响应和凭据效果，不访问真实账号、服务或存储。没有修改或编译 Rust/Go 运行源码，没有启动 Docker。未跑真实浏览器、实际设备、多后端矩阵或真实WS。

## 下一步

自动刷新仍沿用旧的响应字段回退：可能用旧token/session/expiry补齐缺失字段，日期只 tryParse，须接下来严格核对完整刷新响应与同session约束，按契约拒绝错误数据。Nuxt Web 的刷新并发、Cookie/身份绑定、失败处理和浏览器用例也尚未补齐。还需实际平台存储不确定结果、跨实例/页签同步、实时状态切换，以及完整业务/AI与部署路线；本检查点不代表完整认证或工程目标完成。
