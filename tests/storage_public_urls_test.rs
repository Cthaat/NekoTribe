use nekotribe_backend::auth::storage_urls::StorageUrlPolicy;
use serde_json::Value;

#[test]
fn shared_storage_urls_match_nuxt() {
    let vectors: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/storage-public-urls.json"
    ))
    .unwrap();
    assert_eq!(vectors["id"], "STORAGE-PUBLIC-URLS");
    let cases = vectors["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 26);
    for case in cases {
        let env = case["env"].as_object().unwrap();
        let policy = StorageUrlPolicy::from_lookup(|key| {
            env.get(key).and_then(Value::as_str).map(str::to_owned)
        });
        let result = policy.normalize_avatar(case["input"].as_str().unwrap_or_default());
        if case["error"].as_bool() == Some(true) {
            assert!(result.is_err(), "{}", case["id"]);
        } else {
            assert_eq!(
                result.unwrap(),
                case["expected"].as_str().unwrap(),
                "{}",
                case["id"]
            );
        }
    }
}
