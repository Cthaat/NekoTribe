# Go 通知 WebSocket 开发检查点

Go 原生 `/_ws` 已实现通知用户频道订阅、身份验证、来源校验、连接提示与 ping/pong。连接和事件投递前验证 JWT 与当前数据库会话；订阅失败返回不可用，不伪装成可接收通知的连接。通过共享 Redis 的用户频道接收已登记通知事件，限制消息大小和队列；断开或服务关闭时释放订阅。Redis URL、主机、端口、数据库与密码由显式环境配置，浏览器跨域来源须允许。

隔离测试使用真实回环 WebSocket 和本地模拟 Redis 协议服务，覆盖登录凭证、非法来源、同源 Cookie、用户频道、心跳、撤销后拒绝投递、订阅关闭和配置错误脱敏；Go 全量 test/vet 与 Linux amd64 静态构建通过。Rust 尚未实现通知连接；Go 的群聊、私信和在线状态也未实现。Nuxt 现有连接建立后尚需对齐事件投递前的会话复核。真实 Oracle/Redis 7、TLS、ACL、反向代理、多机器和两客户端仍待隔离验收；未启动 Docker 或访问日常数据。

实现使用 [coder/websocket](https://pkg.go.dev/github.com/coder/websocket)；通知连接的部分实现不能视作完整 `/_ws` 协议验收。
