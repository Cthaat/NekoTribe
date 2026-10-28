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
                        let payload =
                            b"{\"type\":\"notification_created\",\"data\":{},\"timestamp\":1}";
                        let response = format!("*3\r\n$9\r\nsubscribe\r\n${}\r\n{}\r\n:1\r\n*3\r\n$7\r\nmessage\r\n${}\r\n{}\r\n${}\r\n", channel.len(), channel, channel.len(), channel, payload.len());
                        stream.write_all(response.as_bytes()).map_err(|_| "ack")?;
                        stream.write_all(payload).map_err(|_| "payload")?;
                        stream.write_all(b"\r\n").map_err(|_| "ending")?;
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
    drop(events);
    let channel = tokio::task::spawn_blocking(move || rx.recv_timeout(Duration::from_secs(5)))
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(channel, "ws:user:42");
    worker.join().unwrap();
}
