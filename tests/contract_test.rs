use axum::body::Body;
use http::{Request, StatusCode};
use http_body_util::BodyExt;
use nekotribe_backend::{
    app::routes::build_router,
    config::env::AppConfig,
    httpx::{errors::ApiError, pagination::PageState, response::V2Response},
};
use serde_json::{json, Value};
use tower::ServiceExt;

async fn json_response(request: Request<Body>) -> (StatusCode, http::HeaderMap, Value) {
    let app = build_router(AppConfig::for_test());
    let response = app.oneshot(request).await.expect("router response");
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("body bytes")
        .to_bytes();
    let body = serde_json::from_slice::<Value>(&bytes).expect("json body");
    (status, headers, body)
}

#[tokio::test]
async fn health_endpoint_returns_existing_contract_and_security_headers() {
    let (status, headers, body) = json_response(
        Request::builder()
            .uri("/api/health")
            .body(Body::empty())
            .unwrap(),
    )
    .await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["status"], "ok");
    assert_eq!(body["service"], "nekotribe");
    assert!(body["timestamp"].as_str().unwrap().contains('T'));
    assert_eq!(
        headers["x-content-type-options"], "nosniff",
        "security header must match Nitro backend"
    );
    assert_eq!(headers["x-frame-options"], "DENY");
    assert_eq!(headers["referrer-policy"], "same-origin");
    assert_eq!(
        headers["permissions-policy"],
        "camera=(), microphone=(), geolocation=()"
    );
    assert!(headers.contains_key("x-request-id"));
}

#[tokio::test]
async fn unmatched_v2_route_returns_40404_envelope() {
    let (status, _, body) = json_response(
        Request::builder()
            .uri("/api/v2/not-exists")
            .body(Body::empty())
            .unwrap(),
    )
    .await;

    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(
        body,
        json!({
            "code": 40404,
            "message": "API route not found",
            "data": null,
            "meta": null
        })
    );
}

#[test]
fn v2_response_helpers_keep_code_message_data_meta_shape() {
    let response = V2Response::ok(json!({ "user_id": 100001 }));
    let serialized = serde_json::to_value(response).unwrap();

    assert_eq!(
        serialized,
        json!({
            "code": 200,
            "message": "success",
            "data": { "user_id": 100001 },
            "meta": null
        })
    );

    let null_response = V2Response::null("已退出登录");
    assert_eq!(
        serde_json::to_value(null_response).unwrap(),
        json!({
            "code": 200,
            "message": "已退出登录",
            "data": null,
            "meta": null
        })
    );
}

#[test]
fn page_state_matches_existing_v2_page_bounds() {
    let default_page = PageState::from_query(None, None);
    assert_eq!(default_page.page, 1);
    assert_eq!(default_page.page_size, 20);
    assert_eq!(default_page.start_row, 1);
    assert_eq!(default_page.end_row, 20);

    let clamped = PageState::from_query(Some("-10"), Some("200"));
    assert_eq!(clamped.page, 1);
    assert_eq!(clamped.page_size, 100);
    assert_eq!(clamped.start_row, 1);
    assert_eq!(clamped.end_row, 100);

    let second_page = PageState::from_query(Some("2"), Some("30"));
    assert_eq!(second_page.start_row, 31);
    assert_eq!(second_page.end_row, 60);
}

#[test]
fn api_error_maps_status_code_and_body_contract() {
    let error = ApiError::route_not_found();
    assert_eq!(error.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        serde_json::to_value(error.body()).unwrap(),
        json!({
            "code": 40404,
            "message": "API route not found",
            "data": null,
            "meta": null
        })
    );
}
