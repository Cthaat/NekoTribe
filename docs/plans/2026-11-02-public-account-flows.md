# 公开账号流程：OTP、注册与找回密码

已核对共同需求及Nuxt/Rust/Go原生实现：OTP用途/account/verificationId关联、注册需verified OTP且不签会话、重置在服务端消费OTP并撤销旧会话。当前缺口集中在客户端异步流程，真实Oracle/SMTP仍未验收。

本步实现：

1. 注册/找回密码两端的发码、提交函数入口阻止重复调用；失败释放忙碌状态，允许用户主动重试，不自动重放。
2. OTP绑定规范化邮箱。邮箱改变即废弃标识/输入和在途版本；迟到响应不得发布。卸载时清理Nuxt定时器/使请求失效。Flutter在dispose后不继续注册第二阶段。
3. 注册开始前捕获邮箱、OTP、verificationId和整份资料，验证成功必须为true且account匹配，之后只提交捕获副本，避免await后读取可变表单。
4. Nuxt找回密码仅成功后执行原版本受控的退出/跳转；失败不得通过finally额外退出。保留网络提交结果可能未知的后端语义。
5. 登记四个功能的双客户端范围与后续任务；本步不声称安全页change_email/修改密码的OTP生命周期、完整响应解码、服务端限流/OTP一次消费及真实服务已全部完成。

先写实际SFC回调和Flutter Widget失败回归，再实施最小修改，运行相关测试/typecheck/analyze/contracts/parity并同步共同需求。继续完整业务和Agent路线，不以局部进展替代总目标。

检查点：公共两页流程接线、Node160项/Flutter106项回归及typecheck/analyze/contracts/parity通过。见 [审计](../audits/2026-11-02-public-account-flows.md)。严格解码/输入、安全页消费者、Flutter重置凭据条件清理及第5项边界仍未完成。
