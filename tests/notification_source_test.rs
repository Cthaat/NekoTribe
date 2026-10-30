use nekotribe_backend::{
    config::env::RedisConfig,
    notification_source::{NotificationSource, RedisNotificationSource},
};
use std::{
    io::{BufRead, BufReader, Read, Write},
    net::TcpListener,
    sync::mpsc,
    time::Duration,
};

#[tokio::test]
async fn redis_subscription_uses_authenticated_user_channel_and_closes_with_receiver() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        let result = (|| -> Result<String, String> {
            let (mut stream, _) = listener.accept().map_err(|_| "accept")?;
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .map_err(|_| "timeout")?;
            let mut reader = BufReader::new(stream.try_clone().map_err(|_| "clone")?);
            let mut subscribed_user = false;
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
                        .map_err(|_| "hello")?,
                    "SUBSCRIBE" => {
                        if args.len() != 2 {
                            return Err("bad subscribe".into());
                        }
                        let channel = args[1].clone();
                        if channel == "ws:user:42" && !subscribed_user {
                            subscribed_user = true;
                            let response = format!(
                                "*3\r\n$9\r\nsubscribe\r\n${}\r\n{}\r\n:1\r\n",
                                channel.len(),
                                channel
                            );
                            stream
                                .write_all(response.as_bytes())
                                .map_err(|_| "first ack")?;
                            let early =
                                b"{\"type\":\"notification_created\",\"data\":{},\"timestamp\":1}";
                            let message = format!(
                                "*3\r\n$7\r\nmessage\r\n$10\r\nws:user:42\r\n${}\r\n",
                                early.len()
                            );
                            stream
                                .write_all(message.as_bytes())
                                .map_err(|_| "early header")?;
                            stream.write_all(early).map_err(|_| "early payload")?;
                            stream.write_all(b"\r\n").map_err(|_| "early ending")?;
                            continue;
                        }
                        if !subscribed_user || channel != "ws:presence" {
                            return Err("wrong channel".into());
                        }
                        let response = format!(
                            "*3\r\n$9\r\nsubscribe\r\n${}\r\n{}\r\n:2\r\n",
                            channel.len(),
                            channel
                        );
                        stream.write_all(response.as_bytes()).map_err(|_| "ack")?;
                        let presence = b"{\"type\":\"presence_update\",\"data\":{\"user_id\":9,\"online_status\":\"hidden\",\"last_seen_at\":null,\"server_id\":\"peer\"},\"timestamp\":1}";
                        let message = format!(
                            "*3\r\n$7\r\nmessage\r\n$11\r\nws:presence\r\n${}\r\n",
                            presence.len()
                        );
                        stream
                            .write_all(message.as_bytes())
                            .map_err(|_| "presence header")?;
                        stream.write_all(presence).map_err(|_| "presence payload")?;
                        stream.write_all(b"\r\n").map_err(|_| "presence ending")?;
                        let mut eof = [0; 1];
                        if reader.read(&mut eof).map_err(|_| "close")? != 0 {
                            return Err("expected close".into());
                        }
                        return Ok(channel);
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
    let source = RedisNotificationSource::new(&config).unwrap();
    assert!(source.subscribe(0).await.is_err());
    let mut events = tokio::time::timeout(Duration::from_secs(3), source.subscribe(42))
        .await
        .unwrap()
        .unwrap();
    let body = tokio::time::timeout(Duration::from_secs(3), events.recv())
        .await
        .unwrap()
        .unwrap();
    let event: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(event["type"], "notification_created");
    let body = tokio::time::timeout(Duration::from_secs(3), events.recv())
        .await
        .unwrap()
        .unwrap();
    let event: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(event["type"], "presence_update");
    drop(events);
    let channel = tokio::task::spawn_blocking(move || rx.recv_timeout(Duration::from_secs(5)))
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(channel, "ws:presence");
    worker.join().unwrap();
}
