//! Public URL mapping for the native login profile. No file I/O occurs here.
use reqwest::Url;

#[derive(Clone, PartialEq, Eq)]
pub struct StorageUrlPolicy {
    public_base: String,
    base_url: String,
    cdn_base_url: String,
    invalid_credentials: bool,
    invalid_public_base: bool,
}

impl std::fmt::Debug for StorageUrlPolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("StorageUrlPolicy [redacted]")
    }
}

impl Default for StorageUrlPolicy {
    fn default() -> Self {
        Self::from_lookup(|_| None)
    }
}

fn trim_js(value: &str) -> &str {
    value.trim_matches(|c: char| (c.is_whitespace() && c != '\u{0085}') || c == '\u{feff}')
}

impl StorageUrlPolicy {
    pub(crate) fn site_base_url(&self) -> &str {
        &self.base_url
    }

    pub(crate) fn managed_key(&self, reference: &str) -> Result<Option<String>, ()> {
        if reference.is_empty() {
            return Ok(None);
        }
        if self.invalid_credentials || self.invalid_public_base {
            return Err(());
        }
        let prefixes = [
            format!("{}/", self.public_base),
            "/storage/".into(),
            "/uploads/".into(),
            "/upload/".into(),
        ];
        let find = |path: &str| -> Result<Option<String>, ()> {
            for prefix in &prefixes {
                if let Some(key) = path.strip_prefix(prefix) {
                    return crate::storage::local_policy::normalize_local_key(key)
                        .map(Some)
                        .map_err(|_| ());
                }
            }
            Ok(None)
        };
        if reference.starts_with('/') {
            return find(reference);
        }
        let base = if self.cdn_base_url.is_empty() {
            &self.base_url
        } else {
            &self.cdn_base_url
        };
        if base.is_empty() {
            return Ok(None);
        }
        if let (Ok(url), Ok(origin)) = (Url::parse(reference), Url::parse(&format!("{base}/"))) {
            if url.origin() == origin.origin() {
                return find(url.path());
            }
        }
        Ok(None)
    }
    pub fn from_lookup(mut lookup: impl FnMut(&str) -> Option<String>) -> Self {
        let value = |s: Option<String>| trim_js(s.as_deref().unwrap_or_default()).to_owned();
        let raw = value(lookup("STORAGE_PUBLIC_BASE")).replace('\\', "/");
        let invalid_public_base =
            (!raw.is_empty() && raw.trim_matches('/').is_empty()) || raw.starts_with("//");
        let raw = raw.trim_end_matches('/');
        let public_base = if raw.is_empty() {
            "/storage".to_owned()
        } else if raw.starts_with('/') {
            raw.to_owned()
        } else {
            format!("/{raw}")
        };
        let base_url = value(lookup("BASE_URL")).trim_end_matches('/').to_owned();
        let cdn_base_url = value(lookup("STORAGE_CDN_BASE_URL"))
            .trim_end_matches('/')
            .to_owned();
        let invalid_credentials = [&base_url, &cdn_base_url].iter().any(|value| {
            Url::parse(value).ok().is_some_and(|url| {
                !url.username().is_empty()
                    || url.password().is_some_and(|password| !password.is_empty())
            })
        });
        Self {
            public_base,
            base_url,
            cdn_base_url,
            invalid_credentials,
            invalid_public_base,
        }
    }

    pub fn normalize_avatar(&self, input: &str) -> Result<String, ()> {
        if self.invalid_credentials || self.invalid_public_base {
            return Err(());
        }
        let value = trim_js(input);
        let base = if self.cdn_base_url.is_empty() {
            &self.base_url
        } else {
            &self.cdn_base_url
        };
        let build = |key: &str| -> Result<String, ()> {
            let key = normalize_key(key)?;
            let relative = format!("{}/{key}", self.public_base);
            if base.is_empty() {
                return Ok(relative);
            }
            let base = Url::parse(&format!("{base}/")).map_err(|_| ())?;
            Ok(base.join(&relative).map_err(|_| ())?.to_string())
        };
        if value.is_empty() || value == "/default-avatar.png" || value == "default-avatar.png" {
            return build("default-avatar.png");
        }
        let prefixes = [
            format!("{}/", self.public_base),
            "/storage/".to_owned(),
            "/uploads/".to_owned(),
            "/upload/".to_owned(),
        ];
        for prefix in &prefixes {
            if let Some(key) = value.strip_prefix(prefix) {
                return build(key);
            }
        }
        if base.is_empty() {
            return Ok(value.to_owned());
        }
        if let (Ok(url), Ok(origin)) = (Url::parse(value), Url::parse(&format!("{base}/"))) {
            if url.origin() == origin.origin() {
                for prefix in &prefixes {
                    if let Some(key) = url.path().strip_prefix(prefix) {
                        return build(key);
                    }
                }
            }
        }
        Ok(value.to_owned())
    }
}

fn normalize_key(value: &str) -> Result<String, ()> {
    let input = value.replace('\\', "/");
    let input = input.trim_start_matches('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in input.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.pop().is_none() {
                    return Err(());
                }
            }
            _ => parts.push(part),
        }
    }
    if parts.is_empty() {
        return Err(());
    }
    let mut result = parts.join("/");
    if input.ends_with('/') {
        result.push('/');
    }
    Ok(result)
}
