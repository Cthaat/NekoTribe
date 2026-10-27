use nekotribe_backend::ai::model_config::ModelRouter;
use serde_json::{json, Value};

fn cases() -> Vec<Value> {
    let fixture: Value =
        serde_json::from_str(include_str!("../contracts/scenarios/ai-model-config.json")).unwrap();
    fixture["cases"].as_array().unwrap().clone()
}

fn base() -> Value {
    cases()[0]["config"].clone()
}

#[test]
fn shared_52_configuration_scenarios() {
    let fixtures = cases();
    assert_eq!(fixtures.len(), 52);
    for case in fixtures {
        let run = || {
            let router = ModelRouter::new(&case["config"])?;
            let required: Vec<&str> = case["requiredCapabilities"]
                .as_array()
                .map(|items| items.iter().map(|item| item.as_str().unwrap()).collect())
                .unwrap_or_default();
            let role = case["role"].as_str().unwrap();
            if case["action"] == "replace" {
                let old = router.select(role, &[])?;
                if let Err(error) = router.replace(
                    &case["nextConfig"],
                    case["expectedRevision"].as_u64().unwrap(),
                ) {
                    assert_eq!(
                        serde_json::to_value(router.select(role, &[]).unwrap()).unwrap(),
                        case["expectedAfterError"],
                        "{}",
                        case["id"]
                    );
                    return Err(error);
                }
                assert_eq!(old.configuration_revision, 1);
            }
            let mut selection = router.select(role, &required)?;
            if case["action"] == "isolation" {
                selection.model = "mutated".into();
                selection.capabilities.clear();
                selection = router.select(role, &required)?;
            }
            Ok(serde_json::to_value(selection).unwrap())
        };
        match run() {
            Ok(snapshot) => assert_eq!(snapshot, case["expected"], "{}", case["id"]),
            Err(error) => assert_eq!(
                error.code(),
                case["expectedError"].as_str().unwrap_or("success"),
                "{}",
                case["id"]
            ),
        }
    }
}

#[test]
fn strict_schema_types_urls_and_safe_errors() {
    let changes = [
        (
            "/providers/0/baseUrl",
            json!("http://user:SECRET@example.test"),
        ),
        ("/providers/0/baseUrl", json!("http://@example.test")),
        ("/providers/0/baseUrl", json!("http://example.test:0")),
        ("/providers/0/baseUrl", json!("http://example.test:65536")),
        ("/providers/0/baseUrl", json!("http:///example.test")),
        ("/providers/0/baseUrl", json!("http://example.test?SECRET")),
        ("/providers/0/baseUrl", json!("http://example.test#SECRET")),
        ("/providers/0/baseUrl", json!("http://example.test/ space")),
        ("/providers/0/apiKeyEnv", json!("bad-secret")),
        ("/models/0/contextWindowTokens", json!(4096.5)),
        ("/models/0/maxOutputTokens", json!(2147483648u64)),
        ("/models/0/model", json!(" x")),
        ("/models/0/model", json!("猫".repeat(257))),
        ("/revision", json!(9007199254740992u64)),
        ("/schemaVersion", json!(true)),
    ];
    for (path, value) in changes {
        let mut config = base();
        if path.ends_with("apiKeyEnv") {
            config["providers"][0]["apiKeyEnv"] = value;
        } else {
            *config.pointer_mut(path).unwrap() = value;
        }
        let error = ModelRouter::new(&config).err().expect(path);
        assert_eq!(error.to_string(), "INVALID_CONFIGURATION", "{path}");
        assert!(!format!("{error:?}").contains("SECRET"));
    }
    for path in ["", "/providers/0", "/models/0", "/bindings"] {
        let mut config = base();
        config
            .pointer_mut(path)
            .unwrap()
            .as_object_mut()
            .unwrap()
            .insert("apiKey".into(), json!("SECRET"));
        assert!(ModelRouter::new(&config).is_err());
    }
}

#[test]
fn replace_checks_revision_first_and_preserves_snapshots() {
    let mut config = base();
    let router = ModelRouter::new(&config).unwrap();
    let old = router.select("knowledge", &[]).unwrap();
    config["models"][0]["model"] = json!("new/model");
    config["revision"] = json!(2);
    assert_eq!(
        router.replace(&Value::Null, 0).unwrap_err().code(),
        "STALE_CONFIGURATION"
    );
    router.replace(&config, 1).unwrap();
    assert_eq!(old.model, "test/local-v1");
    assert_eq!(router.select("knowledge", &[]).unwrap().model, "new/model");
    assert_eq!(
        router.replace(&config, 2).unwrap_err().code(),
        "REVISION_REUSED"
    );
    assert_eq!(
        router.replace(&Value::Null, 2).unwrap_err().code(),
        "INVALID_CONFIGURATION"
    );
    assert_eq!(
        router
            .select("knowledge", &[])
            .unwrap()
            .configuration_revision,
        2
    );
    assert_eq!(
        router
            .select("agent", &["tools", "tools"])
            .unwrap_err()
            .code(),
        "UNSUPPORTED_CAPABILITY"
    );
    assert_eq!(
        router.select("agent", &["unknown"]).unwrap_err().code(),
        "UNSUPPORTED_CAPABILITY"
    );
}

#[test]
fn integral_numbers_empty_reference_and_input_isolation() {
    let mut config = base();
    config["schemaVersion"] = json!(1.0);
    config["revision"] = json!(1.0);
    config["models"][0]["contextWindowTokens"] = json!(4096.0);
    config["models"][0]["maxOutputTokens"] = json!(512.0);
    config["providers"][0]["apiKeyEnv"] = json!("");
    config["providers"][0]["baseUrl"] = json!("http://EXAMPLE.test:80/v1///");
    config["models"][0]["model"] = json!("猫".repeat(256));
    let router = ModelRouter::new(&config).unwrap();
    config["models"][0]["model"] = json!("changed-input");
    let selected = router.select("knowledge", &[]).unwrap();
    assert_eq!(selected.model, "猫".repeat(256));
    assert_eq!(selected.api_key_env, None);
    assert_eq!(selected.base_url, "http://EXAMPLE.test:80/v1");
    assert_eq!(
        serde_json::to_value(selected).unwrap()["apiKeyEnv"],
        Value::Null
    );
    config["revision"] = json!("1");
    assert!(ModelRouter::new(&config).is_err());
}

#[test]
fn concurrent_readers_and_competing_writers_observe_complete_configurations() {
    use std::sync::{Arc, Barrier};
    let router = Arc::new(ModelRouter::new(&base()).unwrap());
    let barrier = Arc::new(Barrier::new(9));
    let threads: Vec<_> = (0..8)
        .map(|index| {
            let router = Arc::clone(&router);
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                let mut next = base();
                next["revision"] = json!(2);
                next["models"][0]["model"] = json!(format!("winner-{index}"));
                barrier.wait();
                let result = router.replace(&next, 1);
                for _ in 0..50 {
                    let selection = router.select("knowledge", &[]).unwrap();
                    assert_eq!(selection.configuration_revision, 2);
                    assert!(selection.model.starts_with("winner-"));
                    assert_eq!(selection.provider_id, "local");
                }
                result
            })
        })
        .collect();
    barrier.wait();
    let results: Vec<_> = threads
        .into_iter()
        .map(|thread| thread.join().unwrap())
        .collect();
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    for error in results.into_iter().filter_map(Result::err) {
        assert_eq!(error.code(), "STALE_CONFIGURATION");
    }
}
