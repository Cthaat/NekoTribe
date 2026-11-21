use crate::{
    ai::conversation_http::ModerationSettings,
    auth::{
        login::js_trim,
        session_list::{session_pagination, SessionPage},
        session_repository::{nullable_text, row_number, row_text},
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        value::DbValue,
    },
    direct_history::query,
    moderation::appeals::{authorized, private, server_error},
};
use axum::{
    extract::{OriginalUri, State},
    http::HeaderMap,
    response::Response,
    Extension, Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::OnceLock;

#[derive(Deserialize)]
struct Contract {
    sorts: Vec<String>,
    sql: String,
}

fn contract() -> &'static Contract {
    static SPEC: OnceLock<Contract> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/moderation-user-queue.json"
        ))
        .expect("valid moderation user queue contract")
    })
}

pub struct Filters {
    pub status: Option<String>,
    pub search: Option<String>,
    pub sort: String,
    pub page: SessionPage,
    pub storage: StorageUrlPolicy,
}

pub(crate) fn execute(conn: &oracle::Connection, f: Filters) -> Result<(Vec<Value>, i64), DbError> {
    read(conn, None, f)
}

pub(super) fn read(
    conn: &oracle::Connection,
    user_id: Option<i64>,
    f: Filters,
) -> Result<(Vec<Value>, i64), DbError> {
    let rows = query(
        conn,
        &contract().sql,
        BindMap::from([
            (
                "user_id".into(),
                user_id.map(DbValue::I64).unwrap_or(DbValue::Null),
            ),
            ("status".into(), DbValue::from_option_string(f.status)),
            ("q".into(), DbValue::from_option_string(f.search)),
            ("sort".into(), DbValue::String(f.sort)),
            ("start_row".into(), DbValue::F64(f.page.start)),
            ("end_row".into(), DbValue::F64(f.page.end)),
        ]),
    )?;
    let total = rows
        .first()
        .map(|row| row_number(row, "TOTAL"))
        .unwrap_or(0);
    let items=rows.iter().filter(|row| row_number(row,"USER_ID")>0).map(|row| {
        let avatar=f.storage.normalize_avatar(&row_text(row,"AVATAR_URL")).map_err(|_| DbError::SchemaNotReady)?;
        Ok(json!({
            "user_id":row_number(row,"USER_ID"),"username":row_text(row,"USERNAME"),
            "display_name":row_text(row,"DISPLAY_NAME"),"avatar_url":avatar,"email":row_text(row,"EMAIL"),
            "status":row_text(row,"STATUS"),"is_active":row_number(row,"IS_ACTIVE"),"is_verified":row_number(row,"IS_VERIFIED"),
            "followers_count":row_number(row,"FOLLOWERS_COUNT"),"posts_count":row_number(row,"POSTS_COUNT"),
            "likes_count":row_number(row,"LIKES_COUNT"),"report_count":row_number(row,"REPORT_COUNT"),
            "active_restriction":nullable_text(row,"ACTIVE_RESTRICTION"),"restriction_until":nullable_text(row,"RESTRICTION_UNTIL"),
            "created_at":row_text(row,"CREATED_AT"),"updated_at":row_text(row,"UPDATED_AT")
        }))
    }).collect::<Result<_,DbError>>()?;
    Ok((items, total))
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    settings: Option<Extension<ModerationSettings>>,
    headers: HeaderMap,
) -> Response {
    private(async {
        authorized(&state,&headers,settings).await?;
        let raw=uri.query().unwrap_or_default();
        let url=reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
        let value=|name:&str|{
            let mut values=url.query_pairs().filter(|(k,_)| k==name).map(|(_,v)| v);
            values.next().filter(|_| values.next().is_none()).map(|v| v.into_owned())
        };
        let page=session_pagination(raw);
        let filters=Filters{
            status:value("status").filter(|s| !s.is_empty() && s!="all"),
            search:value("q").map(|s| js_trim(&s).to_owned()).filter(|q| !q.is_empty()),
            sort:value("sort").filter(|s| contract().sorts.contains(s)).unwrap_or_else(|| "newest".into()),
            page,
            storage:state.storage_urls.clone(),
        };
        let (data,total)=state.repository.moderation_users(filters).await.map_err(|_| server_error())?;
        Ok(Json(json!({"code":200,"message":"moderation users listed","data":data,
            "meta":{"page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64}})))
    }.await)
}
