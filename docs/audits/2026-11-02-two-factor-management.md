# 三后端原生双因素管理检查点

已补齐Rust/Go的setup、confirm、disable原生路由、存储与密码学接线；Nuxt同时升级为共同事务规则。三个后端均独立访问共享Oracle，不转发Nuxt业务。生成20字节Base32密钥并以既有AES-256-GCM格式保存；确认时生成10个5-5-5恢复码，只存规范化bcrypt哈希。设置/确认/关闭的密钥、恢复码、受信设备与设置写入各在一个事务中提交。

确认和关闭条件更新原密文/IV/tag，状态变化409；恢复码消费与关闭同一事务，零行401回滚。setup不覆盖已启用密钥；重复confirm已启用密钥返回422，避免无意替换恢复码。这是三后端共同修正旧Nuxt逐条提交行为，不是只为新后端保留另一套语义。提交报错仍可能已经提交，客户端不能自动重放。三个成功响应明确private/no-store；只有当前setup密钥和当前confirm恢复码可作为成功字段交付。

具体输入顺序、格式、错误、事务及限制见 [共同需求](../../specifications/requirements/auth-two-factor-management.md)。未新增框架或依赖；Go复用既有TokenManager并新增同格式seal，管理接口有实际OracleSessions编译断言；Rust复用登录AES/TOTP函数及已有OraclePool/事务层。

## 证据

- 三个实际装配HTTP管理路由消费57项共同场景，覆盖鉴权、旧密码/active账号、只读schema、AES认证/Base32、TOTP/恢复码、状态冲突、逐步失败、提交报错与模拟提交后报错。setup/confirm/disable三个场景视图从同一集合生成，Nuxt回归验证等于对应子集，不能重复计数。修改前Nuxt事务检查失败、Go/Rust管理路由404；日志 `.codex-logs/factor-*-red.log`。
- Go/Rust生成的新密文由现有AES解码模块读取；生成恢复码与已存哈希通过既有规范化/bcrypt验证。Nuxt成功密钥/恢复码格式及URI字段验证通过。这些是隔离的格式/算法互通证据，不等于实际OTP应用和三台后端真实数据库互测。
- 生产事务逻辑下方的Go database/sql隔离driver与Rust OracleTx适配器测试，逐步模拟失败/提交失败、密钥CAS零行、恢复码消费零行并核对回滚；Go另验证已匹配恢复码不会把ID零误当无恢复码证明。真实Oracle驱动、锁和触发器仍未运行。
- Nuxt相关18文件最终546项全通过，失败/取消/跳过0（`.codex-logs/factor-node-final.log`）；typecheck通过。新增Cache-Control检查先观察到缺标记失败，再补标记通过。OpenAPI明确confirm缺code/null/非标量的业务错误顺序，payload测试包含在546内。
- Go离线全量test/vet通过（`factor-go-final.log`、`factor-go-vet-final.log`）。Rust8个相关集成测试文件27个声明测试通过，另1个生产事务单测通过，后者过滤96个其他lib测试，未执行完整Rust回归。
- Flutter本轮只同步契约资料，业务代码未修改；API接线相关39项通过（`factor-flutter-contract.log`），包括三个管理操作的路径/方法/请求体。此前467项/analyze是上一检查点的结果，不作为本轮新增全量运行记录。
- contracts/parity工作区检查通过：171操作、schemaGaps=0、4519 schemas；155 features、68 scenarios、142 sharedFiles、131 sourceAudits；客户端required=15/unreviewed=140。accepted=0、ready=false，整体仍未验收。

三项管理feature revision3、需求reviewed，三后端及两客户端均in-progress。注销revision2及其他认证版本保持。OpenAPI revision `2026-11-02-two-factor-management`，SHA-256 `e7e157ca787961cf05e38cb124db7a5ad6abc8e369475337b1439c866ee1892b`。Nuxt源基线仅重钉本次审查的管理代码及安全路由；未把整个auth模块或其他131项源审计宣称完成。

## 后续

优先完善两客户端凭据成功正文/envelope/secret/URI/enabled/recovery_codes解码及已显示秘密失效，处理注销Set-Cookie与认证队列/并发登录。继续AUTH-901限流/尝试次数、AUTH-905在途登录/挑战/实时撤销、资料编辑与140项待审客户端范围。全业务同步、知识索引、持久化上下文、版本化Skills/有界Agent、群运营/审核、旧情感分析退役与Windows/Linux多方式多机器部署全部保留。

本次未启动Docker/真实Oracle/Redis/模型/SMTP，未操作真实用户或日常迁移，未提交/推送/切分支。实际Oracle锁/driver/schema数据、真实OTP应用、浏览器Cookie/cache/SSR/设备存储及六种客户端/后端组合仍待C3集中验收。C盘仍约99 GiB可用，无新增清理操作，Rust继续禁用增量与dev/test调试符号。
