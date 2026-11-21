# 修改当前用户邮箱

安全页入口绑定创建时会话，身份变更通知后卸载旧表单并清除新邮箱/验证码/OTP上下文；在途身份变更结束后方可显式重开。自身成功清理后的当前receipt由父页面校验并导航，不因子表单先卸载而丢失，也不能跳离较新身份。见auth-security-client-lifecycle.md；跨端点/设备和真实浏览器验收仍未完成。

新邮箱按 `auth-account-input.md` 执行与Nuxt Zod/v3相同的格式检查；在鉴权/三个必填字段解析之后、任何业务查询/OTP消费前固定400拒绝非法新邮箱。两客户端的发码和提交同步此规则；旧账号不批量修改。

共同接口：`PATCH /api/v2/users/me/email`。Nuxt为现有行为来源；Rust/Go必须原生实现，不能依赖Nuxt。三套实现已有静态接线与隔离回归，真实数据库和跨后端验收仍未完成。

1. 必须先完成统一会话鉴权，再按v2标量字符串规则读取并trim `new_email`、`verification_id`、`code`；空字段按顺序返回400 `<字段> 不能为空`。沿用共享JSON/表单和安全错误包装，不新增独立令牌格式。
2. 验证目标邮箱没有被其他user_id使用；已存在返回409 `邮箱已被使用`。邮箱大小写和格式的最终统一规则须与全体账号输入规则同步，当前不私自改变已有比较规则。
3. 验证OTP的account必须为捕获的new_email、type为change_email、verification_id一致且未过期，bcrypt代码匹配；不要求预先调用公开OTP验证接口。不存在或过期返回 400 `验证码不存在或已过期`。比对前按 `auth-otp-verification.md` 预留同一验证码的共享额度，耗尽返回 429，Redis 不可用返回 503。验证码不匹配返回 401 `验证码错误`。客户端应将发码发送到新邮箱；旧邮箱验证不能替代。
4. 目标安全语义：在同一事务中条件消费原OTP（绑定account/type/id/原hash/有效期）并更新唯一当前用户邮箱及email_verified_at；任何步骤失败都回滚，不能只消费OTP或只改邮箱。同一OTP的重放/并发只允许一个成功，邮箱唯一性竞争按409安全返回。真实Oracle并发必须后续验证。
5. 成功返回现有v2 envelope，data包含email与带时区email_verified_at；不自动创建新会话。TIMESTAMP列在写入的同一连接中按SESSIONTIMEZONE转UTC、输出毫秒ISO时间，避免不同部署主机时区改变返回值。现有客户端成功后按捕获会话版本退出当前会话，失败不额外退出；新登录/输入改变/卸载不能被旧页面结果覆盖。提交抛错或提交后连接关闭失败可能已写入，回滚不能保证撤销已提交结果；客户端不能把错误等价为服务端未提交，也不自动重放修改。
6. 不输出邮箱验证码、哈希、内部连接或底层异常；数据库与邮件测试使用隔离数据。跨后端相同数据、权限、错误、OTP消费和客户端六组合需共同验收。

7. 两客户端在2xx响应下校验完整成功正文：根对象、数值code=200、非空字符串message、存在的meta（null或对象，已知has_next须为bool/null）、data对象。data.email为非空字符串且精确等于捕获请求trim后的新邮箱，email_verified_at为有效带时区日历日期；不按客户端当前时钟拒绝较早日期。拒绝缺字段、错误类型、error=true和冲突业务code，合法未知附加字段允许。固定安全解码错误为`Invalid email change response`，不能附带正文/邮箱验证码或内部异常。只有解码成功才进入页面的受控成功/退出逻辑。

改邮箱是已鉴权的凭据修改，但错误OTP也返回401；不得因此自动刷新/重放或清除有效会话。请求仍须携带鉴权并受原会话归属检查，旧成功在进入解码前取消。过期会话的错误同样交给页面/用户显式处理，此接口不自动重放来试探结果；普通资源的有界401恢复保留。`scenarios/auth-email-client-response-vectors.json`固定44条两端实际API共同正文样例。

实现位置：Nuxt v2ChangeEmail、Go email_change.go、Rust users/email_change及email_change_transaction。三端以条件更新将原OTP哈希替换为不可验证的`!consumed!`并写过期时间；更新零行视为失效/用户缺失，多行视为存储错误；邮箱唯一性错误安全映射409。Nuxt路由使用safeAuthEntry，原生路由复用现有鉴权和安全envelope。

`scenarios/auth-email-change.json`包含25条共同场景，含提交前失败与提交后报错两种模型；后者返回500但marks/writes为1，禁止推断“错误必然无副作用”。隔离回滚/重放/并发模型不证明真实Oracle锁/驱动/时区转换，仍须最终集中验收。两端成功正文已严格解码；发送与比对额度已有共享实现，完整输入策略、部署后的 Cookie/cache/并发鉴权和真实环境仍需验收。
