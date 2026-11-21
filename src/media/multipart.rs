//! Bounded streaming multipart parser; the caller authenticates before invoking it.
use super::upload_transaction::PrivateScope;
use axum::body::Body;
use tokio::io::{AsyncSeekExt, AsyncWriteExt};

#[derive(Clone, Copy)]
pub struct Limits {
    pub file_bytes: u64,
    pub total_file_bytes: u64,
    pub field_bytes: u64,
    pub files: usize,
    pub fields: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            file_bytes: 500 << 20,
            total_file_bytes: 500 << 20,
            field_bytes: 20 << 20,
            files: 1000,
            fields: 1000,
        }
    }
}

#[derive(Debug)]
pub enum ParseError {
    Invalid,
    InvalidAccessScope,
    NoFile,
    Storage,
}

pub struct SelectedMedia {
    pub file: tokio::fs::File,
    pub(crate) temp_path: Option<tempfile::TempPath>,
    pub name: String,
    pub mime: String,
    pub size: u64,
    pub alt_text: String,
    pub description: String,
    pub private_scope: Option<PrivateScope>,
}

struct PartFile {
    file: tokio::fs::File,
    temp_path: Option<tempfile::TempPath>,
    name: String,
    mime: String,
    size: u64,
}

fn create_staged_file() -> std::io::Result<(std::fs::File, Option<tempfile::TempPath>)> {
    #[cfg(windows)]
    {
        let (file, path) = tempfile::NamedTempFile::new()?.into_parts();
        Ok((file, Some(path)))
    }
    #[cfg(not(windows))]
    {
        Ok((tempfile::tempfile()?, None))
    }
}

#[derive(Clone, Copy)]
enum ScopePolicy {
    Ignore,
    Optional,
    RequiredPrivate,
}

pub async fn parse(
    body: Body,
    boundary: &str,
    limits: Limits,
) -> Result<SelectedMedia, ParseError> {
    parse_fields(body, boundary, limits, "media", ScopePolicy::Optional).await
}

pub(crate) async fn parse_private(
    body: Body,
    boundary: &str,
    limits: Limits,
) -> Result<SelectedMedia, ParseError> {
    parse_fields(body, boundary, limits, "media", ScopePolicy::RequiredPrivate).await
}

pub(crate) async fn parse_with_alias(
    body: Body,
    boundary: &str,
    limits: Limits,
    alias: &str,
) -> Result<SelectedMedia, ParseError> {
    parse_fields(body, boundary, limits, alias, ScopePolicy::Ignore).await
}

async fn parse_fields(
    body: Body,
    boundary: &str,
    limits: Limits,
    alias: &str,
    scope_policy: ScopePolicy,
) -> Result<SelectedMedia, ParseError> {
    if boundary.is_empty()
        || limits.file_bytes == 0
        || limits.total_file_bytes == 0
        || limits.field_bytes == 0
        || limits.files == 0
        || limits.fields == 0
    {
        return Err(ParseError::Invalid);
    }
    // Bound multipart headers and framing as well as file and field contents.
    let body_limit = limits
        .total_file_bytes
        .checked_add(limits.field_bytes)
        .and_then(|n| n.checked_add(10 << 20))
        .ok_or(ParseError::Invalid)?;
    let constraints =
        multer::Constraints::new().size_limit(multer::SizeLimit::new().whole_stream(body_limit));
    let mut multipart = multer::Multipart::with_constraints(
        body.into_data_stream(),
        boundary.to_owned(),
        constraints,
    );
    let (mut primary, mut alternate) = (None, None);
    let (mut files, mut fields, mut total_files, mut total_fields) = (0usize, 0usize, 0u64, 0u64);
    let (mut alt_text, mut description, mut access_scope) = (None, None, None);
    while let Some(mut field) = multipart
        .next_field()
        .await
        .map_err(|_| ParseError::Invalid)?
    {
        let field_name = field.name().ok_or(ParseError::Invalid)?.to_owned();
        let filename = field.file_name().map(str::to_owned);
        if let Some(name) = filename {
            files += 1;
            if files > limits.files {
                return Err(ParseError::Invalid);
            }
            let mime = field
                .content_type()
                .map(ToString::to_string)
                .unwrap_or_default();
            let (temp, temp_path) = tokio::task::spawn_blocking(create_staged_file)
                .await
                .map_err(|_| ParseError::Storage)?
                .map_err(|_| ParseError::Storage)?;
            let mut file = tokio::fs::File::from_std(temp);
            let mut size = 0u64;
            while let Some(chunk) = field.chunk().await.map_err(|_| ParseError::Invalid)? {
                size = size
                    .checked_add(chunk.len() as u64)
                    .ok_or(ParseError::Invalid)?;
                total_files = total_files
                    .checked_add(chunk.len() as u64)
                    .ok_or(ParseError::Invalid)?;
                if size > limits.file_bytes || total_files > limits.total_file_bytes {
                    return Err(ParseError::Invalid);
                }
                file.write_all(&chunk)
                    .await
                    .map_err(|_| ParseError::Storage)?;
            }
            if size == 0 {
                return Err(ParseError::Invalid);
            }
            file.flush().await.map_err(|_| ParseError::Storage)?;
            let item = PartFile {
                file,
                temp_path,
                name,
                mime,
                size,
            };
            if field_name == "file" && primary.is_none() {
                primary = Some(item);
            } else if field_name == alias && alternate.is_none() {
                alternate = Some(item);
            }
        } else {
            fields += 1;
            if fields > limits.fields {
                return Err(ParseError::Invalid);
            }
            let target = match field_name.as_str() {
                "alt_text" if alt_text.is_none() => Some(&mut alt_text),
                "description" if description.is_none() => Some(&mut description),
                "access_scope"
                    if !matches!(scope_policy, ScopePolicy::Ignore) && access_scope.is_none() =>
                {
                    Some(&mut access_scope)
                }
                _ => None,
            };
            let mut value = Vec::new();
            while let Some(chunk) = field.chunk().await.map_err(|_| ParseError::Invalid)? {
                total_fields = total_fields
                    .checked_add(chunk.len() as u64)
                    .ok_or(ParseError::Invalid)?;
                if total_fields > limits.field_bytes {
                    return Err(ParseError::Invalid);
                }
                if target.is_some() {
                    value.extend_from_slice(&chunk);
                }
            }
            if let Some(target) = target {
                *target = Some(String::from_utf8_lossy(&value).into_owned());
            }
        }
    }
    let private_scope = match access_scope.as_deref() {
        None | Some("public") if !matches!(scope_policy, ScopePolicy::RequiredPrivate) => None,
        Some("chat") => Some(PrivateScope::Chat),
        Some("post") => Some(PrivateScope::Post),
        _ => return Err(ParseError::InvalidAccessScope),
    };
    let mut selected = primary.or(alternate).ok_or(ParseError::NoFile)?;
    selected
        .file
        .seek(std::io::SeekFrom::Start(0))
        .await
        .map_err(|_| ParseError::Storage)?;
    Ok(SelectedMedia {
        file: selected.file,
        temp_path: selected.temp_path,
        name: selected.name,
        mime: selected.mime,
        size: selected.size,
        alt_text: alt_text.unwrap_or_default(),
        description: description.unwrap_or_default(),
        private_scope,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use tokio::io::AsyncReadExt;

    fn fixture() -> Body {
        Body::from(concat!(
            "--boundary\r\nContent-Disposition: form-data; name=\"media\"; filename=\"alternate.txt\"\r\nContent-Type: text/plain\r\n\r\nalt\r\n",
            "--boundary\r\nContent-Disposition: form-data; name=\"alt_text\"\r\n\r\nfirst\r\n",
            "--boundary\r\nContent-Disposition: form-data; name=\"alt_text\"\r\n\r\nsecond\r\n",
            "--boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"primary.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n",
            "--boundary--\r\n"
        ))
    }

    #[tokio::test]
    async fn selects_primary_file_and_first_field_with_streamed_bytes() {
        let mut result = parse(fixture(), "boundary", Limits::default())
            .await
            .unwrap();
        assert_eq!(result.name, "primary.txt");
        assert_eq!(result.mime, "text/plain");
        assert_eq!(result.alt_text, "first");
        assert_eq!(result.size, 5);
        let mut data = Vec::new();
        result.file.read_to_end(&mut data).await.unwrap();
        assert_eq!(data, b"hello");
    }

    #[tokio::test]
    async fn rejects_oversized_and_truncated_requests() {
        let limits = Limits {
            file_bytes: 4,
            ..Limits::default()
        };
        assert!(matches!(
            parse(fixture(), "boundary", limits).await,
            Err(ParseError::Invalid)
        ));
        let limits = Limits {
            total_file_bytes: 7,
            ..Limits::default()
        };
        assert!(matches!(
            parse(fixture(), "boundary", limits).await,
            Err(ParseError::Invalid)
        ));
        let limits = Limits {
            field_bytes: 10,
            ..Limits::default()
        };
        assert!(matches!(
            parse(fixture(), "boundary", limits).await,
            Err(ParseError::Invalid)
        ));
        let body = Body::from("--boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a\"\r\n\r\nabc");
        assert!(matches!(
            parse(body, "boundary", Limits::default()).await,
            Err(ParseError::Invalid)
        ));
        let body = Body::from("--boundary--\r\n");
        assert!(matches!(
            parse(body, "boundary", Limits::default()).await,
            Err(ParseError::NoFile)
        ));
    }

    #[tokio::test]
    async fn selects_alternate_and_rejects_excess_part_counts() {
        let body = || {
            Body::from(concat!(
            "--boundary\r\nContent-Disposition: form-data; name=\"media\"; filename=\"a.txt\"\r\n\r\na\r\n",
            "--boundary\r\nContent-Disposition: form-data; name=\"media\"; filename=\"b.txt\"\r\n\r\nb\r\n",
            "--boundary--\r\n"
        ))
        };
        let selected = parse(body(), "boundary", Limits::default()).await.unwrap();
        assert_eq!(selected.name, "a.txt");
        let limits = Limits {
            files: 1,
            ..Limits::default()
        };
        assert!(matches!(
            parse(body(), "boundary", limits).await,
            Err(ParseError::Invalid)
        ));
    }
}
