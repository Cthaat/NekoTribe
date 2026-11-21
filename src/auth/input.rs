use crate::httpx::errors::ApiError;
use std::sync::OnceLock;

pub(crate) fn require_new_email(value: &str) -> Result<(), ApiError> {
    static PATTERN: OnceLock<regex::Regex> = OnceLock::new();
    let pattern = PATTERN.get_or_init(|| {
        regex::Regex::new(
            r"^[A-Za-z0-9_'+\-.]*[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,}$",
        )
        .expect("fixed email pattern")
    });
    if value.starts_with('.') || value.contains("..") || !pattern.is_match(value) {
        return Err(ApiError::bad_request("邮箱格式错误"));
    }
    Ok(())
}

pub(crate) fn require_registration_name(value: &str, message: &str) -> Result<(), ApiError> {
    if value.encode_utf16().count() < 2 {
        return Err(ApiError::bad_request(message));
    }
    Ok(())
}

// Existing Nuxt new-password length semantics; login keeps legacy short passwords.
pub(crate) fn require_new_password(password: &str) -> Result<(), ApiError> {
    if password.encode_utf16().count() < 6 {
        return Err(ApiError::bad_request("密码至少需要6个字符"));
    }
    Ok(())
}
