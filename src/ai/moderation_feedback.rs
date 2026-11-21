use super::conversation_store::Error;
use oracle::{sql_type::ToSql, Connection, ErrorKind};
use serde::Deserialize;
use std::sync::OnceLock;

#[derive(Deserialize)]
pub(super) struct Queries {
    pub schema: String,
    pub lock: String,
    pub message: String,
    pub read: String,
    pub save: String,
}

#[derive(Deserialize)]
struct Contract {
    ratings: Vec<String>,
    queries: Queries,
}

fn contract() -> &'static Contract {
    static CONTRACT: OnceLock<Contract> = OnceLock::new();
    CONTRACT.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/ai-moderation-feedback.json"
        ))
        .expect("valid moderation feedback contract")
    })
}

pub(super) fn queries() -> &'static Queries {
    &contract().queries
}

pub(super) fn valid_rating(rating: &str) -> bool {
    contract().ratings.iter().any(|option| option == rating)
}

pub(super) fn parse_rating(body: &[u8]) -> Option<String> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Request {
        rating: String,
    }
    if body.iter().copied().find(|byte| !byte.is_ascii_whitespace()) != Some(b'{') {
        return None;
    }
    let request: Request = serde_json::from_slice(body).ok()?;
    valid_rating(&request.rating).then_some(request.rating)
}

pub(super) fn optional_text(
    connection: &Connection,
    query: &str,
    values: &[(&str, &dyn ToSql)],
) -> Result<Option<String>, Error> {
    match connection.query_row_as_named::<String>(query, values) {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == ErrorKind::NoDataFound => Ok(None),
        Err(_) => Err(Error::SchemaUnavailable),
    }
}

pub(super) fn table_present(connection: &Connection) -> Result<bool, Error> {
    Ok(optional_text(connection, &queries().schema, &[])?.is_some())
}

pub(super) fn read_rating(connection: &Connection, id: &str) -> Result<Option<String>, Error> {
    let rating = optional_text(connection, &queries().read, &[("message_id", &id)])?;
    if rating.as_deref().is_some_and(|value| !valid_rating(value)) {
        return Err(Error::SchemaUnavailable);
    }
    Ok(rating)
}
