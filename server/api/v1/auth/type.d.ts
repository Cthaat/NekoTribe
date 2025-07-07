// ========================== register.post ======================================

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

interface RegisterResponse extends Response {
    success: true,
    message: string,
    data: {
        
    }
    code: 200,
    timestamp: string
}

// ========================== get-verification.post ======================================

interface GetVerificationPayload {
    account: string // 账号
}

interface GetRandomCode {
    (length?: number): number
}

interface GetVerificationResponse extends Response {
    success: true,
    message: string,
    data: {
        account: string
    }
    code: 200,
    timestamp: string
}

// ========================== check-verification.post ======================================

interface CheckVerificationPayload {
    account: string // 账号
    code: string // 验证码
}

interface CheckVerificationResponse extends Response {
    success: true,
    message: string,
    data: {
        account: string
    }
    code: 200,
    timestamp: string
}