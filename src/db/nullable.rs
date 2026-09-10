pub trait NullableExt {
    fn null_if_empty(self) -> Option<String>;
}

impl NullableExt for Option<String> {
    fn null_if_empty(self) -> Option<String> {
        self.and_then(|value| {
            let trimmed = value.trim().to_string();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        })
    }
}
