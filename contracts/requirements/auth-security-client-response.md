# 两客户端安全动作成功响应

适用于2FA setup/confirm/disable和当前账号注销。后端业务/事务仍按auth-two-factor-management.md、auth-account-deletion.md；这里规定Nuxt/Flutter对外部成功响应的解释。实际HTTP2xx并不等于可发布成功，必须先校验完整envelope再解码data；失败仅固定 `Invalid security action response`，不附带secret、恢复码、URI、密码或原响应文本，不自动重放或清理会话。

1. 根为对象而非数组/null/标量；code为数字且精确等于200，message为字符串且按JS trim后非空。meta必须存在，可为null或对象，has_next若存在为null/布尔；error若存在只能字面false。data必须对象。未知附加字段忽略，允许兼容扩展；不以宽松Map回退、类型断言、真值强制或过滤坏数组元素代替校验。
2. setup的secret为恰好32个A–Z/2–7字符，无空格/填充/换行。otpauth_url为原样ASCII可打印字符串，无空白/反斜杠，形如otpauth://totp/<单一路径段>?<查询>，无userinfo/端口/片段/其他scheme或类型。路径严格UTF8百分号解码后为NekoTribe:加非空账号（JS trim），允许编码后的斜杠/Unicode；不要求与可能已更新的客户端资料缓存相等。查询按application/x-www-form-urlencoded解码，所有项须key=value且编码有效；secret/issuer/algorithm/digits/period各恰好一次，值依次为同secret、NekoTribe、SHA1、6、30。顺序可变；未知合法查询项可附加/重复。失败不展示密钥或URI。
3. confirm的enabled须字面true，recovery_codes须恰好10个字符串，每项为5-5-5 Base32（共17字符），不接受短码、小写、空白、数字或过滤后的部分列表。三后端当前独立随机生成，不承诺恢复码无重复；客户端不自行增加去重要求。返回列表复制，不保留外部可变引用；Flutter结果不可变。
4. disable的enabled须字面false。注销的deleted须字面true，user_id须数字、有限、正整数且<=9007199254740991，禁止字符串/布尔转换。只有解析成功且仍属于原会话才发布成功；Flutter原版本条件清理/receipt及Nuxt认证队列继续适用。
5. Nuxt由v2 API层读取完整响应再产生受验证DTO，service映射VM；Flutter由ApiClient成功envelope回调和严格工厂产生不可变DTO，API/仓储/页面沿用同类型，不再暴露四种安全动作的Map结果。坏响应后保留客户端本地会话，不能据解析失败断言服务器事务未提交（注销Cookie可能已被服务端清理），应允许用户主动重新核实状态，不能自动重放。
6. 重新setup可能已经替换服务端未启用密钥；发起有效请求前先清除旧secret/URI/确认码及恢复码显示，不能在新请求失败或响应解析失败后继续展示旧配置。保留密码输入供用户主动重试，不自动重新生成。此清理不等价身份切换时的即时秘密失效，后者另按生命周期任务处理。

共同向量 `scenarios/auth-security-client-response-vectors.json` 包含合成合法与畸形响应，两客户端实际API边界读取同一份规范；Nuxt经service验证VM，Flutter同时检查类型、数据及不可变恢复码。OpenAPI描述可表达的结构约束，URI跨字段一致性/解码语义等仍以上文和共同向量为准。

身份变化时秘密失效及重开按auth-security-client-lifecycle.md执行，设置快照及安全页未知状态按user-settings-snapshot.md严格处理。后续仍须原生设置行为差异/一般设置页旅程、真实OTP应用、HttpOnly/跨标签页/SSR/设备存储、六组合和部署验收；隔离检查不标accepted。仅静态开发，不接触真实账号和日常数据。
