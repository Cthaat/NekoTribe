# 账号注册 v1

`POST /api/v2/auth/registration` 是公开接口；Nuxt、Rust、Go 使用同一 Oracle 用户及 OTP 模型并各自独立执行，不能转发其他后端。此接口不创建登录 session、签发 token 或设置认证 Cookie；过期 access Cookie 不阻止注册。

1. JSON/form 请求按现有 v2 字符串规则逐项读取 `email`、`username`、`password`、`confirm_password`、`display_name`、`verification_id`：字符串/数字/布尔值转字符串并 trim，空或非标量返回 400 `<字段> 不能为空`。`bio`、`location`、`phone`、`birth_date` 使用相同标量转换但不 trim，空值转换为数据库 NULL。必须严格 `agree_to_terms: true`，否则400 `必须同意服务条款`；两次密码必须一致，否则400 `两次输入的密码不一致`。字段解析完成后才检查条款和密码。
2. 查询匹配 email、用途 `register`、verification_id、数据库当前时间尚未过期且 `verified_at IS NOT NULL` 的 OTP；不存在返回422 `请先完成验证码校验`。注册不消费 OTP。再按 email 或 username 查重，已存在返回409 `邮箱或用户名已被注册`。两个条件都使用绑定参数，不回显敏感数据。
3. 查 `seq_user_id.NEXTVAL`，以 bcrypt 成本10生成密码哈希并插入 `n_users`：写入 ID、email、username、hash、display_name、bio、location、phone、birth_date；非空出生日期交由 Oracle `TO_DATE(..., 'YYYY-MM-DD')`，email_verified_at 用数据库时间，status 为 active。共享数据库自身触发器负责初始化 stats/settings 等数据，不重复创建。bcrypt 长输入按 Nuxt 的 UTF-8 字节截断72字节，不能因语言库限制而静默改变密码。
4. 用户 INSERT 自动提交后读取完整 self profile，头像地址按 `storage-public-urls.md` 映射，返回 `{code:200,message:"registration success",data:{user},meta:null}`。没有用户返回404 `用户不存在`。数据库、哈希、profile和连接异常返回安全500，不泄露密码、OTP、数据库或内部异常；即使返回错误，INSERT 可能已经提交，不能声称全流程原子。
5. 查重与插入之间存在竞争；真实 Oracle 唯一约束及并发错误映射尚需实测，不据预检查声称并发幂等。email格式、密码强度、注册限流、OTP一次性消费与失效策略尚未统一，见 AUTH-901/905；不得宣称这些安全增强已完成。

共同合成场景 `scenarios/auth-registration.json` 覆盖校验顺序、OTP状态、查重、bcrypt、提交后失败、有限数字转换和无Cookie；其中 `hashInterop` 保存由 Go、Rust 生成的长中文合成密码哈希，供三端交叉校验。极大指数等超出有限浮点范围的非典型 JSON 数值在各语言解析时仍可能不同，不能以有限样例声称所有数字输入完全一致。真实 Oracle、触发器、跨后端登录、时区、并发及两前端在最终隔离环境集中验收。合成用户和密码只用于测试。
