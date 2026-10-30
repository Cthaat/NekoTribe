use nekotribe_backend::ai::{
    knowledge_history::{encode, restore, HistoryError},
    knowledge_source::{Candidate, Source},
};
fn candidate() -> Candidate {
    Candidate {
        kind: "post".into(),
        id: 1,
        version: "a".repeat(64),
    }
}
#[test]
fn mixed_terms_history_omits_post_id_and_revalidates() {
    let post = candidate();
    let terms = Candidate {
        kind: "terms".into(),
        id: 3,
        version: "b".repeat(64),
    };
    let encoded = encode("answer", &[post.clone(), terms.clone()]).unwrap();
    let rows = vec![
        Source {
            kind: post.kind.clone(),
            id: 1,
            post_id: 1,
            content: "post".into(),
            version: post.version.clone(),
        },
        Source {
            kind: terms.kind.clone(),
            id: 3,
            post_id: 0,
            content: "terms".into(),
            version: terms.version.clone(),
        },
    ];
    let result = restore(&encoded, |_| Ok(rows.clone())).unwrap();
    let value = serde_json::to_value(result.citations).unwrap();
    assert_eq!(value[0]["post_id"], 1);
    assert!(value[1].get("post_id").is_none());
    let mut forged = rows;
    forged[1].post_id = 3;
    assert_eq!(
        restore(&encoded, |_| Ok(forged)),
        Err(HistoryError::SourceChanged)
    );
}
#[test]
fn restores_only_current_sources() {
    let ref_ = candidate();
    let encoded = encode("答案", std::slice::from_ref(&ref_)).unwrap();
    let result = restore(&encoded, |refs| {
        assert_eq!(refs, [ref_.clone()]);
        Ok(vec![Source {
            kind: "post".into(),
            id: 1,
            post_id: 1,
            content: "公开资料".into(),
            version: ref_.version.clone(),
        }])
    })
    .unwrap();
    assert_eq!(result.answer.as_deref(), Some("答案"));
    assert_eq!(result.sources, vec![ref_]);
    assert_eq!(
        restore(&encoded, |_| Ok(vec![])),
        Err(HistoryError::SourceChanged)
    );
}
#[test]
fn refuses_invalid_references_and_oversized_storage() {
    let r = candidate();
    assert_eq!(
        encode("answer", &[r.clone(), r.clone()]),
        Err(HistoryError::Invalid)
    );
    assert_eq!(encode(&"x".repeat(65536), &[r]), Err(HistoryError::Invalid));
    let mut called = false;
    assert_eq!(
        restore("bad", |_| {
            called = true;
            Ok(vec![])
        }),
        Err(HistoryError::Invalid)
    );
    assert!(!called);
}
#[test]
fn comment_citation_has_authorized_parent_without_source_content() {
    let reference = Candidate {
        kind: "comment".into(),
        id: 23,
        version: "b".repeat(64),
    };
    let encoded = encode("回答", std::slice::from_ref(&reference)).unwrap();
    let result = restore(&encoded, |_| {
        Ok(vec![Source {
            kind: "comment".into(),
            id: 23,
            post_id: 99,
            content: "internal text".into(),
            version: reference.version.clone(),
        }])
    })
    .unwrap();
    assert_eq!(result.citations[0].post_id, 99);
    assert!(!serde_json::to_string(&result.citations)
        .unwrap()
        .contains("internal text"));
    assert_eq!(
        restore(&encoded, |_| Ok(vec![Source {
            kind: "comment".into(),
            id: 23,
            post_id: 0,
            content: "x".into(),
            version: reference.version.clone()
        }])),
        Err(HistoryError::SourceChanged)
    );
}
