# 发帖与转发请求兼容要求

本要求以当前 Nuxt 路由、服务和转换函数为共同基线，覆盖 `POST /api/v2/posts` 与 `POST /api/v2/posts/:id/retweets`。向量文件为 `../scenarios/post-create-request-vectors.json`，只覆盖已认证请求解析及写入前校验；成功向量假设仓储正常且引用、媒体均可用，不声明这些示例 ID 在真实数据库中存在。事务与可见性要求继续使用 `post-create-transaction.md`、`post-create-reference.md`。

## 请求与转换

- 请求体必须解析为非空值的对象，数组、null、数字、布尔值和字符串均返回 HTTP 400、code 40001、message `请求体必须是 JSON 对象`。所有业务响应使用 v2 envelope，meta 为 null；路由设置 `Cache-Control: private, no-store`。
- `content`、`location` 的字符串保留原始空白；数字、布尔值使用 JavaScript String 转换；null、数组、对象或缺失使用空字符串。合法 JSON 数值溢出（例如 `1e400`）按 JavaScript 解析为 Infinity：字符串字段转换为对应字符串，数值数组过滤非有限值，安全引用拒绝该值。不能复用会 trim 的登录字符串转换函数。空字符串入库绑定 null；非空的纯空白原样保留。
- `visibility` 同样转换，但非字符串/数字/布尔值或缺失回退 `public`。只接受精确的 `public`、`followers`、`mentioned`、`private`，不 trim、不折叠大小写；空字符串等无效值返回 `visibility 参数错误`。
- `media_ids/mediaIds`、`tag_names/tagNames`、`mention_user_ids/mentionUserIds` 和三个引用字段均按 snake_case 属性是否存在选择值；存在但为 null、空值或无效值时仍压过 camelCase，不得使用 null 合并或真值回退。
- 数值数组仅接受数组。每项为有限 number 或可由 JavaScript Number 转换为有限数的非空字符串时保留；空白字符串转换为 0；十六/二/八进制和指数写法可接受。null、空字符串、boolean、对象、数组和非有限结果过滤。负数、0、小数和超安全整数范围的有限数都不在此阶段拒绝；不得截断小数、强制正整数或将 boolean 转为 0/1。保留原顺序和重复项。
- 标签数组逐项按上述字符串转换后 trim，过滤空串；此阶段保留大小写、重复项及开头的 #。非数组转空数组。
- `reply_to_post_id/replyToPostId`、`repost_of_post_id/repostOfPostId`、`quoted_post_id/quotedPostId` 与数值数组有不同规则：缺失、null 和空字符串表示无引用；其他值仅接受正的 JavaScript 安全整数 number，或匹配 `^[1-9][0-9]*$` 且不大于 9007199254740991 的字符串。失败返回 `id 参数错误`。
- 创建接口忽略 `language`、`post_type`、`author_id` 及其他未读取字段；语言固定为 `zh`，作者来自有效会话。不存在客户端指定帖子类型的入口。

## 类型、顺序与转发

解析顺序是 content、visibility、三个关系数组、reply/repost/quote 引用、location。解析后先拒绝多个非 null 引用（`引用字段只能传一个`），再按单个引用确定 reply、repost、quote，否则 post。除 repost 外，trim 后内容为空且解析后的媒体数组为空时返回 `content 不能为空`。有解析后的媒体 ID 不代表媒体可用，必须继续执行事务中的真实媒体附加检查。

转发路由先校验并解码路径 ID；要求与安全引用相同的 canonical 正整数，失败为 `id 参数错误`。随后读取对象 body，仅读取 content 和 visibility，强制 repost 引用为路径 ID，其他引用为 null，忽略 body 中所有媒体、标签、提及、位置、语言及引用字段。因此空对象可转发，无文本也可转发，额外字段不能产生关系或通知。认证中间件仍先于这些路由逻辑运行。

成功使用 HTTP 200、code 200，repost message 为 `retweet created`，其他类型为 `post created`；data 是完整帖子映射。最终读取不得增加浏览计数。数组去重和数量上限属于仓储阶段：媒体先去重取前 4 个；标签去掉一个开头 # 后 trim、过滤、按大小写敏感首次出现去重取前 20 个，数据库用 lower(name) 合并；提及关系先去重取前 50 个。

Nuxt Web 和 Flutter 只有在收到正安全整数的新 `post_id`、其与原帖 ID 不同且 `repost_of_post_id` 等于所请求的原帖 ID 时才确认转发。在回执缺失或不匹配时，提示先刷新核对发布状态，避免自动重试或增加本地转发计数。

在通用创建接口中，两端同样要求新 `post_id` 为正安全整数，且不能等于引用帖 ID。回执的回复、转发和引用关系应与提交一致，缺失或 null 均表示无引用。无法确认回执时保留编辑器中的草稿和附件，提示先核对发布结果，由用户决定是否重试。已经离开的页面或已经切换的登录会话不能被旧请求的结果修改。

## 提交后通知与错误

帖子及关系成功提交后才发送通知，然后读取完整帖子。回复通知 type 为 `comment`、event 为 `post_reply`；转发与引用通知 type 均为 `retweet`、event 分别为 `post_repost` 和 `post_quote`。资源均为新创建的 post。三者 metadata 都有 source_post_id、target_post_id（均为原帖 ID）、action_post_id（新帖 ID）、post_excerpt，另分别有 reply_excerpt、retweet_excerpt、quote_excerpt。

提及通知 type 为 `mention`，metadata 为 target_post_id（新帖）、post_excerpt、event `post_mention`。通知遍历全部去重后的原始提及 ID，不受关系写入的 50 个上限限制；不得根据截断后的数据库关系重新构造收件人。小数收件人必须精确查询，不得截断成其他用户。非正 ID、自我通知、不存在或不活跃用户、禁用对应类型时不存通知；全局 push 关闭只禁止推送，仍可存储。事件名 `notification_created`，其 notification_type 必须使用实际类型。

摘录压缩 JavaScript 空白并 trim，最长 160 个 UTF-16 单元，超过追加三个英文点；null/空字符串对应 null，纯空白的非空字符串对应空字符串。创建动作摘录取原始 payload 内容，原帖/提及摘录取数据库前 4000 字符内容。

提交后的通知数据库、映射、最终帖子读取或连接关闭失败不会回滚已提交帖子，可能保留部分通知，禁止因此自动重试创建。普通内部错误清洗为 HTTP 500/code 50001/`服务器内部错误`；最终帖子缺失为 404/`帖子不存在`，作者缺失为 404/`用户不存在`，媒体 schema 不就绪为 503/`服务暂不可用，请稍后重试。`。Redis 不可用或发布失败按现有实现降级，不把已提交请求改成业务失败。通知被设置抑制不是错误。

## 已知框架边界

当前 H3 对空 JSON body 返回 undefined，继而得到 `请求体必须是 JSON 对象`；空 URL 编码 body 解析为空对象，普通创建得到 `content 不能为空`，转发可以成功。精确 `application/json` 的非法 JSON 会保留 H3 原生 HTTP 400/`Invalid JSON body`，没有 v2 envelope；Rust/Go 的发帖请求读取器将此类错误合并为 `请求体必须是 JSON 对象`，并限制 1 MiB。带 charset 或其他 Content-Type 的 H3 解析还受其 strict 默认值影响。非法 URL 转义也可能由 HTTP 服务器在进入路由前拒绝；此类向量仅验证原始路由参数校验，不代表真实 HTTP 响应体相同。这些框架差异仅记录，不纳入本次请求向量或声称已经对齐。

## 向量结构

顶层 `cases` 每项包含 id、route（create/retweet）、body、可选 path_id 和 expected。所有 body 都是合法 JSON；retweet 的 path_id 为未经路由解码的段。expected 包含 status、code、message；成功还包含 post_type 和完整 input。input 使用 snake_case，缺失的可选引用统一规范成 null，缺失数组规范成空数组、location 规范成空字符串，用于各语言对照而非要求 Nuxt 私有 payload 的属性必须显式存在。input 保留关系去重和截断前的值。错误消息按真实解析顺序断言，不只断言状态码。
