use nekotribe_backend::posts::update_request::parse_update_body;
use serde_json::Value;
#[test]
fn shared_post_update_request_vectors() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/post-update-request.json"
    ))
    .unwrap();
    for vector in fixture["cases"].as_array().unwrap() {
        let body = serde_json::to_vec(&vector["body"]).unwrap();
        let actual = parse_update_body(&body, "application/json");
        if vector["expected"]["status"] == 400 {
            let error = actual.unwrap_err();
            assert_eq!(
                error.body().message,
                vector["expected"]["message"].as_str().unwrap(),
                "{}",
                vector["id"]
            );
        } else {
            let input = actual.unwrap();
            let mut actual = serde_json::to_value(input).unwrap();
            if actual.get("location") == Some(&Value::String(String::new())) {
                actual["location"] = Value::Null;
            }
            let mut expected = vector["expected"]["input"].clone();
            normalize_numbers(&mut actual);
            normalize_numbers(&mut expected);
            assert_eq!(actual, expected, "{}", vector["id"]);
        }
    }
}

fn normalize_numbers(value: &mut Value) {
    match value {
        Value::Number(n) => {
            *value = Value::from(n.as_f64().unwrap());
        }
        Value::Array(a) => {
            for v in a {
                normalize_numbers(v)
            }
        }
        Value::Object(o) => {
            for v in o.values_mut() {
                normalize_numbers(v)
            }
        }
        _ => {}
    }
}
