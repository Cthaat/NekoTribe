use super::*;
use std::{collections::VecDeque, sync::Mutex};

const PUBLIC: &str = "11.22.33.44";
const OTHER: &str = "12.23.34.45";

fn address(ip: &str, port: u16) -> SocketAddr {
    SocketAddr::new(ip.parse().unwrap(), port)
}

#[test]
fn url_normalization_preserves_http_authority_and_rejects_unsafe_input() {
    let url = parse_target("HTTPS://ExAmPlE.org:443/path?a=one#fragment").unwrap();
    assert_eq!(url.as_str(), "https://example.org/path?a=one");
    assert_eq!(
        parse_target("http://11.22.33.44:80/").unwrap().host_str(),
        Some(PUBLIC)
    );
    let ipv6 = parse_target("https://[2606:4700::1111]/").unwrap();
    assert!(matches!(ipv6.host(), Some(Host::Ipv6(_))));
    for invalid in [
        "file:///fixture",
        "https://example.org:8443/",
        "https://name:pass@example.org/",
        "http://@example.org/",
        "https://ex%61mple.org/",
        "http://example.org\\fixture",
        "http://127.0.0.1/",
        "http://0177.0.0.1/",
        "http://0x0b.22.33.44/",
        "http://11.22.33.44./",
        "http://184950060/",
        "http://localhost./",
        "http://metadata.internal/",
        "http://example.home.arpa/",
        "http://169.254.169.254/",
        "http://168.63.129.16/",
        "http://[::ffff:11.22.33.44]/",
        "http://[2002:b16:212c::]/",
        "http://[2001:db8::1]/",
        "http://example.org/with space",
    ] {
        assert!(parse_target(invalid).is_err(), "accepted {invalid}");
    }
    assert!(parse_target(&format!("https://example.org/{}", "中".repeat(700))).is_err());
    assert_eq!(
        key(&parse_target("https://example.org/#first").unwrap()),
        key(&parse_target("https://example.org/#second").unwrap())
    );
    assert!(key(&url).starts_with(policy().cache_prefix.as_str()));
    assert!(!key(&url).contains("example"));
}

#[test]
fn address_policy_checks_every_contract_range() {
    for cidr in &policy().blocked_cidrs {
        let network: IpNet = cidr.parse().unwrap();
        assert!(!public_ip(network.network()), "accepted {cidr}");
    }
    for ip in [
        PUBLIC,
        "2606:4700::1111",
        "64:ff9b::b16:212c",
        "fc00::1",
        "fe80::1",
    ] {
        assert_eq!(
            public_ip(ip.parse().unwrap()),
            ip == PUBLIC || ip == "2606:4700::1111"
        );
    }
}

enum Step {
    Resolve(&'static str, u16, Vec<SocketAddr>),
    Send(&'static str, Vec<SocketAddr>, Hop),
}

struct Fixture(Mutex<VecDeque<Step>>);

impl Fixture {
    fn new(steps: impl Into<VecDeque<Step>>) -> Self {
        Self(Mutex::new(steps.into()))
    }
    fn done(&self) {
        assert!(self.0.lock().unwrap().is_empty());
    }
}

impl Transport for Fixture {
    fn resolve<'a>(&self, host: &'a str, port: u16) -> BoxFuture<'a, Option<Vec<SocketAddr>>> {
        let Some(Step::Resolve(expected, expected_port, answers)) =
            self.0.lock().unwrap().pop_front()
        else {
            panic!("unplanned DNS call");
        };
        assert_eq!((host, port), (expected, expected_port));
        Box::pin(async move { Some(answers) })
    }

    fn send<'a>(&self, target: &'a Url, approved: &'a [SocketAddr]) -> BoxFuture<'a, Option<Hop>> {
        let Some(Step::Send(expected, expected_addrs, response)) =
            self.0.lock().unwrap().pop_front()
        else {
            panic!("unplanned outbound call");
        };
        assert_eq!(target.as_str(), expected);
        assert_eq!(approved, expected_addrs);
        Box::pin(async move { Some(response) })
    }
}

#[tokio::test]
async fn redirects_reresolve_the_origin_and_use_only_the_approved_addresses() {
    let fixture = Fixture::new([
        Step::Resolve("example.org", 443, vec![address(PUBLIC, 443)]),
        Step::Send(
            "https://example.org/",
            vec![address(PUBLIC, 443)],
            Hop::Redirect("/next#discard".into()),
        ),
        Step::Resolve("example.org", 443, vec![address(OTHER, 443)]),
        Step::Send(
            "https://example.org/next",
            vec![address(OTHER, 443)],
            Hop::Redirect("http://another.example/path#discard".into()),
        ),
        Step::Resolve("another.example", 80, vec![address(PUBLIC, 80)]),
        Step::Send(
            "http://another.example/path",
            vec![address(PUBLIC, 80)],
            Hop::Html(b"<title>fixture</title>".to_vec()),
        ),
    ]);
    let result = fetch_chain(&fixture, parse_target("https://example.org/").unwrap())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result.url, "http://another.example/path");
    assert_eq!(result.title, "fixture");
    fixture.done();
}

#[tokio::test]
async fn blocks_private_answers_and_redirects_before_any_forbidden_send() {
    let start = parse_target("http://example.org/").unwrap();
    let fixture = Fixture::new([Step::Resolve(
        "example.org",
        80,
        vec![address(PUBLIC, 80), address("10.0.0.2", 80)],
    )]);
    assert_eq!(fetch_chain(&fixture, start.clone()).await, Err(Blocked));
    fixture.done();
    for location in [
        "http://169.254.169.254/",
        "//0x0b.22.33.44/",
        "//user@public.example/",
        "https://public.example:8443/",
    ] {
        let fixture = Fixture::new([
            Step::Resolve("example.org", 80, vec![address(PUBLIC, 80)]),
            Step::Send(
                "http://example.org/",
                vec![address(PUBLIC, 80)],
                Hop::Redirect(location.into()),
            ),
        ]);
        assert_eq!(fetch_chain(&fixture, start.clone()).await, Err(Blocked));
        fixture.done();
    }
    let fixture = Fixture::new([
        Step::Resolve("example.org", 80, vec![address(PUBLIC, 80)]),
        Step::Send(
            "http://example.org/",
            vec![address(PUBLIC, 80)],
            Hop::Redirect("//second.example/".into()),
        ),
        Step::Resolve("second.example", 80, vec![address("127.0.0.1", 80)]),
    ]);
    assert_eq!(fetch_chain(&fixture, start).await, Err(Blocked));
    fixture.done();
}

#[tokio::test]
async fn redirects_and_response_body_are_bounded() {
    let start = parse_target("http://11.22.33.44/").unwrap();
    let send = || {
        Step::Send(
            "http://11.22.33.44/",
            vec![address(PUBLIC, 80)],
            Hop::Redirect("/#skip".into()),
        )
    };
    let fixture = Fixture::new(
        (0..=policy().max_redirects)
            .map(|_| send())
            .collect::<VecDeque<_>>(),
    );
    assert_eq!(fetch_chain(&fixture, start.clone()).await, Ok(None));
    fixture.done();
    let fixture = Fixture::new([Step::Send(
        "http://11.22.33.44/",
        vec![address(PUBLIC, 80)],
        Hop::Html(vec![b'x'; policy().max_body_bytes + 1]),
    )]);
    assert_eq!(fetch_chain(&fixture, start).await, Ok(None));
    fixture.done();

    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        "application/xhtml+xml; charset=utf-8".parse().unwrap(),
    );
    assert!(readable_headers(&headers, Some(524_288)));
    assert!(!readable_headers(&headers, Some(524_289)));
    headers.append(header::CONTENT_ENCODING, "identity".parse().unwrap());
    assert!(readable_headers(&headers, None));
    headers.append(header::CONTENT_ENCODING, "gzip".parse().unwrap());
    assert!(!readable_headers(&headers, None));
}

#[tokio::test]
async fn connector_has_no_unverified_dns_fallback() {
    let resolver = NoUnverifiedDns;
    let name = "fixture.example".parse::<reqwest::dns::Name>().unwrap();
    assert!(reqwest::dns::Resolve::resolve(&resolver, name)
        .await
        .is_err());
}

#[test]
fn metadata_prefers_open_graph_and_ignores_comments_raw_containers_and_images() {
    let html = br#"<head><title>Fallback title</title>
        <!-- <meta property='og:title' content='comment'> -->
        <script>var fixture = "<meta property='og:title' content='script'>"</script>
        <meta NAME=description content='Fallback description'>
        <meta CONTENT='  A &amp; B  ' PROPERTY='OG:TITLE'>
        <meta property="og:description" content="one &gt; two">
        <meta property='og:site_name' content=' Fixture &copy; '>
        <meta property='og:image' content='https://reserved.example/picture.png'>
        </head><body>content</body>"#;
    let target = parse_target("https://example.org/page").unwrap();
    let result = metadata::preview(&target, html).unwrap();
    assert_eq!(result.title, "A & B");
    assert_eq!(result.description, "one > two");
    assert_eq!(result.site_name, "Fixture ©");
    assert_eq!(result.url, "https://example.org/page");
    let fallback = format!(
        "<title>{}</title><meta name=description content='fallback &#20013;'>",
        "中".repeat(200)
    );
    let result = metadata::preview(&target, fallback.as_bytes()).unwrap();
    assert_eq!(result.title.chars().count(), policy().title_chars);
    assert_eq!(result.description, "fallback 中");
    assert_eq!(result.site_name, "example.org");
    assert!(
        metadata::preview(&target, b"<meta property='og:image' content='image-only'>").is_none()
    );
    let description_only =
        metadata::preview(&target, b"<meta name=description content='fixture'>").unwrap();
    assert_eq!(description_only.title, "example.org");
    let html_entities = metadata::preview(
        &target,
        b"<title>&NotEqualTilde; &Eacute; &#x1F600;</title>",
    )
    .unwrap();
    assert_eq!(html_entities.title, "\u{2242}\u{0338} É 😀");
}

#[test]
fn cached_previews_are_bounded_and_never_return_an_unsafe_final_url() {
    let message = |value: &str, title: &str| {
        serde_json::json!({
            "url": value, "title": title, "description": "Fixture", "site_name": "Example",
        })
        .to_string()
    };
    assert!(cached_preview(&message("https://example.org/page", "Fixture")).is_some());
    assert!(cached_preview(&message("https://example.org/page#fragment", "Fixture")).is_none());
    assert!(cached_preview(&message("http://127.0.0.1/", "Fixture")).is_none());
    assert!(cached_preview(&message("https://example.org/page", &"x".repeat(161))).is_none());
    assert_eq!(policy().cache_ttl_seconds, 3600);
}
