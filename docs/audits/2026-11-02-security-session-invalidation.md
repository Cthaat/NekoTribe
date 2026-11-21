# 安全页会话失效检查点

2026-11-02：补齐两客户端已显示秘密在身份变化时的失效、显式重开及成功清理后的导航。保持静态开发；没有运行Docker、真实Oracle/Redis/模型/SMTP，没有操作真实账号、日常数据、分支或提交，没有额外清理文件。

## 实现

Nuxt `AuthRequestQueue` 新增无用户数据的同步订阅、取消订阅及身份变更在途标志。登录/2FA完成/退出在开始（含排队等待）时失效原版本，响应成功或失败都释放在途标志；普通刷新不失效安全页。观察者按Nuxt app隔离，观察异常不能阻止认证工作。`SecurityPage.vue` 在身份变化后卸载密码、2FA、邮箱及注销子表单，阻止在途重开；结束后用户显式重开，重新创建空表单并读取状态。不同分支使用不同key，避免动态key初值与Vue生成的分支key冲突；实际Vue模板/运行时回归发现并修复了该冲突。

Nuxt邮箱与安全页密码表单还在动作入口绑定创建时版本，卸载清空字段、OTP及定时器。自己的成功清理可先卸载子表单，再由仍挂载父页校验当前版本并在捕获app上下文中导航；过期回执、父页已卸载不导航，导航失败用安全反馈处理。

Flutter `TokenStore` 通过私有ChangeNotifier子类发布版本/在途通知，保留串行存储与条件清理语义；`AuthRepository` 跟踪登录、2FA完成、退出的完整网络生命周期，清理成功/失败都释放在途标志。安全页外层绑定原仓储/版本，仓储替换同样失效，取消旧订阅。移除旧表单，清空控制器及secret/URI/恢复码引用，阻止旧动作/复制回调；重开创建新owner并重读状态。自己的注销/改邮箱清理结果交由父页凭当前仓储和receipt导航，因此不会因子页面先卸载而丢失，也不能跳离新登录。普通读取/刷新不额外清理秘密。

共同规则为 `specifications/requirements/auth-security-client-lifecycle.md`，同步Rust/Go/Flutter副本。2FA三项、注销、改邮箱feature revision5，密码重置revision10，三后端/双客户端targetRevision同步；公开密码重置仍是公开接口，仅已登录安全页表单增加门控。后端业务/HTTP响应没有改变，OpenAPI仍为SHA256 `37e6337b103b64a9c827fff763889dd31c502c07253a6b759d5dc4daa37d8f98`。

## 验证

- 先观察4项Nuxt订阅回归失败、2项Flutter已显示密钥/恢复码保留失败：`security-session-queue-red.log`、`security-session-flutter-red.log`。
- Nuxt最终20文件809项通过，fail/cancelled/skipped均0，typecheck exit0：`security-session-node-final.log`、`security-session-typecheck.log`。新增13项包含队列通知/失败/隔离、实际父SFC模板与Vue运行时卸载/重开/父页导航、OTP旧owner与子表单卸载后的回执转交。Vue运行时使用内存renderer及子组件替身；子表单实际函数另有隔离回归，不等价浏览器DOM、VeeValidate实机或SSR部署验收。
- Flutter完整819项通过，analyze无问题：`security-session-flutter-full.log`、`security-session-flutter-analyze.log`。新增7项真实TokenStore/AuthRepository信号检查、8项安全页widget检查，覆盖在途重开、已显示秘密、仓储替换/取消订阅、旧响应不释放新busy、旧复制回调及子页已卸载后的当前/过期清理回执。11项初始分析警告/info已通过私有通知发布器和正确块语法修正，没有禁用规则。
- contracts/parity exit0：171 operations、0 schemaGaps、4527 schemas、155 features、68 scenarios、144 sharedFiles、131 sourceAudits，required15/unreviewed140，accepted0/readyfalse。四工作树作用域diff检查通过；新文件单独源审查/哈希记录。
- Go/Rust运行时代码未改，本轮未重跑其运行时回归；旧原生事务/HTTP结果属于历史。本轮没有重建Rust target或删除缓存/开发文件。

## 仍需推进

下一步审查两客户端安全状态读取字段与加载/错误行为，再继续AUTH-901限流/尝试次数、AUTH-905在途会话发放/实时撤销、资料输入、140项客户端范围及完整业务同步。跨端点切换时完整认证存储/刷新范围、跨标签页/设备通知、真实浏览器Cookie/cache/SSR、Oracle/OTP应用、六组合及多方式多机部署未验收。不承诺擦除不可变字符串物理内存，也不清空用户此前主动复制的系统剪贴板。

原AI目标继续包括可切换模型、公开平台数据RAG索引、持久化对话上下文、版本化Skills、有界Agent、问答写作/群运营/审核、旧情感分析退役及Windows/Linux本地/Docker/混合/多机启动。局部安全页完成不等价整个项目完成。
