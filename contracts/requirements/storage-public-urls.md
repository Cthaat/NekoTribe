# 公共存储地址与登录头像 v1

Nuxt、Rust native 与 Go 的登录响应应使用一致的头像公共地址；此规则只转换 URL，不证明文件存在或原生后端已实现文件读取、上传或删除。共同合成样例见 `scenarios/storage-public-urls.json`，需分别运行三端实现并另行验证真实跨机访问。

- 各服务使用 `STORAGE_PUBLIC_BASE`（默认 `/storage`）、`BASE_URL` 和 `STORAGE_CDN_BASE_URL`。后两者去首尾空白及尾随斜杠；CDN 非空时优先。公开路径统一为前导斜杠、去尾随斜杠，反斜杠转换成斜杠。
- 空、`default-avatar.png` 及 `/default-avatar.png` 映射到当前公共路径的默认头像。原有 `/storage/`、`/uploads/`、`/upload/` 和当前公共路径下的地址，按相同 key 映射到当前公共路径；同选定 base origin 的绝对旧地址也转换，其他来源地址保留。无 base 时返回相对地址；有 base 时构造可公开的绝对 URL。路径 key 规范化后不得越过存储根。
- 为避免公开响应携带凭据，`BASE_URL` 或 `STORAGE_CDN_BASE_URL` 含 URL 用户名或密码时拒绝处理，不记录这些值。为避免将地址解释为指向其他主机的协议相对 URL，`STORAGE_PUBLIC_BASE` 不允许根路径 `/`、仅斜杠或以 `//` 开头。其他非法地址仍须安全失败，不以原始错误泄露内部配置。
- 本轮共同样例覆盖常见配置、旧路径、相同/不同 origin、大小写与默认端口、Unicode、路径穿越及上述不安全配置。各语言 URL 库对非标准/畸形 URL、转义及边界输入可能不同；不能据样例声称所有 URL 都已等价。配置和 URL 均不赋予请求文件或跨来源访问权限。
- 登录时在生成 Cookie 前完成资料地址转换；转换失败不得发送新 Cookie。之前已提交的 session/通知可能仍存在。Rust/Go 当前仍需补文件服务、上传、安全访问和完整通知等业务。

公共 `BASE_URL` 与 CDN 配置是给浏览器访问的地址，不应使用带凭据的内部服务连接串；测试只用虚构域名和秘密。Windows/Linux、反向代理、CDN 与两前端真实访问须在隔离环境集中验收。
