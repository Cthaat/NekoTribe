use axum::{http::StatusCode, response::IntoResponse, Json};

use crate::httpx::response::V2Response;

pub fn server_error_response() -> axum::response::Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(V2Response {
            code: 50001,
            message: "服务器内部错误".to_string(),
            data: None::<()>,
            meta: None,
        }),
    )
        .into_response()
}
