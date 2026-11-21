use axum::{
    body::{to_bytes, Body},
    http::Request,
};
use nekotribe_backend::{
    auth::{
        sessions::{
            build_native_router, CorsPolicy, SessionRepository, SessionStoreError, StoreFuture,
        },
        TokenClaims, TokenCodec,
    },
    moderation::{
        appeals::{Operation, Outcome},
        content_queue, dashboard, post_actions, reports, user_actions, user_queue,
    },
};
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use tower::ServiceExt;

#[derive(Default)]
struct Store {
    denied: AtomicBool,
    decision: Mutex<Option<(String, String)>>,
    report_reason: Mutex<Option<String>>,
    settings: Mutex<Option<(String, String)>>,
}

impl SessionRepository for Store {
    fn moderate_user(
        &self,
        actor: u64,
        input: user_actions::Input,
        _storage: nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'_, user_actions::Outcome> {
        Box::pin(async move {
            use user_actions::Outcome::*;
            assert_eq!(actor, 42);
            match input.id {
                99 => return Ok(Missing),
                9 | 10 => return Ok(InvalidState),
                _ => {}
            }
            if input.action == "mute" && input.hours == Some(3) {
                assert_eq!(input.note, "reviewed");
            }
            if input.action == "ban" && input.hours == Some(4) {
                return Err(SessionStoreError);
            }
            let (status, active) = if input.action == "ban" {
                ("suspended", 0)
            } else {
                ("active", 1)
            };
            Ok(Applied(
                json!({"user_id":input.id,"status":status,"is_active":active}),
            ))
        })
    }
    fn moderate_posts(
        &self,
        actor: u64,
        input: post_actions::Input,
        _storage: nekotribe_backend::auth::storage_urls::StorageUrlPolicy,
    ) -> StoreFuture<'_, post_actions::Outcome> {
        Box::pin(async move {
            use post_actions::Outcome::*;
            assert_eq!(actor, 42);
            if input.posts.contains(&99) {
                return Ok(Missing);
            }
            match (input.action.as_str(), input.bulk) {
                ("claim", false) => Ok(ClaimDisabled),
                ("release", false) => Ok(Claimed),
                ("reject", false) if input.note.is_empty() => Ok(NoteRequired),
                ("reject", false) => {
                    assert_eq!(
                        (&input.note[..], &input.reason[..]),
                        ("Reviewed", "duplicate")
                    );
                    Ok(Applied(
                        json!({"post_id":81,"case_id":17,"status":"rejected"}),
                    ))
                }
                ("flag", false) => Ok(Applied(
                    json!({"post_id":81,"case_id":17,"status":"flagged"}),
                )),
                ("flag", true) => Err(SessionStoreError),
                ("approve", true) => {
                    assert_eq!(input.posts.into_iter().collect::<Vec<_>>(), vec![81, 82]);
                    Ok(Applied(json!({"processed_count":2})))
                }
                _ => Err(SessionStoreError),
            }
        })
    }
    fn moderation_content(
        &self,
        actor: u64,
        f: content_queue::Filters,
    ) -> StoreFuture<'_, (Vec<Value>, i64)> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            let spec: Value = serde_json::from_str(include_str!(
                "../contracts/scenarios/moderation-content-queue.json"
            ))
            .unwrap();
            let query = json!({"status":f.status,"priority":f.priority,"reason":f.reason,"q":f.search,
                "date_range":f.date,"sort":f.sort});
            for vector in spec["cases"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|v| v["status"] == 200)
            {
                let expected = &vector["query"];
                if query
                    .as_object()
                    .unwrap()
                    .iter()
                    .all(|(key, value)| value == &expected[key])
                    && expected["start_row"].as_f64() == Some(f.page.start)
                    && expected["end_row"].as_f64() == Some(f.page.end)
                {
                    let items=vector.get("item").map(|item| {
                        let reports: Vec<_> = item["report_ids"].as_array().unwrap().iter().map(|id| json!({"report_id":id})).collect();
                        let media: Vec<_> = item["media_ids"].as_array().unwrap().iter().map(|id| json!({"media_id":id})).collect();
                        json!({"case_id":item["case_id"],"post_id":item["post_id"],
                            "report_reasons":item["report_reasons"],"reports":reports,"media":media})
                    }).into_iter().collect();
                    return Ok((items, vector["meta"]["total"].as_i64().unwrap()));
                }
            }
            Err(SessionStoreError)
        })
    }
    fn moderation_users(&self, filters: user_queue::Filters) -> StoreFuture<'_, (Vec<Value>, i64)> {
        Box::pin(async move {
            let spec: Value = serde_json::from_str(include_str!(
                "../contracts/scenarios/moderation-user-queue.json"
            ))
            .unwrap();
            let query = json!({"status":filters.status,"q":filters.search,"sort":filters.sort});
            for vector in spec["cases"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|v| v["status"] == 200)
            {
                let expected = &vector["query"];
                if query["status"] == expected["status"]
                    && query["q"] == expected["q"]
                    && query["sort"] == expected["sort"]
                    && expected["start_row"].as_f64() == Some(filters.page.start)
                    && expected["end_row"].as_f64() == Some(filters.page.end)
                {
                    return Ok((
                        vector["data"].as_array().unwrap().clone(),
                        vector["meta"]["total"].as_i64().unwrap(),
                    ));
                }
            }
            Err(SessionStoreError)
        })
    }
    fn moderation_dashboard(&self, actor: u64, op: dashboard::Operation) -> StoreFuture<'_, Value> {
        Box::pin(async move {
            assert_eq!(actor, 42);
            if matches!(op, dashboard::Operation::Stats) {
                return Ok(
                    json!({"pending":2,"approved":3,"rejected":1,"flagged":2,"today_processed":6,
                    "avg_process_minutes":15,"open_reports":4,"appeal_success_rate":67}),
                );
            }
            let mut settings = self.settings.lock().unwrap();
            let current = settings.get_or_insert_with(|| ("24".into(), "true".into()));
            if let dashboard::Operation::Update(batch) = op {
                if !batch.is_empty() {
                    assert_eq!(batch.len(), 2);
                    let number = &batch["default_mute_hours"];
                    let boolean = &batch["require_note_on_reject"];
                    assert_eq!(number.kind, "number");
                    assert_eq!(boolean.kind, "boolean");
                    if number.value == "77" {
                        return Err(SessionStoreError);
                    }
                    *current = (number.value.clone(), boolean.value.clone());
                }
            }
            Ok(json!([
                {"key":"default_mute_hours","value":current.0},
                {"key":"require_note_on_reject","value":current.1}
            ]))
        })
    }
    fn touch<'a>(&'a self, claims: &'a TokenClaims) -> StoreFuture<'a, u64> {
        Box::pin(async move { Ok(u64::from(claims.user_id == 42)) })
    }
    fn revoke<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn revoke_others<'a>(&'a self, _: u64, _: &'a str) -> StoreFuture<'a, u64> {
        Box::pin(async { Ok(0) })
    }
    fn moderation_appeal(&self, viewer: u64, operation: Operation) -> StoreFuture<'_, Outcome> {
        Box::pin(async move {
            assert_eq!(viewer, 42);
            match operation {
                Operation::Authorize(_) => Ok(Outcome::Access(!self.denied.load(Ordering::SeqCst))),
                Operation::List { status, page, .. } => {
                    assert_eq!(status.as_deref(), Some("pending"));
                    assert_eq!((page.start, page.end), (3.0, 4.0));
                    Ok(Outcome::Listed(vec![], 2))
                }
                Operation::Decide {
                    id, status, reply, ..
                } => {
                    if id == 13 {
                        return Err(SessionStoreError);
                    }
                    if id != 12 {
                        return Ok(Outcome::Missing);
                    }
                    let mut decision = self.decision.lock().unwrap();
                    if let Some((previous_status, previous_reply)) = decision.as_ref() {
                        if previous_status != &status || previous_reply != &reply {
                            return Ok(Outcome::Conflict);
                        }
                    } else {
                        *decision = Some((status.clone(), reply.clone()));
                    }
                    Ok(Outcome::Decided(
                        json!({"appeal_id":id,"statement_id":9,"user":{"user_id":7},"appeal_status":status,"admin_response":reply}),
                    ))
                }
            }
        })
    }
    fn moderation_report(
        &self,
        viewer: u64,
        operation: reports::Operation,
    ) -> StoreFuture<'_, reports::Outcome> {
        Box::pin(async move {
            assert_eq!(viewer, 42);
            match operation {
                reports::Operation::Create { input, .. } => match input.target_id {
                    99 => Ok(reports::Outcome::Missing),
                    13 => Err(SessionStoreError),
                    30 => {
                        assert_eq!(input.target_type, "post");
                        assert_eq!(input.priority, "normal");
                        assert_eq!(input.description, "Detail");
                        assert_eq!(input.evidence_url, "/tweet/30");
                        let mut reason = self.report_reason.lock().unwrap();
                        if reason
                            .as_ref()
                            .is_some_and(|current| current != &input.reason)
                        {
                            Ok(reports::Outcome::Conflict)
                        } else {
                            *reason = Some(input.reason);
                            Ok(reports::Outcome::Created(json!({
                                "report_id": 15, "description": input.description, "evidence_url": input.evidence_url
                            })))
                        }
                    }
                    _ => Err(SessionStoreError),
                },
                reports::Operation::List { page, .. } => {
                    assert_eq!((page.start, page.end), (3.0, 4.0));
                    Ok(reports::Outcome::Listed(vec![], 2))
                }
                reports::Operation::Update { id, status, .. } => match id {
                    12 => Ok(reports::Outcome::Updated(
                        json!({"report_id":id,"status":status}),
                    )),
                    13 => Err(SessionStoreError),
                    _ => Ok(reports::Outcome::Missing),
                },
            }
        })
    }
}

#[tokio::test]
async fn shared_moderator_appeal_routes() {
    run_vectors(include_str!(
        "../contracts/scenarios/moderation-appeals.json"
    ))
    .await;
}

#[tokio::test]
async fn shared_moderator_report_routes() {
    run_vectors(include_str!(
        "../contracts/scenarios/moderation-reports.json"
    ))
    .await;
}

#[tokio::test]
async fn shared_moderation_dashboard_routes() {
    run_vectors(include_str!(
        "../contracts/scenarios/moderation-dashboard.json"
    ))
    .await;
}

#[tokio::test]
async fn shared_moderation_user_queue_routes() {
    run_vectors(include_str!(
        "../contracts/scenarios/moderation-user-queue.json"
    ))
    .await;
}

#[tokio::test]
async fn shared_moderation_content_queue_routes() {
    run_vectors(include_str!(
        "../contracts/scenarios/moderation-content-queue.json"
    ))
    .await;
}

#[tokio::test]
async fn shared_moderation_post_action_routes() {
    run_vectors(include_str!(
        "../contracts/scenarios/moderation-post-actions.json"
    ))
    .await;
}

#[tokio::test]
async fn shared_moderation_user_action_routes() {
    run_vectors(include_str!(
        "../contracts/scenarios/moderation-user-actions.json"
    ))
    .await;
}

async fn run_vectors(vectors: &str) {
    let tokens: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap();
    let token = tokens["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "access-hs256")
        .unwrap()["token"]
        .as_str()
        .unwrap();
    let codec = TokenCodec::new(
        tokens["keys"]["access"].as_str().unwrap().as_bytes(),
        tokens["keys"]["refresh"].as_str().unwrap().as_bytes(),
    )
    .unwrap();
    let store = Arc::new(Store::default());
    let app = build_native_router(
        codec,
        store.clone(),
        CorsPolicy::default(),
        Arc::new(|| 1_700_000_000),
    );
    let spec: Value = serde_json::from_str(vectors).unwrap();
    for vector in spec["cases"].as_array().unwrap() {
        store
            .denied
            .store(vector["denied"] == true, Ordering::SeqCst);
        let mut request = Request::builder()
            .method(vector["method"].as_str().unwrap())
            .uri(vector["path"].as_str().unwrap())
            .header("Content-Type", "application/json");
        if vector["status"] != 401 {
            request = request.header("Authorization", format!("Bearer {token}"));
        }
        let body = vector
            .get("body")
            .map_or_else(Body::empty, |data| Body::from(data.to_string()));
        let result = app
            .clone()
            .oneshot(request.body(body).unwrap())
            .await
            .unwrap();
        assert_eq!(
            u64::from(result.status().as_u16()),
            vector["status"].as_u64().unwrap(),
            "{}",
            vector["id"]
        );
        assert_eq!(result.headers()["Cache-Control"], "private, no-store");
        let data: Value =
            serde_json::from_slice(&to_bytes(result.into_body(), 8192).await.unwrap()).unwrap();
        if let Some(meta) = vector.get("meta") {
            if let Some(item) = vector.get("item") {
                let projected = &data["data"][0];
                for key in ["case_id", "post_id", "report_reasons"] {
                    assert_eq!(projected[key], item[key]);
                }
                let ids = |key: &str, id: &str| {
                    projected[key]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|item| item[id].clone())
                        .collect::<Vec<_>>()
                };
                assert_eq!(json!(ids("reports", "report_id")), item["report_ids"]);
                assert_eq!(json!(ids("media", "media_id")), item["media_ids"]);
            } else {
                assert_eq!(
                    data["data"],
                    vector.get("data").cloned().unwrap_or_else(|| json!([]))
                );
            }
            for key in ["page", "page_size", "total"] {
                assert_eq!(data["meta"][key].as_f64(), meta[key].as_f64());
            }
            assert_eq!(data["meta"]["has_next"], meta["has_next"]);
        }
        if vector.get("decision").is_some() {
            assert_eq!(data["data"]["appeal_id"], 12);
            assert_eq!(data["data"]["user"]["user_id"], 7);
            assert_eq!(data["data"]["appeal_status"], vector["decision"]);
            assert_eq!(data["data"]["admin_response"], vector["reply"]);
        }
        if let Some(status) = vector.get("expectStatus") {
            assert_eq!(data["data"]["report_id"], 12);
            assert_eq!(&data["data"]["status"], status);
        }
        if let Some(id) = vector.get("reportId") {
            assert_eq!(&data["data"]["report_id"], id);
            assert_eq!(data["data"]["description"], "Detail");
            assert_eq!(data["data"]["evidence_url"], "/tweet/30");
        }
        if let Some(stats) = vector.get("stats") {
            assert_eq!(&data["data"], stats);
        }
        if vector["method"] == "POST"
            && vector["path"]
                .as_str()
                .is_some_and(|path| path.starts_with("/api/v2/moderation/content/"))
        {
            if let Some(item) = vector.get("item") {
                assert_eq!(&data["data"], item);
            }
            if let Some(count) = vector.get("processed") {
                assert_eq!(&data["data"]["processed_count"], count);
            }
            if let Some(error) = vector.get("error") {
                assert_eq!(&data["message"], error);
            }
        }
        if vector["method"] == "POST"
            && vector["path"]
                .as_str()
                .is_some_and(|path| path.starts_with("/api/v2/moderation/users/"))
        {
            if let Some(item) = vector.get("item") {
                assert_eq!(&data["data"], item);
            }
            if let Some(error) = vector.get("error") {
                assert_eq!(&data["message"], error);
            }
        }
        if let Some(values) = vector.get("values") {
            let items = data["data"].as_array().unwrap();
            let mapped: serde_json::Map<String, Value> = items
                .iter()
                .map(|item| {
                    (
                        item["key"].as_str().unwrap().to_owned(),
                        item["value"].clone(),
                    )
                })
                .collect();
            assert_eq!(&Value::Object(mapped), values);
        }
    }
}
