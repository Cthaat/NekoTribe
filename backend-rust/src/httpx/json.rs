use axum::{response::IntoResponse, Json};
use serde::Serialize;

use crate::httpx::response::V2Response;

pub fn ok<T>(data: T) -> impl IntoResponse
where
    T: Serialize,
{
    Json(V2Response::ok(data))
}
