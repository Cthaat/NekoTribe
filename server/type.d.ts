interface Response {
    success: true,
    message: "string",
    data: {},
    code: 0,
    timestamp: "string"
}

interface ErrorResponse {
    success: false,
    message: "string",
    code: number,
    timestamp: "string"
}