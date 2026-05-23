use axum::{http::StatusCode, response::IntoResponse, Json};

use crate::httpx::response::{V2NullResponse, V2Response};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{message}")]
pub struct ApiError {
    status: StatusCode,
    code: i32,
    message: String,
}

impl ApiError {
    pub fn new(status: StatusCode, code: i32, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }

    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, 40001, message)
    }

    pub fn unauthorized(message: impl Into<String>) -> Self {
        Self::new(StatusCode::UNAUTHORIZED, 40101, message)
    }

    pub fn forbidden(message: impl Into<String>) -> Self {
        Self::new(StatusCode::FORBIDDEN, 40301, message)
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(StatusCode::NOT_FOUND, 40401, message)
    }

    pub fn conflict(message: impl Into<String>) -> Self {
        Self::new(StatusCode::CONFLICT, 40901, message)
    }

    pub fn unprocessable(message: impl Into<String>) -> Self {
        Self::new(StatusCode::UNPROCESSABLE_ENTITY, 42201, message)
    }

    pub fn server_error(message: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, 50001, message)
    }

    pub fn route_not_found() -> Self {
        Self::new(StatusCode::NOT_FOUND, 40404, "API route not found")
    }

    pub fn status(&self) -> StatusCode {
        self.status
    }

    pub fn body(&self) -> V2NullResponse {
        V2Response {
            code: self.code,
            message: self.message.clone(),
            data: None,
            meta: None,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (self.status, Json(self.body())).into_response()
    }
}
