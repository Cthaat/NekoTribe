const REDACTED_VALUE: &str = "[redacted]";
const SENSITIVE_KEYS: &[&str] = &[
    "access_token",
    "refresh_token",
    "token",
    "password",
    "new_password",
    "confirm_password",
    "authorization",
    "cookie",
    "secret",
    "client_secret",
    "code",
];

pub fn is_sensitive_key(key: &str) -> bool {
    let normalized = key.trim().to_ascii_lowercase();
    SENSITIVE_KEYS.contains(&normalized.as_str())
        || normalized.ends_with("_token")
        || normalized.ends_with("_secret")
        || normalized.contains("password")
}

pub fn redact_query_pairs<'a>(
    pairs: impl IntoIterator<Item = (&'a str, &'a str)>,
) -> Vec<(String, String)> {
    pairs
        .into_iter()
        .map(|(key, value)| {
            let sanitized = if is_sensitive_key(key) {
                REDACTED_VALUE
            } else {
                value
            };
            (key.to_string(), sanitized.to_string())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{is_sensitive_key, redact_query_pairs};

    #[test]
    fn redacts_token_password_and_secret_keys() {
        assert!(is_sensitive_key("password"));
        assert!(is_sensitive_key("refresh_token"));
        assert!(is_sensitive_key("client_secret"));
        assert!(!is_sensitive_key("page"));

        let pairs = redact_query_pairs([("password", "123456"), ("page", "2")]);
        assert_eq!(
            pairs,
            vec![
                ("password".to_string(), "[redacted]".to_string()),
                ("page".to_string(), "2".to_string())
            ]
        );
    }
}
