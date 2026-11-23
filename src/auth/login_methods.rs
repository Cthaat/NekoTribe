use crate::{
    auth::{
        session_repository::TOUCH_SQL,
        sessions::{access_token, NativeState},
        TokenClaims, TokenKind,
    },
    db::{
        oracle::{BindMap, DbError},
        row::DbRow,
        tx::Transaction,
        value::DbValue,
    },
    httpx::errors::ApiError,
};
use http::HeaderMap;
use std::sync::OnceLock;

pub(super) async fn access_claims(
    state: &NativeState,
    headers: &HeaderMap,
) -> Result<TokenClaims, ApiError> {
    let token = access_token(headers);
    let claims = state
        .codec
        .verify(&token, TokenKind::Access, (state.clock)())
        .map_err(|_| ApiError::unauthorized("请先登录"))?;
    if state.repository.touch(&claims).await.unwrap_or_default() != 1 {
        return Err(ApiError::unauthorized("Token无效或已过期"));
    }
    Ok(claims)
}

pub(super) fn active_session(tx: &impl Transaction, claims: &TokenClaims) -> Result<bool, DbError> {
    let binds = BindMap::from([
        ("user_id".into(), DbValue::I64(claims.user_id as i64)),
        (
            "session_id".into(),
            DbValue::String(claims.session_id.clone()),
        ),
        ("access_jti".into(), DbValue::String(claims.jti.clone())),
    ]);
    Ok(tx.execute(TOUCH_SQL, binds)? == 1)
}

pub(super) fn has_password(owner: &DbRow) -> bool {
    static PASSWORD: OnceLock<regex::Regex> = OnceLock::new();
    let pattern = PASSWORD.get_or_init(|| {
        regex::Regex::new(crate::auth::passkey::password_hash_pattern())
            .expect("synchronized password hash pattern")
    });
    owner
        .get("PASSWORD_HASH")
        .and_then(DbValue::as_str)
        .is_some_and(|hash| pattern.is_match(hash))
}

pub(super) fn missing_table(error: &DbError) -> bool {
    matches!(error, DbError::Oracle(err) if err.db_error().is_some_and(|detail| detail.code() == 942))
}
