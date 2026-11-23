use axum::{
    body::Body,
    http::{header::HeaderName, HeaderValue, Request},
    middleware::Next,
    response::Response,
};
use std::{future::Future, sync::OnceLock};
use uuid::Uuid;

const REQUEST_ID_HEADER: HeaderName = HeaderName::from_static("x-request-id");

#[derive(Clone)]
pub(crate) struct RequestId(pub String);

tokio::task_local! { static CURRENT: Option<RequestId>; }

pub(crate) fn current() -> Option<RequestId> {
    CURRENT.try_with(Clone::clone).ok().flatten()
}

pub(crate) async fn scope<T>(id: Option<RequestId>, future: impl Future<Output = T>) -> T {
    CURRENT.scope(id, future).await
}

pub async fn request_id(mut request: Request<Body>, next: Next) -> Response {
    static PATTERN: OnceLock<regex::Regex> = OnceLock::new();
    let pattern = PATTERN.get_or_init(|| {
        regex::Regex::new(&crate::observability::contract().request_id_pattern)
            .expect("synchronized request ID pattern")
    });
    let all = request.headers().get_all(&REQUEST_ID_HEADER);
    let mut values = all.iter();
    let request_id = match (
        values.next().and_then(|header| header.to_str().ok()),
        values.next(),
    ) {
        (Some(value), None) if pattern.is_match(value) => value.to_owned(),
        _ => Uuid::new_v4().to_string(),
    };
    let header = HeaderValue::from_str(&request_id).expect("validated request ID");
    let id = RequestId(request_id);
    request
        .headers_mut()
        .insert(REQUEST_ID_HEADER, header.clone());
    request.extensions_mut().insert(id.clone());
    let mut response = scope(Some(id), next.run(request)).await;
    response.headers_mut().insert(REQUEST_ID_HEADER, header);
    response
}
