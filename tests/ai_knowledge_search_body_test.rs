use nekotribe_backend::ai::knowledge_search_body::parse;
use serde_json::Value;

#[test]
fn shared_vectors_and_byte_limits() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/ai-knowledge-search-body.json"
    ))
    .unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let actual = parse(case["body"].as_str().unwrap().as_bytes());
        if case["accepted"] == true {
            let input = actual.unwrap();
            assert_eq!(
                input.phrase.as_deref(),
                case["phrase"].as_str(),
                "{}",
                case["id"]
            );
            assert_eq!(input.skill_id, case["skill_id"].as_str(), "{}", case["id"]);
            assert_eq!(
                input.expected_sequence,
                case["expected_sequence"].as_i64(),
                "{}",
                case["id"]
            );
        } else {
            assert!(actual.is_err(), "{}", case["id"]);
        }
    }
    assert!(parse(&[0xff]).is_err());
    assert!(parse(&vec![b' '; 4097]).is_err());
    assert!(
        parse(
            serde_json::json!({"search_phrase":"猫".repeat(85)})
                .to_string()
                .as_bytes()
        )
        .is_ok()
    );
    assert!(
        parse(
            serde_json::json!({"search_phrase":"猫".repeat(86)})
                .to_string()
                .as_bytes()
        )
        .is_err()
    );
}
