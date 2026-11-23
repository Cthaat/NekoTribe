# 帖子和聊天外链预览

登录后可通过 `GET /api/v2/links/preview?url=...` 查询外链。请求只接受带主机且无凭据的 HTTP 或 HTTPS URL，使用协议默认端口。URL 最多 2,048 UTF-8 字节，缓存及请求去掉片段。返回 `{preview}`，成功包含已验证的最终 `url`、`title`、`description`、`site_name`。以 OpenGraph 标题、摘要和站点信息为先，回退到网页标题、描述及主机名。无法获得元数据时返回 `preview: null`。

三个后端每次连接前核对目标及全部解析地址，只连接已核对的公网地址。禁止私网、回环、链路本地、保留地址、编码转换与云平台内部地址。保留域名后缀按共享策略拒绝，无需解析。每跳重做检查，最多跟随 3 次重定向，整条请求链含解析最多 3 秒。只读取 HTML/XHTML，限制正文为 512 KiB。连接保留目标的 HTTP Host 与 TLS 主机校验。服务不携带用户凭据，不使用环境代理。禁止的 URL 或跳转返回普通 400。网络故障、超时或不支持的内容仍可正常浏览原帖和聊天。[IANA IPv4 地址登记](https://www.iana.org/assignments/iana-ipv4-special-registry) · [IANA IPv6 地址登记](https://www.iana.org/assignments/iana-ipv6-special-registry) · [OpenGraph 协议](https://ogp.me/)

外链请求声明只接受 identity 编码，服务忽略压缩的正文。Redis 按规范化 URL 的 SHA-256 缓存成功的文本元数据 1 小时。Redis 不可用时仍可查询，接口响应禁用浏览器及后端通用缓存。

Nuxt Web 和 Flutter 在普通帖、群帖、频道消息和私信中为首个外链显示文本卡片。卡片只包含站点、标题和摘要。用户点击后打开链接。预览不下载或自动显示远程图片。发送、编辑和读取原始内容的权限保持原样。
