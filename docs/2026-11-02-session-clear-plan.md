# 会话清理完成凭据

> **历史阶段计划与检查点（2026-11-02）**：本文记录会话清理凭据切片的阶段性设计与静态回归检查点。现行入口见 [Flutter 分支文档说明](README.md) 与 [全项目文档总索引 (master)](https://github.com/Cthaat/NekoTribe/blob/master/docs/README.md)。

目标：密码重置成功/主动退出只清理本次原版本，保护较新登录的凭据、全局状态、路由与实时连接。当前仅静态实现/隔离回归，不启动真实依赖。

1. AuthRepository的重置在发起时捕获版本，API成功后条件清理；主动退出沿用既有发起即失效策略。返回含清理后版本的receipt，过期操作不能作为当前清理成功返回。失败不伪造服务端未提交；存储清理失败向上游传播，同时仅为仍属本次版本尝试全局退出收尾。
2. provider注入唯一按版本检查的清理回调，断开实时连接前后核对，重置未读与认证状态。receipt只在回调完成且仍匹配时有效。页面先捕获仓储，等待后只据当前receipt提示/导航，移除重复清理。旧失败不能显示到新身份。
3. AuthSessionController初始异步hydrate不得覆盖之后的明确登录/退出或已dispose状态。RealtimeService断开时先分离旧资源，关闭捕获资源，不读取await后可能属于新连接的字段；连接/回调使用代次与会话版本，旧open不能复活，旧回调不能操纵新连接。使用可注入channel工厂做隔离测试，默认仍为现有WebSocketChannel.connect。
4. 先补仓储/真实provider状态回归，再接UI及实时隔离回归，运行相关Flutter测试/analyze和工作区contracts/parity；同步需求/任务/最新接手。不宣称真实设备存储、Cookie、WebSocket传输或完整矩阵完成，安全页OTP及输入/服务端缺口仍需继续。

检查点：清理完成凭据、统一回调、调用方与状态/实时所有权已接入，Flutter主回归229项及实时定向3项通过（其中2项重叠），Node211项/typecheck/analyze/contracts/parity通过。详见根工作区 `nuxt/docs/audits/2026-11-02-session-clear.md`；继续安全页OTP及已列出的真实平台/服务端未完成项。
