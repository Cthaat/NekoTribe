interface registerPayload {
    email: "string", // 邮箱地址
    username: "string", // 用户名（3-20位字母数字下划线）
    password: "string", // 密码（8-32位，包含字母数字）
    confirmPassword: "string", // 确认密码
    displayName: "string", // 显示名称
    phone: "string", // 手机号（可选）
    birthDate: "string", // 生日（YYYY-MM-DD格式）（可选）
    agreeToTerms: "boolean", // 同意服务条款
    captcha: "string" // 验证码
}