use nekotribe_backend::auth::{IssuedToken, TokenCodec, TokenKind};
use serde::Deserialize;

#[derive(Deserialize)]
struct Fixture {
    now: u64,
    keys: Keys,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Keys {
    access: String,
    refresh: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    id: String,
    #[serde(rename = "type")]
    kind: TokenKind,
    token: String,
    expected_valid: bool,
    expected_user_id: Option<u64>,
}

fn fixture() -> Fixture {
    serde_json::from_str(include_str!("../contracts/scenarios/auth-tokens.json")).unwrap()
}

#[test]
fn verifies_all_25_shared_nuxt_vectors() {
    let fixture = fixture();
    assert_eq!(fixture.cases.len(), 25);
    let codec = TokenCodec::new(
        fixture.keys.access.as_bytes(),
        fixture.keys.refresh.as_bytes(),
    )
    .unwrap();
    for case in fixture.cases {
        let result = codec.verify(&case.token, case.kind, fixture.now);
        assert_eq!(result.is_ok(), case.expected_valid, "{}", case.id);
        if let Some(expected) = case.expected_user_id {
            assert_eq!(result.unwrap().user_id, expected, "{}", case.id);
        }
    }
}

#[test]
fn signs_both_kinds_with_distinct_keys_and_nuxt_claims() {
    let fixture = fixture();
    let codec = TokenCodec::new(
        fixture.keys.access.as_bytes(),
        fixture.keys.refresh.as_bytes(),
    )
    .unwrap();
    for kind in [TokenKind::Access, TokenKind::Refresh] {
        let issued = IssuedToken {
            user_id: 42,
            user_name: "测试用户".into(),
            session_id: "fixture-session-42".into(),
            kind,
            issued_at: fixture.now - 60,
            expires_at: fixture.now + 900,
            jti: format!("fixture-{}-jti-42", kind.as_str()),
        };
        let token = codec.sign(&issued).unwrap();
        // JWT object-key ordering differs between libraries; compare signed claims.
        let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::HS256);
        validation.validate_exp = false;
        let key = match kind {
            TokenKind::Access => &fixture.keys.access,
            TokenKind::Refresh => &fixture.keys.refresh,
        };
        let decoded = jsonwebtoken::decode::<serde_json::Value>(
            &token,
            &jsonwebtoken::DecodingKey::from_secret(key.as_bytes()),
            &validation,
        )
        .unwrap();
        assert_eq!(decoded.header.alg, jsonwebtoken::Algorithm::HS256);
        assert_eq!(decoded.claims, serde_json::to_value(&issued).unwrap());
        let claims = codec.verify(&token, kind, fixture.now).unwrap();
        assert_eq!(claims.user_name.as_deref(), Some("测试用户"));
        assert_eq!(claims.session_id, issued.session_id);
        assert_eq!(claims.jti, issued.jti);
        assert_eq!(claims.issued_at, Some(issued.issued_at as f64));
        assert_eq!(claims.expires_at, Some(issued.expires_at as f64));
        let opposite = if kind == TokenKind::Access {
            TokenKind::Refresh
        } else {
            TokenKind::Access
        };
        assert!(codec.verify(&token, opposite, fixture.now).is_err());
    }
}

#[test]
fn rejects_invalid_issuance_and_empty_keys_without_leaking_inputs() {
    assert!(TokenCodec::new(b"", b"refresh").is_err());
    assert!(TokenCodec::new(b"access", b"").is_err());
    let codec = TokenCodec::new(b"private-access-key", b"private-refresh-key").unwrap();
    let mut claims = IssuedToken {
        user_id: 0,
        user_name: "test".into(),
        session_id: "session".into(),
        kind: TokenKind::Access,
        issued_at: 100,
        expires_at: 200,
        jti: "jti".into(),
    };
    assert!(codec.sign(&claims).is_err());
    claims.user_id = 9_007_199_254_740_992;
    assert!(codec.sign(&claims).is_err());
    claims.user_id = 42;
    claims.session_id.clear();
    assert!(codec.sign(&claims).is_err());
    claims.session_id = "session".into();
    claims.jti.clear();
    assert!(codec.sign(&claims).is_err());
    let error = codec
        .verify("private-token", TokenKind::Access, 100)
        .unwrap_err();
    assert_eq!(error.to_string(), "invalid token");
    assert!(!format!("{error:?}").contains("private"));
}

#[test]
fn rejects_signed_claims_with_invalid_boundaries_or_types() {
    let fixture = fixture();
    let codec = TokenCodec::new(
        fixture.keys.access.as_bytes(),
        fixture.keys.refresh.as_bytes(),
    )
    .unwrap();
    let base = serde_json::json!({
        "userId": 42, "userName": "test", "sessionId": "session",
        "type": "access", "iat": fixture.now, "exp": fixture.now + 60, "jti": "jti"
    });
    for (name, value) in [
        ("userId", serde_json::json!(-1)),
        ("userId", serde_json::json!(true)),
        ("userId", serde_json::json!("NaN")),
        ("userId", serde_json::json!("9007199254740992")),
        ("sessionId", serde_json::json!("")),
        ("sessionId", serde_json::json!(42)),
        ("jti", serde_json::json!("")),
        ("jti", serde_json::json!(false)),
        ("exp", serde_json::json!(null)),
        ("exp", serde_json::json!("1700000060")),
        ("nbf", serde_json::json!("1700000000")),
    ] {
        let mut claims = base.clone();
        claims[name] = value;
        let token = jsonwebtoken::encode(
            &jsonwebtoken::Header::new(jsonwebtoken::Algorithm::HS256),
            &claims,
            &jsonwebtoken::EncodingKey::from_secret(fixture.keys.access.as_bytes()),
        )
        .unwrap();
        assert!(
            codec
                .verify(&token, TokenKind::Access, fixture.now)
                .is_err(),
            "{name}"
        );
    }
}
