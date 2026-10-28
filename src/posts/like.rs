use crate::{
    auth::sessions::NativeState,
    httpx::{errors::ApiError, response::V2Response},
};
use axum::{
    extract::{Path, State},
    http::HeaderMap,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::{json, Map, Value};

#[derive(Clone, Debug, PartialEq)]
pub struct PostLikeOutcome {
    pub count: f64,
    pub inserted: bool,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoredLikeNotification {
    pub recipient: u64,
    pub id: u64,
    pub push_enabled: bool,
}

fn js_whitespace(c: char) -> bool {
    matches!(c,'\u{0009}'..='\u{000d}'|'\u{0020}'|'\u{00a0}'|'\u{1680}'|'\u{2000}'..='\u{200a}'|'\u{2028}'|'\u{2029}'|'\u{202f}'|'\u{205f}'|'\u{3000}'|'\u{feff}')
}
pub fn excerpt_json(content: Option<&str>) -> String {
    let Some(content) = content.filter(|s| !s.is_empty()) else {
        return "null".into();
    };
    let mut compact = String::new();
    let mut space = false;
    for ch in content.chars() {
        if js_whitespace(ch) {
            space = !compact.is_empty();
            continue;
        }
        if space {
            compact.push(' ');
            space = false
        }
        compact.push(ch);
    }
    let units: Vec<u16> = compact.encode_utf16().collect();
    if units.len() <= 160 {
        return serde_json::to_string(&compact).expect("string encoding");
    }
    let head = &units[..160];
    if (0xd800..=0xdbff).contains(&head[159]) {
        let mut prefix =
            serde_json::to_string(&String::from_utf16(&head[..159]).expect("valid prefix"))
                .expect("string encoding");
        prefix.pop();
        return format!("{prefix}\\u{:04x}...\"", head[159]);
    }
    serde_json::to_string(&(String::from_utf16(head).expect("valid prefix") + "..."))
        .expect("string encoding")
}

pub(crate) async fn add(
    State(state): State<NativeState>,
    Path(raw): Path<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let (viewer, id) = super::bookmark::interaction_identity(&state, &raw, &headers).await?;
    let result = state
        .repository
        .add_post_like(viewer, id)
        .await
        .map_err(|_| ApiError::server_error("服务器内部错误"))?
        .ok_or_else(|| ApiError::not_found("帖子不存在"))?;
    if result.inserted {
        if let Some(stored) = state
            .repository
            .prepare_post_like_notification(viewer, id)
            .await
            .map_err(|_| ApiError::server_error("服务器内部错误"))?
        {
            if let Some(mut notification) = state
                .repository
                .read_notification(stored.recipient, stored.id)
                .await
                .map_err(|_| ApiError::server_error("服务器内部错误"))?
            {
                crate::notifications::hydrate_notification(
                    &state,
                    stored.recipient,
                    &mut notification,
                )
                .await?;
                if stored.push_enabled {
                    let mut data = Map::new();
                    data.insert("notification".into(), notification);
                    data.insert("notification_type".into(), Value::String("like".into()));
                    let sent = match &state.notification_publisher {
                        Some(publisher) => publisher
                            .publish(stored.recipient, "notification_created", &data)
                            .await
                            .is_ok(),
                        None => false,
                    };
                    if !sent {
                        eprintln!("notification delivery unavailable");
                    }
                }
            }
        }
    }
    let mut response = Json(V2Response::ok(
        json!({"post_id":id,"is_liked":true,"likes_count":result.count}),
    ))
    .into_response();
    response.headers_mut().insert(
        axum::http::header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("private, no-store"),
    );
    Ok(response)
}
