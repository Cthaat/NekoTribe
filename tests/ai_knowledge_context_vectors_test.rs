use nekotribe_backend::ai::knowledge_context::{select, ContextError};
use serde_json::{json, Value};

#[test]
fn matches_shared_cross_backend_history_vectors() {
    let vectors: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-knowledge-context-vectors.json"
    ))
    .unwrap();
    for row in vectors["cases"].as_array().unwrap() {
        let id = row["id"].as_str().unwrap();
        let result = select(
            row["messages"].as_array().unwrap(),
            row["max_bytes"].as_u64().unwrap() as usize,
            row["max_sources"].as_u64().unwrap() as usize,
        );
        if let Some(error) = row.get("error").and_then(Value::as_str) {
            let expected = if error == "CONTEXT_TOO_LARGE" {
                ContextError::TooLarge
            } else {
                ContextError::Invalid
            };
            assert_eq!(result.unwrap_err(), expected, "{id}");
        } else {
            let result = result.unwrap();
            assert_eq!(
                json!({"question":result.question,"history":result.history,"sources":result.sources}),
                row["expected"],
                "{id}"
            );
        }
    }
}
