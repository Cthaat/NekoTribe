# 一对一 WebRTC 音视频通话

私信与频道顶部的通话入口均发起一对一会话。频道入口先选择成员，再通过现有私信会话权限解析对端。仅当前有效且互未拉黑的私信参与者可提交或接收信令。音视频媒体由两端 WebRTC 传输。聊天后端只转发信令，不写 Oracle，也不记录 SDP、ICE、音视频和 TURN 密钥。

`GET /api/v2/calls/ice-servers` 需要有效会话，并返回 `{ice_servers,expires_at}` 和 `Cache-Control: private, no-store`。每个服务器含 `urls`，TURN 项另外含 `username` 和 `credential`。部署通过后端环境变量 `WEBRTC_STUN_URLS`、`WEBRTC_TURN_URLS` 设置逗号分隔的 URL。TURN 使用 `WEBRTC_TURN_SHARED_SECRET` 计算短期 coturn 凭据，用户名为 `<过期 Unix 秒>:<认证账号 ID>`，凭据为该用户名的 HMAC-SHA1 标准 Base64。共享密钥留在服务端。没有 TURN 时过期时间为 `null`，无配置时 ICE 列表为空。配置无效时返回 503。[coturn TURN REST API](https://github.com/coturn/coturn/blob/master/man/man1/turnserver.1)

客户端通过认证 `/_ws` 发送 `{type,data}`。所有请求的 `data` 都有 `call_id`、`conversation_id` 和 `client_id`。两个字符串 ID 采用小写 UUID 形状，`client_id` 区分同账号的客户端实例。会话 ID 为正安全整数。`call_invite` 另含 `mode: 'voice' | 'video'`。响铃状态接收 `call_accept`、`call_reject`、`call_cancel`。接听后主叫发送 `call_sdp_offer`，被叫发送 `call_sdp_answer`，两者另含 `sdp`。接听后两端可发送 `call_ice`，另含 `candidates`（最多 16 个 `{candidate,sdp_mid?,sdp_mline_index?}` 对象），并可发送 `call_hangup`。客户端先应用远端 SDP，再将此前收到的 ICE 候选提交给远端描述。[W3C WebRTC](https://www.w3.org/TR/webrtc/)

各节点复用同一份 Redis 原子状态脚本。同账号同时最多占用一个通话，邀请响铃 30 秒，接通状态最长 4 小时。接受、拒绝、取消、超时和断开释放或转换占用。接听绑定首个完成接受的客户端和 WebSocket 连接。主叫同样绑定发起连接。任一连接关闭时结束它所占用的通话。客户端还设有本地响铃超时，服务器中断时可以退出等待。Redis 不可用时向发起端返回 `call_unavailable`。

脚本的三个键依次为 `nt:{webrtc}:call:<call_id>`、`nt:{webrtc}:user:<actor_id>`、`nt:{webrtc}:user:<peer_id>`。参数依次为动作名、通话 ID、会话 ID、认证账号 ID、对端账号 ID、客户端 ID、当前 WebSocket 连接标识、邀请模式、当前毫秒、响铃毫秒、最大接通毫秒。动作使用 `invite`、`accept`、`reject`、`cancel`、`offer`、`answer`、`ice`、`hangup`，服务端内部另有 `expire` 与 `disconnect`。返回 `[状态, 通话 JSON 或空字符串]`。其中 `ok` 可转发，`busy` 仅回复当前发起端，`timeout` 发送超时。其它状态只向当前连接报告通用错误。脚本记录的账号和会话 ID 是十进制文本，服务端组装协议事件时转换为数字；Redis 与 Oracle 不保存 SDP 和候选数据。

服务端事件使用 `{type,data,timestamp}`。`data` 返回 `call_id`、`conversation_id`、`caller_id`、`callee_id`、`mode`、`caller_client_id`，接听后附 `callee_client_id`，可带 `server_id`。控制状态事件只发两个参与者的用户通道，忙线及不可用只回应请求连接。信令负载只转发给对端匹配的客户端实例。关闭前发 `call_cancel` 或 `call_hangup`，拒绝发 `call_reject`，超时用 `call_timeout`，忙线用 `call_busy`。事件包括重新鉴权和当前参与者检查。

Nuxt Web 与 Flutter 提供发起、接受、拒绝、结束和错误提示。麦克风和相机只在用户发起或接受后请求权限，结束时关闭轨道。平台不支持、浏览器环境不安全、权限被拒绝或设备不可用时显示对应说明。
