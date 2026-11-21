# Flutter 本地凭据队列与登录意图版本

2026-11-01。继续 AUTH-LOGIN，局部开发与隔离验证；不启动 Docker/真实服务。

TokenStore 将 read/write/updateAccess/clear 放进同实例串行队列，失败操作的异常返回原调用方，但后续队列仍可执行。登录和挑战完成发起前获取递增意图版本；保存用 writeIfCurrent，在排队开始和持久化完成后都核对版本。写入中被新意图取代时先清缓存并撤销旧会话标记。退出发起即改变意图版本；网络返回后用 clearIfCurrent，避免较早退出清理较新登录。

新增测试先复现三项失败：退出后旧登录仍返回成功、较新登录不能阻止旧响应、清理与持久化交错留下会话。修复后还验证迟到退出保留新登录、条件写入中版本失效时撤销标记。共74项 Flutter auth_result/auth_screens/api_contract/api_client 测试通过；analyze 无问题。测试的存储和网络均为替身，不代表平台原子性或真实后端验收。

AUTH-LOGIN revision7，三后端与两客户端目标版本同步，共同需求副本同步 Rust/Go/Flutter。contracts/parity check 通过；四项客户端范围 required、151项 unreviewed，accepted=0、ready=false。没有修改或重编译 Rust/Go 运行源码，没有提交此前在途变更。

## 下一步必须接线的真实缺口

ApiClient 自动刷新仍调用无条件 write，401失败分支仍无条件 clear。需要把原请求身份/版本记录在请求上，刷新条件写入、失败条件清理、重试不得切换到另一个用户；刷新 Future 也应按版本区分，不能复用旧会话的刷新结果。这部分本轮没有改，不能宣称所有刷新/退出竞态都已解决。

TokenStore 的无条件 write/updateAccess 仅保证排队顺序，调用方若保存旧网络结果仍须显式使用版本条件接口。版本只在同一个 TokenStore 实例/进程有效；跨实例、多浏览器页签、实际 secure storage、持久化已成功但调用报错、存储删除失败、浏览器 Cookie 和跨三后端验收仍需后续实现/验证。仓储版本守卫不替代服务端撤销或挑战一次性消费。
