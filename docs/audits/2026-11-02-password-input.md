# 新密码输入检查点

以已有Nuxt注册/找回/安全页最少6位规则为基准，修复trim前计数和各端不一致。三后端在规范化、原有字段/条款/确认校验后检查新密码至少6个UTF-16代码单元，短密码在OTP读取/消费和写库前固定400。Nuxt三份表单先trim再校验；Flutter使用JS trim字符集合并提交规范化快照。登录只要求非空，三后端隔离路由及两个客户端保留历史短密码。

这是新密码API的有意收紧，未迁移或强制修改旧密码；不新增大小写/复杂度或长度上限，bcrypt UTF-8前72字节规则不变。详见 [共同需求](../../specifications/requirements/auth-password-input.md)。JSON Schema结构校验不能直接表达JS trim后UTF-16长度；OpenAPI用扩展和文字约束，不能把schema通过当业务校验通过。

## 验证证据

- 共同向量19项字符串（含BOM、NBSP、NEL、零宽字符、补充平面emoji、规范化确认、长密码），以及8项API标量/非标量。注册/重置三个实际装配HTTP路由都消费27项；各语言测试使用隔离仓储，不访问真实Oracle。
- 修改前Nuxt schema 76项中21失败、55通过；Nuxt实际HTTP注册/重置2项失败，复现短密码被接受。Go/Rust路由也复现短密码返回200。Flutter纯工具尚未建立时先以实际页面复现：53项中24失败、29通过。失败日志分别保存在 `.codex-logs/password-*-red.log`。
- Nuxt相关16个Node测试文件402项全通过，失败/取消/跳过均0（`.codex-logs/password-node-green.log`）；Nuxt typecheck退出0。更新契约后单独复查payload测试18项通过，与402项有重叠，不能相加。
- Flutter相关11个文件328项全通过（`.codex-logs/password-flutter-full-green.log`）；analyze无问题。补齐测试代码的3处大括号提示后重查静态分析通过，无产品行为变化。
- Go离线 `go test ./...` 与 `go vet ./...` 退出0；Rust受控离线 `cargo test --offline --test password_input_test --test password_reset_test --test registration_test` 共7个测试通过。Rust禁用增量构建及dev/test调试符号，保留工具链与依赖；未执行完整Rust回归。
- contracts/parity工作区检查通过：171操作、schemaGaps=0、4476个schema；155 features、63 scenarios、132 sharedFiles、131 sourceAudits。客户端范围required=11、unreviewed=144；accepted=0、ready=false，完整项目尚未验收。

登录revision15，OTP创建/校验/注册各7，密码重置8；改邮箱3、刷新10、退出7保持原值。OpenAPI revision `2026-11-02-password-input`，SHA-256 `5e0ce50cb18575f528d28b641e9aedbef98ecda392f3c26e317d3a1769216660`。共同输入场景只登记一个owner，其他功能通过sharedDependencies复用。所有实现仍in-progress，没有生成虚假验收回执。

## 后续工作与边界

继续统一邮箱格式、用户名/显示名等输入，补安全页2FA/删除账号生命周期、AUTH-901/905及并发撤销。仍需补全其余144项客户端范围、全部业务、知识索引、Skills/Agent、群运营/审核和旧模块退役；本切片不缩减原目标。

本次未启动Docker、真实Oracle/Redis/模型或SMTP，未执行日常数据迁移，未提交/推送/切换分支。真实Oracle约束、会话撤销、浏览器Cookie/cache/SSR、设备持久化、六种客户端/后端组合以及Windows/Linux多机器部署均待C3集中验收。

C盘按用户要求先复查，当前约99 GiB可用；前次净回收92.60 GiB有独立审计。本次保留重建的受控Cargo产物，没有再次删缓存。最新实测见 `.codex-logs/storage-2026-11-02/post-tests.json`；该数字为时点值，不是完整C盘占用归因。
