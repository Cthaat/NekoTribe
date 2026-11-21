# 当前账号注销

`DELETE /api/v2/users/me`由三后端独立提供，不能代理Nuxt。沿用Nuxt业务范围：软删当前用户帖子/评论、撤销当时已存在的会话、匿名化并禁用账号；不是物理删除或完整个人数据擦除，不删除上传文件、模型、私信、所有关系和审计数据。

1. 先执行统一access Cookie/Bearer及session鉴权；解析JSON/表单对象，读取当前用户资料，不存在404。再按v2标量字符串/JS trim规则读取password、confirmation；依次必填400。confirmation须等于当前username（大小写敏感）或转换为大写后为DELETE，否则400 `确认内容不匹配`。
2. 只按鉴权user_id查密码/status/is_active，不接受body user_id；不存在404、非active账号403 `账号不可用`，bcrypt不匹配401 `密码错误`。旧短密码不套用新密码6位规则，bcrypt继续UTF-8前72字节兼容。数据库、哈希及内部异常固定安全500，不能暴露密码/哈希/驱动异常。
3. 生成密码学随机不可猜值并bcrypt成本10哈希。在单个数据库连接的同一事务中依次软删n_posts(author_id)、n_comments(user_id)，撤销n_auth_sessions，再更新n_users：username=deleted_<id>、email=deleted_<id>@deleted.local、display_name=已注销用户，清空bio/location/website/phone/avatar_url/avatar_media_id，is_active=0、status=disabled。保留其他既有字段。所有SQL绑定user_id；最终更新同时绑定原密码哈希及active状态，零行回滚并409 `账号已变更，请重新验证`，多行/执行异常回滚500。
4. 四步只提交一次；提交失败也尝试回滚。提交或连接关闭报错可能发生在实际提交后，客户端不能据500认定未注销，不能自动重放。成功200 `{code:200,message:'success',data:{deleted:true,user_id},meta:null}`，清理access/refresh Cookie；失败不伪造Cookie清理。提交后最佳努力发送presence，通知失败不改变已提交注销结果。此事务修正旧Nuxt逐条自动提交的部分注销行为，三后端同时升级。
5. 客户端绑定发起时会话与资料快照，函数入口防重复提交，离开/切换身份后不发布旧结果。业务401不自动刷新/重放/退出，普通GET/PATCH用户资料仍保留原401恢复。成功只能清理原版本本地状态；Flutter条件持久化清理及全局收尾完成后凭receipt导航，不追加已失效会话的网络退出。Nuxt确认当前版本后重置Pinia并导航。
6. Nuxt注销请求复用同app认证队列，与登录/2FA登录完成/刷新/退出等到响应完成后才执行下一项；提交参数和app在发起时捕获。身份变更已排队或执行中时拒绝注销；等待期间身份变化则取消发送，完成时再次核对版本。普通刷新完成后仍可执行原身份注销。队列失败后可继续；不同SSR/app彼此隔离。不能只忽略JS结果而允许旧注销的Set-Cookie晚于较新登录到达。

`scenarios/auth-account-deletion.json`22项共同HTTP场景覆盖确认/密码/鉴权、四步事务失败、并发状态变化及提交后报错。Nuxt实际服务执行器、Go SQL driver隔离测试和Rust OracleTx适配器下方的事务逻辑测试分别验证事务；假仓储的路由通过不等于真实Oracle锁/驱动/触发器验收。

两客户端注销完整成功envelope按auth-security-client-response.md严格解码；FlutterAPI/仓储/页面使用不可变注销DTO。解析失败不代表服务端未提交，不重放；只有当前会话的有效成功确认才进入受控清理。

待完成：在途登录/挑战发放在注销提交后才新建session、实时WebSocket即时撤销、完整数据保留策略及真实浏览器/跨标签页Cookie并发，见AUTH-905/C3。同app认证队列已有隔离回归。三后端2FA管理原生接口已有接线，注销不据此额外增加2FA要求。本次不操作真实账号，不可据隔离检查标accepted。


共享presence映射和事件编码按user-settings-presence.md：精确可见标志、hidden时间脱敏、固定字段、合法时钟和降级日志。此次不改变既有鉴权/业务提交规则。Nuxt本地独立发送与Go/Rust依赖Redis的本地送达仍有实现差异，WebSocket验收前须统一并验证本地降级、断线恢复和客户端状态传播；共同设置HTTP场景不代替本功能的完整验收。
