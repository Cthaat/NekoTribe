use nekotribe_backend::{db::value::DbValue, users::settings_patch::parse};
use serde_json::json;

#[test]
fn shared_user_settings_patch_vectors() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/user-settings-patch.json"
    ))
    .unwrap();
    assert_eq!(fixture["id"], "USER-SETTINGS-PATCH");
    assert_eq!(fixture["cases"].as_array().unwrap().len(), 16);
    for case in fixture["cases"].as_array().unwrap() {
        let result = parse(&case["body"]);
        if let Some(error) = case.get("error").and_then(serde_json::Value::as_str) {
            assert_eq!(result.unwrap_err().to_string(), error, "{}", case["id"]);
        } else {
            let patch = result.unwrap();
            let fields: serde_json::Map<String, serde_json::Value> = patch
                .fields
                .iter()
                .map(|(key, value)| {
                    let value = match value {
                        DbValue::BoolNumber(v) => json!(i32::from(*v)),
                        _ => serde_json::to_value(value).unwrap(),
                    };
                    (key.clone(), value)
                })
                .collect();
            assert_eq!(
                serde_json::Value::Object(fields),
                case["fields"],
                "{}",
                case["id"]
            );
            assert_eq!(patch.publish_presence, case["presence"].as_bool().unwrap());
        }
    }
}

#[test]
fn hidden_presence_event_does_not_leak_last_seen() {
    let data = json!({"user_id":42,"online_status":"hidden","last_seen_at":"secret"});
    let body = nekotribe_backend::notification_events::encode_presence_event(
        data.as_object().unwrap(),
        "rust-test",
        1234,
    )
    .unwrap();
    let value: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(value["type"], "presence_update");
    assert_eq!(value["data"]["last_seen_at"], serde_json::Value::Null);
    assert_eq!(value["data"]["server_id"], "rust-test");
    assert_eq!(value["timestamp"], 1234);
}

#[test]
fn settings_patch_matches_known_input_boundaries() {
    let patch = parse(&json!({"show_online_status":"YES", "login_alerts":" true ", "ai_sentiment_top_k":"0xa", "ai_sentiment_model_id":"  "})).unwrap();
    assert!(patch.publish_presence);
    assert_eq!(
        patch.fields["show_online_status"],
        DbValue::BoolNumber(true)
    );
    assert_eq!(patch.fields["login_alerts"], DbValue::BoolNumber(false));
    assert_eq!(patch.fields["ai_sentiment_top_k"], DbValue::I64(10));
    assert_eq!(patch.fields["ai_sentiment_model_id"], DbValue::Null);
    assert!(parse(&json!({"two_factor_enabled":null})).is_err());
    assert!(parse(&json!({"profile_visibility":"PRIVATE"})).is_err());
    assert!(parse(&json!({"ai_sentiment_top_k":""})).is_err());
    assert!(parse(&json!({"ai_sentiment_model_id":"🐈".repeat(65)})).is_err());
    assert_eq!(
        parse(&json!({"ai_sentiment_top_k":"not-a-number"}))
            .unwrap()
            .fields["ai_sentiment_top_k"],
        DbValue::I64(3)
    );
}
