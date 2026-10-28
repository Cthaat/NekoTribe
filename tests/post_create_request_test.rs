use nekotribe_backend::posts::create_request::{
    parse_create_body, parse_repost_id, PostCreateInput,
};
use serde::Deserialize;
use serde_json::{value::RawValue, Value};

#[derive(Deserialize)]
struct Vectors {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    id: String,
    route: String,
    path_id: Option<String>,
    body: Box<RawValue>,
    expected: Value,
}

fn assert_input(input: &PostCreateInput, expected: &Value, case: &str) {
    assert_eq!(
        input.content,
        expected["content"].as_str().unwrap(),
        "{case}"
    );
    assert_eq!(
        input.visibility,
        expected["visibility"].as_str().unwrap(),
        "{case}"
    );
    assert_eq!(
        input.location,
        expected["location"].as_str().unwrap(),
        "{case}"
    );
    let numbers = |key: &str| {
        expected[key]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_f64().unwrap())
            .collect::<Vec<_>>()
    };
    assert_eq!(input.media_ids, numbers("media_ids"), "{case}");
    assert_eq!(
        input.mention_user_ids,
        numbers("mention_user_ids"),
        "{case}"
    );
    let tags: Vec<_> = expected["tag_names"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(input.tag_names, tags, "{case}");
    assert_eq!(
        input.reply_to_post_id,
        expected["reply_to_post_id"].as_u64(),
        "{case}"
    );
    assert_eq!(
        input.repost_of_post_id,
        expected["repost_of_post_id"].as_u64(),
        "{case}"
    );
    assert_eq!(
        input.quoted_post_id,
        expected["quoted_post_id"].as_u64(),
        "{case}"
    );
}

#[test]
fn shared_post_create_request_vectors_match_all_eighty_cases() {
    let vectors: Vectors = serde_json::from_str(include_str!(
        "../contracts/scenarios/post-create-request-vectors.json"
    ))
    .unwrap();
    assert_eq!(vectors.cases.len(), 80);
    for case in vectors.cases {
        let repost = if case.route == "retweet" {
            parse_repost_id(case.path_id.as_deref().unwrap()).map(Some)
        } else {
            Ok(None)
        };
        let result = repost
            .and_then(|id| parse_create_body(case.body.get().as_bytes(), "application/json", id));
        if case.expected["status"] == 200 {
            let input = result.unwrap_or_else(|error| panic!("{}: {error}", case.id));
            assert_input(&input, &case.expected["input"], &case.id);
            assert_eq!(
                input.post_type(),
                case.expected["post_type"].as_str().unwrap(),
                "{}",
                case.id
            );
        } else {
            let error = result.expect_err(&case.id);
            assert_eq!(
                u64::from(error.status().as_u16()),
                case.expected["status"].as_u64().unwrap(),
                "{}",
                case.id
            );
            let body = error.body();
            assert_eq!(
                i64::from(body.code),
                case.expected["code"].as_i64().unwrap(),
                "{}",
                case.id
            );
            assert_eq!(
                body.message,
                case.expected["message"].as_str().unwrap(),
                "{}",
                case.id
            );
            assert!(body.data.is_none() && body.meta.is_none(), "{}", case.id);
        }
    }
}

#[test]
fn overflowing_json_numbers_follow_javascript_field_conversion() {
    let input = parse_create_body(
        br#"{"content":1e400,"location":-1e400,"tag_names":[1e400,-1e400,-0,1e21,1e-7],"media_ids":[1e400,-1e400,2.5],"mention_user_ids":[1e400,3]}"#,
        "application/json", None,
    ).unwrap();
    assert_eq!(input.content, "Infinity");
    assert_eq!(input.location, "-Infinity");
    assert_eq!(
        input.tag_names,
        ["Infinity", "-Infinity", "0", "1e+21", "1e-7"]
    );
    assert_eq!(input.media_ids, [2.5]);
    assert_eq!(input.mention_user_ids, [3.0]);
    assert_eq!(
        parse_create_body(
            br#"{"content":"x","quoted_post_id":1e400}"#,
            "application/json",
            None
        )
        .unwrap_err()
        .to_string(),
        "id 参数错误"
    );
    assert_eq!(
        parse_create_body(
            br#"{"content":"x","visibility":1e400}"#,
            "application/json",
            None
        )
        .unwrap_err()
        .to_string(),
        "visibility 参数错误"
    );
}

#[test]
fn raw_body_and_form_boundaries_are_explicit() {
    for raw in [
        "",
        " ",
        "{",
        "{} {}",
        "{\"content\":NaN}",
        "{\"content\":01}",
        "{\"content\":1e}",
    ] {
        assert_eq!(
            parse_create_body(raw.as_bytes(), "application/json", None)
                .unwrap_err()
                .to_string(),
            "请求体必须是 JSON 对象",
            "{raw}"
        );
    }
    assert!(parse_create_body(&[0xff], "application/json", None).is_err());
    assert!(parse_create_body(br#"{"content":"hello"}"#, "text/plain", None).is_err());
    assert!(parse_create_body(&vec![b' '; 1024 * 1024 + 1], "application/json", None).is_err());
    let form = "content=++hello++&media_ids=0x10&media_ids=1.5&tag_names=+Cat+&tag_names=%EF%BB%BFdog&mention_user_ids=-1&mention_user_ids=+&quoted_post_id=3";
    let input = parse_create_body(
        form.as_bytes(),
        "application/x-www-form-urlencoded; charset=UTF-8",
        None,
    )
    .unwrap();
    assert_eq!(input.content, "  hello  ");
    assert_eq!(input.media_ids, [16.0, 1.5]);
    assert_eq!(input.tag_names, ["Cat", "dog"]);
    assert_eq!(input.mention_user_ids, [-1.0, 0.0]);
    assert_eq!(input.quoted_post_id, Some(3));
    assert_eq!(input.post_type(), "quote");
    assert_eq!(
        parse_create_body(b"", "application/x-www-form-urlencoded", None)
            .unwrap_err()
            .to_string(),
        "content 不能为空"
    );
    assert_eq!(
        parse_create_body(b"", "application/x-www-form-urlencoded", Some(3))
            .unwrap()
            .repost_of_post_id,
        Some(3)
    );
}

#[test]
fn number_strings_use_javascript_radices_and_rounding() {
    let input = parse_create_body(br#"{"content":"x","media_ids":["0x20000000000001","0x20000000000003","0x10000000000000801","0b1001","0o777","0x","0x1g","+0x10","-0x10","1_0","1.2x","\u0085","\uFEFF  ","+1.5e2"]}"#, "application/json", None).unwrap();
    assert_eq!(
        input.media_ids,
        [
            9_007_199_254_740_992.0,
            9_007_199_254_740_996.0,
            18_446_744_073_709_555_712.0,
            9.0,
            511.0,
            0.0,
            150.0
        ]
    );
    let input = parse_create_body(br#"{"content":9007199254740993,"location":-0,"reply_to_post_id":1.0,"ignored":{"huge":1e400}}"#, "application/json", None).unwrap();
    assert_eq!(input.content, "9007199254740992");
    assert_eq!(input.location, "0");
    assert_eq!(input.reply_to_post_id, Some(1));
}

#[test]
fn repost_path_decodes_once_and_validates_canonical_safe_integers() {
    assert_eq!(
        parse_repost_id("%39%30%30%37%31%39%39%32%35%34%37%34%30%39%39%31").unwrap(),
        9_007_199_254_740_991
    );
    for raw in [
        "",
        "+3",
        "%2B3",
        "%2533",
        "%",
        "%FF",
        "３",
        "9007199254740992",
    ] {
        assert_eq!(
            parse_repost_id(raw).unwrap_err().to_string(),
            "id 参数错误",
            "{raw}"
        );
    }
}
