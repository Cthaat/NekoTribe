use nekotribe_backend::storage::media_type_selection::{
    select_media_file_type, DetectedType, SelectedType,
};
use serde::Deserialize;

#[derive(Deserialize)]
struct Vectors {
    cases: Vec<Case>,
}
#[derive(Deserialize)]
struct Case {
    id: String,
    name: String,
    uploaded: String,
    detected: Option<DetectedType>,
    expected: SelectedType,
}

#[test]
fn shared_media_type_selection_vectors() {
    let vectors: Vectors = serde_json::from_str(include_str!(
        "../contracts/scenarios/media-type-selection.json"
    ))
    .unwrap();
    for case in vectors.cases {
        assert_eq!(
            select_media_file_type(&case.name, &case.uploaded, case.detected.as_ref()),
            case.expected,
            "{}",
            case.id
        );
    }
}
