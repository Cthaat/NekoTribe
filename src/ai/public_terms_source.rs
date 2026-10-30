//! Internal, versioned public terms data; callers supply authentication and deployment consistency.
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    InvalidCatalog,
    InvalidQuery,
    InvalidReference,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reference {
    pub kind: String,
    pub id: i64,
    pub version: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    pub kind: String,
    pub id: i64,
    pub version: String,
    pub key: String,
    pub locale: String,
    pub href: String,
    pub title: String,
    pub blocks: Vec<String>,
}
fn text(value: Option<&Value>) -> Result<&str, Error> {
    value
        .and_then(Value::as_str)
        .filter(|s| !crate::auth::login::js_trim(s).is_empty() && s.len() <= 65536)
        .ok_or(Error::InvalidCatalog)
}
fn version(id: i64, key: &str, locale: &str, href: &str, title: &str, blocks: &[String]) -> String {
    let mut hash = Sha256::new();
    hash.update(b"neko-ai-terms-v1\0");
    let values = [
        id.to_string(),
        key.into(),
        locale.into(),
        href.into(),
        title.into(),
        blocks.len().to_string(),
    ];
    for field in values.iter().chain(blocks.iter()) {
        hash.update(format!("{}:", field.len()).as_bytes());
        hash.update(field.as_bytes());
    }
    hex::encode(hash.finalize())
}
pub fn parse(input: &Value) -> Result<Vec<Source>, Error> {
    if input["id"] != "AI-PUBLIC-TERMS-CATALOG"
        || input["revision"] != 1
        || input["source"] != "i18n/locales/{locale}.json#auth.terms.sections"
    {
        return Err(Error::InvalidCatalog);
    }
    let documents = input["documents"]
        .as_array()
        .filter(|v| v.len() == 8)
        .ok_or(Error::InvalidCatalog)?;
    let mut result = Vec::new();
    for (li, locale) in ["zh", "en"].iter().enumerate() {
        for (index, section) in ["acceptance", "accounts", "conduct", "termination"]
            .iter()
            .enumerate()
        {
            let key = format!("terms.{section}");
            let href = format!("/{locale}/auth/terms#{section}");
            let matches: Vec<_> = documents
                .iter()
                .filter(|d| d["key"] == key && d["locale"] == *locale)
                .collect();
            if matches.len() != 1 || matches[0]["href"] != href {
                return Err(Error::InvalidCatalog);
            }
            let doc = matches[0];
            let title = text(doc.get("title"))?.to_owned();
            let expected = if *section == "conduct" { 5 } else { 1 };
            let blocks = doc
                .get("blocks")
                .and_then(Value::as_array)
                .filter(|b| b.len() == expected)
                .ok_or(Error::InvalidCatalog)?
                .iter()
                .map(|b| text(Some(b)).map(str::to_owned))
                .collect::<Result<Vec<_>, _>>()?;
            let id = (li * 4 + index + 1) as i64;
            let version = version(id, &key, locale, &href, &title, &blocks);
            result.push(Source {
                kind: "terms".into(),
                id,
                version,
                key,
                locale: (*locale).into(),
                href,
                title,
                blocks,
            });
        }
    }
    Ok(result)
}
pub fn discover(catalog: &[Source], query: &str, limit: usize) -> Result<Vec<Source>, Error> {
    let term = crate::auth::login::js_trim(query);
    if term.is_empty()
        || term.len() > 256
        || !(1..=20).contains(&limit)
        || term.chars().any(|c| c <= '\u{1f}' || c == '\u{7f}')
    {
        return Err(Error::InvalidQuery);
    }
    Ok(catalog
        .iter()
        .filter(|row| {
            row.title.contains(term) || row.blocks.iter().any(|block| block.contains(term))
        })
        .take(limit)
        .cloned()
        .collect())
}
pub fn hydrate(catalog: &[Source], refs: &[Reference]) -> Result<Vec<Source>, Error> {
    if refs.len() > 20 {
        return Err(Error::InvalidReference);
    }
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    for reference in refs {
        if reference.kind != "terms"
            || !(1..=999_999_999_999_999).contains(&reference.id)
            || reference.version.len() != 64
            || !reference
                .version
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || !seen.insert(reference.id)
        {
            return Err(Error::InvalidReference);
        }
        if let Some(row) = catalog
            .iter()
            .find(|row| row.id == reference.id && row.version == reference.version)
        {
            result.push(row.clone())
        }
    }
    Ok(result)
}
