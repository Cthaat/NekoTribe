use nekotribe_backend::{
    cache::redis::RedisPool,
    config::env::RedisConfig,
    notification_events::{
        encode_notification_event, NotificationPublisher, RedisNotificationPublisher,
        UserEventPublisher,
    },
};
use serde_json::{Map, Value};
use std::{
    io::{BufRead, BufReader, Read, Write},
    net::TcpListener,
    sync::mpsc,
    time::Duration,
};

#[test]
fn shared_notification_event_vectors() {
    let vectors: Value = serde_json::from_str(include_str!(
        "../contracts/scenarios/notification-event-vectors.json"
    ))
    .unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 8);
    for case in cases {
        let user = case["user_id"].as_u64().unwrap();
        let kind = case["type"].as_str().unwrap();
        let data = case["data"].as_object().unwrap();
        let server = case["server_id"].as_str().unwrap();
        let timestamp = case["timestamp"].as_i64().unwrap();
        let before = data.clone();
        let result = encode_notification_event(user, kind, data, server, timestamp);
        assert_eq!(
            result.is_ok(),
            case["valid"].as_bool().unwrap(),
            "{}",
            case["id"]
        );
        if let Ok((channel, payload)) = result {
            let event: Value = serde_json::from_str(&payload).unwrap();
            assert_eq!(channel, format!("ws:user:{user}"));
            assert_eq!(event["type"], kind);
            assert_eq!(event["timestamp"], timestamp);
            assert_eq!(event["data"]["server_id"], server);
            let mut expected = before.clone();
            expected.insert("server_id".into(), server.into());
            assert_eq!(event["data"], Value::Object(expected));
            assert_eq!(*data, before);
        }
    }
}

#[test]
fn notification_event_preserves_unpaired_utf16_metadata_without_internal_marker() {
    let data = Map::from_iter([
        ("notification_type".into(), "like".into()),
        (
            "notification".into(),
            serde_json::json!({"notification_id":12,"metadata":null,"__nekotribe_metadata_raw":r#"{"post_excerpt":"prefix\ud83d..."}"#}),
        ),
    ]);
    let (_, body) =
        encode_notification_event(42, "notification_created", &data, "server", 1).unwrap();
    assert!(
        body.contains(r#""metadata":{"post_excerpt":"prefix\ud83d..."}"#),
        "{body}"
    );
    assert!(!body.contains("__nekotribe_metadata_raw"));
}
#[tokio::test]
async fn unavailable_publisher_is_safe_and_never_claims_delivery() {
    let publisher = UserEventPublisher::new(RedisPool::degraded("synthetic-redis-secret"));
    let error = publisher
        .publish(42, "notification_created", &Map::new())
        .await
        .unwrap_err();
    assert_eq!(error.to_string(), "notification event unavailable");
}

#[tokio::test]
async fn redis_client_publishes_to_isolated_protocol_server() {
    for lazy in [false, true] {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (tx, rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let result = (|| -> Result<(String, String), String> {
                let (mut stream, _) = listener.accept().map_err(|_| "accept")?;
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .map_err(|_| "timeout")?;
                let mut reader = BufReader::new(stream.try_clone().map_err(|_| "clone")?);
                loop {
                    let mut header = String::new();
                    reader.read_line(&mut header).map_err(|_| "array")?;
                    let count = header
                        .strip_prefix('*')
                        .and_then(|s| s.trim().parse::<usize>().ok())
                        .filter(|n| *n > 0 && *n <= 32)
                        .ok_or("count")?;
                    let mut args = Vec::new();
                    for _ in 0..count {
                        let mut line = String::new();
                        reader.read_line(&mut line).map_err(|_| "bulk")?;
                        let n = line
                            .strip_prefix('$')
                            .and_then(|s| s.trim().parse::<usize>().ok())
                            .filter(|n| *n <= 100000)
                            .ok_or("length")?;
                        let mut bytes = vec![0; n + 2];
                        reader.read_exact(&mut bytes).map_err(|_| "body")?;
                        args.push(String::from_utf8(bytes[..n].to_vec()).map_err(|_| "utf8")?);
                    }
                    match args[0].to_ascii_uppercase().as_str() {
                        "HELLO" => stream
                            .write_all(b"-ERR unknown command 'HELLO'\r\n")
                            .map_err(|_| "reply")?,
                        "PUBLISH" => {
                            if args.len() != 3 {
                                return Err("bad publish".into());
                            };
                            stream.write_all(b":1\r\n").map_err(|_| "reply")?;
                            return Ok((args[1].clone(), args[2].clone()));
                        }
                        _ => stream.write_all(b"+OK\r\n").map_err(|_| "reply")?,
                    }
                }
            })();
            let _ = tx.send(result);
        });
        let config = RedisConfig {
            url: Some(format!("redis://{address}/0")),
            host: "127.0.0.1".into(),
            port: address.port(),
            db: 0,
            password: None,
        };
        let data = Map::from_iter([("notification_type".into(), "like".into())]);
        if lazy {
            let publisher = RedisNotificationPublisher::new(&config).unwrap();
            publisher
                .publish(42, "notification_created", &data)
                .await
                .unwrap();
        } else {
            let pool = tokio::time::timeout(Duration::from_secs(3), RedisPool::connect(&config))
                .await
                .unwrap();
            assert!(pool.is_available());
            let publisher = UserEventPublisher::new(pool);
            publisher
                .publish(42, "notification_created", &data)
                .await
                .unwrap();
        }
        let (channel, body) = rx.recv_timeout(Duration::from_secs(3)).unwrap().unwrap();
        assert_eq!(channel, "ws:user:42");
        let event: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(event["type"], "notification_created");
        assert_eq!(event["data"]["notification_type"], "like");
        worker.join().unwrap();
    }
}
