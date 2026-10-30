use chrono::{DateTime, Datelike, TimeZone, Utc};

/// Construct a storage key from server-controlled identity and time only.
pub fn new_key<T: TimeZone>(
    user: u64,
    media_type: &str,
    extension: &str,
    now: DateTime<T>,
) -> Result<String, ()> {
    if user == 0 || user > i64::MAX as u64 {
        return Err(());
    }
    let bucket = match media_type {
        "image" | "gif" => "images",
        "video" => "videos",
        "audio" => "audio",
        "file" => "files",
        _ => return Err(()),
    };
    let extension = extension.to_ascii_lowercase();
    if !(2..=17).contains(&extension.len())
        || !extension.starts_with('.')
        || !extension[1..]
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
    {
        return Err(());
    }
    let now = now.with_timezone(&Utc);
    let key = format!(
        "posts/{bucket}/{user}/{:04}/{:02}/{}{extension}",
        now.year(),
        now.month(),
        uuid::Uuid::new_v4()
    );
    crate::storage::local_policy::normalize_local_key(&key).map_err(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn uses_utc_time_server_uuid_and_expected_buckets() {
        let time = chrono::FixedOffset::east_opt(8 * 3600)
            .unwrap()
            .with_ymd_and_hms(2026, 3, 1, 0, 30, 0)
            .unwrap();
        for (kind, bucket) in [
            ("image", "images"),
            ("gif", "images"),
            ("video", "videos"),
            ("audio", "audio"),
            ("file", "files"),
        ] {
            let key = new_key(42, kind, ".PNG", time).unwrap();
            let prefix = format!("posts/{bucket}/42/2026/02/");
            let name = key
                .strip_prefix(&prefix)
                .unwrap()
                .strip_suffix(".png")
                .unwrap();
            assert_eq!(uuid::Uuid::parse_str(name).unwrap().get_version_num(), 4);
        }
    }

    #[test]
    fn rejects_unsafe_keys_and_unsupported_kinds() {
        let now = chrono::Utc::now();
        for (user, kind, ext) in [
            (0, "file", ".txt"),
            (1, "other", ".txt"),
            (1, "file", "."),
            (1, "file", ".../x"),
            (1, "file", ".a b"),
            (1, "file", ".abcdefghijklmnopq"),
        ] {
            assert!(new_key(user, kind, ext, now).is_err());
        }
    }
}
