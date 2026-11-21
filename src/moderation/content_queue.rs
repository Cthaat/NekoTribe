use crate::{
    ai::conversation_http::ModerationSettings,
    auth::{
        login::js_trim,
        session_list::{session_pagination, SessionPage},
        session_repository::{
            media_json, public_profile_json, row_number, row_text, POST_MEDIA_SQL,
        },
        sessions::NativeState,
        storage_urls::StorageUrlPolicy,
    },
    db::{
        oracle::{BindMap, DbError},
        value::DbValue,
    },
    direct_history::query,
    group_content::user,
    moderation::{
        appeals::{authorized, private, server_error},
        reports,
    },
    media::normalize_attachment_urls,
};
use axum::{
    extract::{OriginalUri, State},
    http::HeaderMap,
    response::Response,
    Extension, Json,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{BTreeSet, HashMap},
    sync::OnceLock,
};

#[derive(Deserialize)]
struct Contract {
    statuses: Vec<String>,
    priorities: Vec<String>,
    dates: Vec<String>,
    sorts: Vec<String>,
    sql: HashMap<String, String>,
}

fn contract() -> &'static Contract {
    static SPEC: OnceLock<Contract> = OnceLock::new();
    SPEC.get_or_init(|| {
        serde_json::from_str(include_str!(
            "../../contracts/requirements/moderation-content-queue.json"
        ))
        .expect("valid moderation content queue contract")
    })
}

pub struct Filters {
    pub status: Option<String>,
    pub priority: Option<String>,
    pub reason: Option<String>,
    pub search: Option<String>,
    pub date: String,
    pub sort: String,
    pub page: SessionPage,
    pub storage: StorageUrlPolicy,
}

pub(crate) fn execute(
    conn: &oracle::Connection,
    viewer: u64,
    f: Filters,
) -> Result<(Vec<Value>, i64), DbError> {
    read(conn, viewer, None, f)
}

pub(super) fn read(
    conn: &oracle::Connection,
    viewer: u64,
    post_id: Option<i64>,
    f: Filters,
) -> Result<(Vec<Value>, i64), DbError> {
    let viewer = viewer as i64;
    let spec = contract();
    let rows = query(
        conn,
        &spec.sql["list"],
        BindMap::from([
            (
                "post_id".into(),
                post_id.map(DbValue::I64).unwrap_or(DbValue::Null),
            ),
            ("status".into(), DbValue::from_option_string(f.status)),
            ("reason".into(), DbValue::from_option_string(f.reason)),
            ("priority".into(), DbValue::from_option_string(f.priority)),
            ("q".into(), DbValue::from_option_string(f.search)),
            ("sort".into(), DbValue::String(f.sort)),
            ("date_range".into(), DbValue::String(f.date)),
            ("viewer_id".into(), DbValue::I64(viewer)),
            ("start_row".into(), DbValue::F64(f.page.start)),
            ("end_row".into(), DbValue::F64(f.page.end)),
        ]),
    )?;
    let total = rows
        .first()
        .map(|row| row_number(row, "TOTAL"))
        .unwrap_or(0);
    let mut items = Vec::new();
    for row in rows.iter().filter(|row| row_number(row, "CASE_ID") > 0) {
        let post_id = row_number(row, "POST_ID");
        let mut author = public_profile_json(row);
        author["avatar_url"] = f
            .storage
            .normalize_avatar(&row_text(row, "AVATAR_URL"))
            .map_err(|_| DbError::SchemaNotReady)?
            .into();
        let assigned_id = row_number(row, "ASSIGNED_TO");
        let assigned = if assigned_id > 0 {
            user(conn, viewer, assigned_id, &f.storage)?
        } else {
            None
        };
        let media_rows = query(
            conn,
            POST_MEDIA_SQL,
            BindMap::from([("post_id".into(), DbValue::I64(post_id))]),
        )?;
        let media = media_rows
            .iter()
            .map(|row| {
                let mut item = media_json(row);
                normalize_attachment_urls(&f.storage, &mut item).map_err(|_| DbError::SchemaNotReady)?;
                Ok(item)
            })
            .collect::<Result<Vec<_>, DbError>>()?;
        let report_rows = query(
            conn,
            &spec.sql["reports"],
            BindMap::from([
                ("target_type".into(), DbValue::String("post".into())),
                ("target_id".into(), DbValue::I64(post_id)),
            ]),
        )?;
        let reports = report_rows
            .iter()
            .map(|r| reports::map(conn, viewer, r, &f.storage))
            .collect::<Result<Vec<_>, _>>()?;
        let reasons = reports
            .iter()
            .filter_map(|r| r["reason"].as_str())
            .collect::<BTreeSet<_>>();
        items.push(json!({
            "case_id":row_number(row,"CASE_ID"), "post_id":post_id,"content":row_text(row,"CONTENT"),
            "author":author,"assigned_to":assigned,"media":media,
            "report_count":row_number(row,"REPORT_COUNT"),"report_reasons":reasons,"reports":reports,
            "status":row_text(row,"STATUS"),"priority":row_text(row,"PRIORITY"),
            "created_at":row_text(row,"CREATED_AT"),"updated_at":row_text(row,"UPDATED_AT"),"reported_at":row_text(row,"REPORTED_AT"),
            "likes_count":row_number(row,"LIKES_COUNT_POST"),"retweets_count":row_number(row,"RETWEETS_COUNT"),"replies_count":row_number(row,"REPLIES_COUNT")
        }));
    }
    Ok((items, total))
}

pub(crate) async fn list(
    State(state): State<NativeState>,
    OriginalUri(uri): OriginalUri,
    settings: Option<Extension<ModerationSettings>>,
    headers: HeaderMap,
) -> Response {
    private(async {
        let viewer=authorized(&state,&headers,settings).await?;
        let raw=uri.query().unwrap_or_default();
        let url=reqwest::Url::parse(&format!("http://localhost/?{raw}")).expect("fixed URL");
        let value=|name:&str|{
            let mut vals=url.query_pairs().filter(|(k,_)| k==name).map(|(_,v)| v);
            vals.next().filter(|v| vals.next().is_none()&&!v.is_empty()).map(|v| v.into_owned())
        };
        let spec=contract();
        let page=session_pagination(raw);
        let filters=Filters{
            status:value("status").filter(|s|s!="all").map(|s| if spec.statuses.contains(&s){s}else{"pending".into()}),
            priority:value("priority").filter(|s|spec.priorities.contains(s)),
            reason:value("reason").filter(|s|s!="all").map(|s|if reports::recognized_reason(&s){s}else{"other".into()}),
            search:value("q").map(|s|js_trim(&s).to_owned()).filter(|s|!s.is_empty()),
            date:value("date_range").filter(|s|spec.dates.contains(s)).unwrap_or_else(||"all".into()),
            sort:value("sort").filter(|s|spec.sorts.contains(s)).unwrap_or_else(||"newest".into()),
            page,storage:state.storage_urls.clone(),
        };
        let (data,total)=state.repository.moderation_content(viewer, filters).await.map_err(|_|server_error())?;
        Ok(Json(json!({"code":200,"message":"moderation content listed","data":data,"meta":{
            "page":page.page,"page_size":page.page_size,"total":total,"has_next":page.end<total as f64
        }})))
    }.await)
}
