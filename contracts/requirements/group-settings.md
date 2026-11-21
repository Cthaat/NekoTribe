# 群组设置

PATCH /api/v2/groups/{id} 要求有效会话、正十进制安全整数群组 ID 和 JSON 对象请求体。响应为 private, no-store。群组须启用且未删除，操作者须是 active 管理员或登记的活跃群主。

支持 name、description、avatar_url、cover_url、privacy、join_approval、post_permission、category 和 tags。省略字段保留原值，未知字段忽略。name 须为非空白字符串，最多 100 个 UTF-8 字节。description、avatar_url 和 cover_url 接受 null 或最多 500 字节的字符串，空字符串清空字段。category 接受预定义分类，null 或空字符串清空分类。privacy 与 post_permission 为各自的已有枚举，join_approval 为布尔值。

tags 须为字符串数组。空数组清空标签，省略时保留。标签去除首尾空白与一个前导 #，按小写去重，保留前八个非空项。显示名和小写键均限制为 50 个 UTF-8 字节，截断时保留完整字符。

先锁群组，再核对操作者的成员记录。更新群组、替换标签及读取响应数据在同一 Oracle 事务完成。读取成功后提交，异常回滚。成功返回更新后的完整群组数据，空补丁只读取当前数据。参数错误返回 40001，群组或群主资料不存在返回 40401，权限不足返回 42201。真实 Oracle 并发与客户端组合待验收。

通过权限检查后，对本次提交的托管群组图标和横幅取得媒体行锁。图片已删除时返回 40001 并回滚。外部地址与未提交的字段继续遵循原规则。详细 URL 识别和锁顺序见 `media-upload.md`。
