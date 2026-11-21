use crate::{
    auth::{
        session_list::{number, session_pagination, SessionPage},
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        value::DbValue,
    },
    direct_history::query,
    group_detail::{hydrate, GroupDetail, GROUP_COLUMNS, GROUP_FROM},
    httpx::errors::ApiError,
};
use axum::{
    extract::{OriginalUri, State},
    http::{header::CACHE_CONTROL, HeaderMap, HeaderValue},
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Value};

#[derive(Clone, Copy)]
pub enum Mode {
    Discover,
    Popular,
    Mine,
}
pub struct Request {
    pub mode: Mode,
    pub page: SessionPage,
    pub limit: f64,
    pub search: String,
    pub privacy: String,
    pub category: String,
}
pub enum Outcome {
    Found(Vec<Value>, u64),
    OwnerMissing,
}

const FILTER: &str = " AND (:privacy IS NULL OR g.privacy=:privacy)
 AND (:category IS NULL OR g.category=:category)
 AND (:search IS NULL OR LOWER(g.group_name) LIKE :search OR LOWER(g.description) LIKE :search)";
const ACTIVE: &str = " WHERE g.is_deleted=0 AND g.is_active=1";

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    request: Request,
    storage: &StorageUrlPolicy,
) -> Result<Outcome, DbError> {
    let viewer = DbValue::I64(i64::try_from(viewer).map_err(|_| DbError::SchemaNotReady)?);
    let mut binds = BindMap::from([("viewer_id".into(), viewer.clone())]);
    let mut from = format!("{GROUP_FROM}{ACTIVE}");
    let mut score = "CAST(NULL AS NUMBER)";
    let mut order = "g.member_count DESC,g.post_count DESC,g.created_at DESC,g.group_id DESC";
    let popular = matches!(request.mode, Mode::Popular);
    if popular {
        from.push_str(" AND g.privacy='public'");
        score = "ROUND(g.member_count*0.3+g.post_count*0.7,2)";
        order =
            "ROUND(g.member_count*0.3+g.post_count*0.7,2) DESC,g.member_count DESC,g.group_id DESC";
    } else {
        from.push_str(FILTER);
        if matches!(request.mode, Mode::Mine) {
            from.push_str(" AND m.status='active'");
            order = "m.joined_at DESC,g.group_id DESC";
        } else {
            from.push_str(" AND (g.privacy='public' OR m.status='active')");
        }
        let optional = |s: String| {
            if s.is_empty() {
                DbValue::Null
            } else {
                DbValue::String(s)
            }
        };
        let search = if request.search.is_empty() {
            DbValue::Null
        } else {
            DbValue::String(format!("%{}%", request.search))
        };
        binds.extend([
            ("privacy".into(), optional(request.privacy)),
            ("category".into(), optional(request.category)),
            ("search".into(), search),
        ]);
    }
    let total = if popular {
        0
    } else {
        query(
            conn,
            &format!("SELECT COUNT(*) AS total {from}"),
            binds.clone(),
        )?
        .first()
        .and_then(|r| r.get("TOTAL"))
        .and_then(DbValue::as_i64)
        .and_then(|n| u64::try_from(n).ok())
        .ok_or(DbError::SchemaNotReady)?
    };
    let (start, end) = if popular {
        (1.0, request.limit)
    } else {
        (request.page.start, request.page.end)
    };
    binds.extend([
        ("start_row".into(), DbValue::F64(start)),
        ("end_row".into(), DbValue::F64(end)),
    ]);
    let rows=query(conn,&format!("SELECT * FROM ({GROUP_COLUMNS},{score} AS activity_score,ROW_NUMBER() OVER (ORDER BY {order}) AS rn {from})
        WHERE rn BETWEEN :start_row AND :end_row ORDER BY rn"),binds)?;
    let mut items = Vec::with_capacity(rows.len());
    for row in &rows {
        let mut group = match hydrate(conn, viewer.clone(), row, storage)? {
            GroupDetail::Found(group) => group,
            GroupDetail::OwnerMissing => return Ok(Outcome::OwnerMissing),
            GroupDetail::Missing => return Err(DbError::SchemaNotReady),
        };
        if popular {
            group["activity_score"] = json!(match row.get("ACTIVITY_SCORE") {
                Some(DbValue::F64(n)) => *n,
                Some(DbValue::I64(n)) => *n as f64,
                _ => return Err(DbError::SchemaNotReady),
            });
        }
        items.push(group);
    }
    Ok(Outcome::Found(items, total))
}

async fn route(
    state: NativeState,
    uri: axum::http::Uri,
    headers: HeaderMap,
    mode: Mode,
) -> Response {
    let result=async {
        let viewer=crate::posts::bookmark::interaction_actor(&state,&headers).await?;
        let raw=uri.query().unwrap_or_default();
        let url=reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
        let get=|name:&str| {
            let mut values=url.query_pairs().filter(|(key,_)|key==name);
            match (values.next(),values.next()){(Some((_,v)),None)=>v.into_owned(),_=>String::new()}
        };
        let trim=|s:String|s.trim_matches(|c:char|(c.is_whitespace() && c!='\u{0085}')||c=='\u{feff}').to_owned();
        let popular=matches!(mode,Mode::Popular);
        let (search,privacy,category)=if popular {(String::new(),String::new(),String::new())}else{
            (trim(get("q")).to_lowercase(),get("privacy"),trim(get("category")))
        };
        if !matches!(category.as_str(),""|"tech"|"game"|"music"|"art"|"life"|"study"|"work"|"other"){
            return Err(ApiError::bad_request("category 参数错误"));
        }
        let page=session_pagination(raw);
        let limit=number(&get("limit")).unwrap_or(10.0).min(50.0);
        let request=Request{mode,page,limit,search,privacy,category};
        let (items,total)=match state.repository.list_groups(viewer,request,&state.storage_urls).await
            .map_err(|_|ApiError::server_error("服务器内部错误"))? {
            Outcome::Found(items,total)=>(items,total),
            Outcome::OwnerMissing=>return Err(ApiError::not_found("用户不存在")),
        };
        let meta=if popular{json!({"limit":limit})}else{
            json!({"page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end < total as f64})
        };
        Ok::<_,ApiError>(Json(json!({"code":200,"message":"success","data":items,"meta":meta})))
    }.await;
    let mut response = result.into_response();
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    response
}

pub(crate) async fn discover(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    route(state, uri, headers, Mode::Discover).await
}
pub(crate) async fn popular(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    route(state, uri, headers, Mode::Popular).await
}
pub(crate) async fn mine(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    headers: HeaderMap,
) -> Response {
    route(state, uri, headers, Mode::Mine).await
}
