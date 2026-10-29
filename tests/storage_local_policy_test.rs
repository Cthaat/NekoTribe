use nekotribe_backend::storage::local_policy::{
    normalize_local_key, parse_local_byte_range, StoragePolicyError,
};
use serde_json::Value;
#[test]
fn shared_storage_local_policy() {
    let vectors: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/storage-local-policy.json"
    ))
    .unwrap();
    for vector in vectors["cases"].as_array().unwrap() {
        let raw = vector["value"].as_str().unwrap();
        let expected = &vector["expected"];
        if vector["kind"] == "key" {
            let actual = normalize_local_key(raw);
            if expected["status"] == 400 {
                assert_eq!(
                    actual,
                    Err(StoragePolicyError::InvalidKey),
                    "{}",
                    vector["id"]
                )
            } else {
                assert_eq!(
                    actual.unwrap(),
                    expected["key"].as_str().unwrap(),
                    "{}",
                    vector["id"]
                )
            }
        } else {
            let actual = parse_local_byte_range(raw, vector["size"].as_u64().unwrap());
            if expected["status"] == 416 {
                assert_eq!(
                    actual,
                    Err(StoragePolicyError::InvalidRange),
                    "{}",
                    vector["id"]
                )
            } else {
                assert_eq!(
                    serde_json::to_value(actual.unwrap()).unwrap(),
                    expected["range"],
                    "{}",
                    vector["id"]
                )
            }
        }
    }
}
