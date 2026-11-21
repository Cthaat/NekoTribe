# 用户设置快照与客户端安全状态

GET/PATCH `/api/v2/users/me/settings` 都返回当前鉴权用户的完整设置快照。三后端独立访问共享数据；GET也可能初始化设置行，不是无写入承诺。共同HTTP与NUMBER映射场景为user-settings-native.json，PATCH输入另见user-settings-patch.json。隔离场景通过不代表真实Oracle、Redis、并发、客户端组合或部署已验收。

成功envelope：对象、数字code精确200、JS trim后非空message、必有meta(null或对象，has_next若非空须布尔)、error若存在只能false、data对象。兼容附加字段。两客户端在真实API边界对GET和PATCH均校验；失败固定 `Invalid account settings response`，不回显响应，也不自动重放业务写入。GET普通401仍可沿既有版本守卫做一次恢复。

完整data共14字段，均必须存在：

- user_id为正安全整数<=9007199254740991。
- two_factor_enabled、login_alerts、show_online_status、allow_dm_from_strangers、push_notification_enabled、email_notification_enabled、ai_sentiment_enabled、ai_sentiment_return_probabilities、ai_sentiment_include_metadata均为字面布尔，不接受null、数字或字符串。
- profile_visibility、updated_at为字符串。保留当前映射允许的未知/空privacy及空时间字符串，不在读取层偷偷更改旧数据或发明时间格式迁移。
- ai_sentiment_model_id为必有的null或字符串；ai_sentiment_top_k为1..10整数。

Flutter工厂不再用toMap/toBool/toInt回退；模型字段非空（model_id例外），公共构造器仅为本地状态/夹具提供显式默认，不代表传输允许缺字段。Nuxt API先校验再映射VM，不做真值转换。旧AI情感字段当前仍在线协议内，原计划中的退役不能通过本次静默删字段替代。

重读或替换设置后，保留的复制回调也须核对当前显示数据，不能把已移除的secret/恢复码写入剪贴板；已在身份改变前发出的系统复制无法保证撤销，不清空用户此前主动复制的数据。

安全页双因素状态：初始/加载/失败为未知(null)，不能展示“未启用”，不能发起setup/confirm/disable。显式读取成功后才启用相应动作；setup仅未启用时，confirm仅未启用且持有本页setup时，disable仅已启用时。重读入口防重复、在管理动作pending时禁用；开始重读清除旧secret/URI/恢复码。旧owner/卸载/迟到结果守卫和显式重开继续按auth-security-client-lifecycle.md。读取失败不自动重试，也不禁用独立的改邮箱/注销等账号操作。167项共同响应向量分别用于GET和PATCH；SSR模板及Flutter widget回归验证未知态/重试/窄屏。

PATCH输入继续沿当前Nuxt行为及user-settings-patch.json：对象JSON/form，未知字段忽略；two_factor_enabled任何值只要出现即400。布尔经既有v2Boolean转换，model_id经v2String转换再JS trim，空值清除，trim后超过128个UTF16单元400。privacy只接受转换后的精确public/private，不trim、不支持followers；此前followers及允许空白的OpenAPI描述有误，现按三份源码修正。新top_k按既有数值转换、截断和1..10限制。不能通过一般设置接口绕过2FA管理流程。空patch保持成功返回快照，presence副作用按show_online_status字段出现触发。一般设置页的身份/保存/结果不确定规则与局部修复见user-settings-client-lifecycle.md；完整浏览器、设备及后端组合旅程仍待验收。

## 原生读取与更新规则

- 请求先鉴权；PATCH先校验输入，非法输入不得初始化行。只读schema检查失败返回固定503/50301“服务暂不可用，请稍后重试。”。schema之后锁当前n_users父行，MERGE缺省设置、可选更新、读取完整快照均在同一事务；Nuxt显式autoCommit=false。不在读取中再次初始化/提交。
- 缺父用户404/40401“用户不存在”；初始化后仍无设置404/40401“用户设置不存在”，均先回滚，不向孤立账号创建设置。返回行user_id不符属于安全500，不返回其他用户数据。
- 成功提交一次；事务内锁/写/读失败回滚，固定500/50001“服务器内部错误”，不暴露驱动细节。提交失败尝试适配器允许的清理，提交结果可能不确定；database/sql已结束的Tx只返回ErrTxDone，不能把调用Rollback误称为实际驱动回滚。提交/关闭/提交后的presence查询失败都不能承诺写入已撤销，不自动重放PATCH。真实驱动连接清理仍须集中验收。
- 组装后的GET/PATCH成功、未登录/无效token、schema/存储/缺行错误都private,no-store。Nuxt设置GET绕过响应缓存，设置路径的SELECT绕过Oracle查询缓存；n_user_settings查询在其他路径也不缓存，避免共享后端或2FA更新后读到旧状态。PATCH及初始化的失效通知仍可访问Redis，不承诺整个请求绝不访问Redis。拒绝的CORS/预检/未知子路径不属于本轮共同业务响应场景。
- 数据库NUMBER标志只有原值精确1为true（1.9不能先截断成1）；return_probabilities为NULL时默认true。旧top_k在原始数值1..10范围内才截断，否则默认3：3.9→3、1.9→1、10.9→3；这是读取兼容映射，PATCH新输入10.9仍按既有截断规则写10，不静默迁移旧数据。模型ID/隐私/日期的旧读取兼容规则如上。
- PATCH presence在事务成功后按字段出现触发，不使用客户端值代替当前服务端状态；隐藏状态不暴露last_seen_at。presence的固定事件、查询/发布失败与降级规则见user-settings-presence.md，共同隔离场景已补齐，PATCH需求reviewed；真实发布/连接失败、初始化并发和账号删除竞争仍待集中验收。
- 日常库不迁移、不改账号；真实依赖、两客户端×三后端及Windows/Linux部署仍待集中验收。原完整业务、AI与可维护性目标保持不变。
