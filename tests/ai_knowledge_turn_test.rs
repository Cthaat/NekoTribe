use nekotribe_backend::ai::{
    knowledge_source::{Candidate, Source},
    knowledge_turn::{run, Dependencies, TurnError, TurnFuture},
};
use std::sync::Mutex;
use tokio::sync::watch;

struct Fake {
    events: Mutex<Vec<&'static str>>,
    stale: bool,
    empty: bool,
}
fn source() -> Source {
    Source {
        kind: "post".into(),
        id: 1,
        post_id: 1,
        group_id: 0,
        content: "公开内容".into(),
        version: "a".repeat(64),
    }
}
impl Dependencies for Fake {
    fn discover(&self) -> TurnFuture<'_, Vec<Source>> {
        Box::pin(async move {
            self.events.lock().unwrap().push("discover");
            Ok(vec![source()])
        })
    }
    fn hydrate<'a>(&'a self, candidates: &'a [Candidate]) -> TurnFuture<'a, Vec<Source>> {
        Box::pin(async move {
            assert_eq!(candidates[0].id, 1);
            let mut events = self.events.lock().unwrap();
            events.push("hydrate");
            if self.empty || (self.stale && events.iter().filter(|&&x| x == "hydrate").count() > 1)
            {
                Ok(vec![])
            } else {
                Ok(vec![source()])
            }
        })
    }
    fn infer<'a>(&'a self, sources: &'a [Source]) -> TurnFuture<'a, String> {
        Box::pin(async move {
            assert_eq!(sources, [source()]);
            self.events.lock().unwrap().push("infer");
            Ok("answer".into())
        })
    }
}
#[tokio::test]
async fn revalidates_before_and_after_inference() {
    let f = Fake {
        events: Mutex::new(vec![]),
        stale: false,
        empty: false,
    };
    let result = run(&f, None).await.unwrap();
    assert_eq!(result.answer.as_deref(), Some("answer"));
    assert_eq!(result.sources[0].id, 1);
    assert_eq!(
        *f.events.lock().unwrap(),
        vec!["discover", "hydrate", "infer", "hydrate"]
    );
}
#[tokio::test]
async fn no_evidence_skips_inference_and_revocation_withholds_output() {
    let f = Fake {
        events: Mutex::new(vec![]),
        stale: false,
        empty: true,
    };
    assert_eq!(run(&f, None).await.unwrap().answer, None);
    assert!(!f.events.lock().unwrap().contains(&"infer"));
    let f = Fake {
        events: Mutex::new(vec![]),
        stale: true,
        empty: false,
    };
    assert_eq!(run(&f, None).await, Err(TurnError::SourceChanged));
}
#[tokio::test]
async fn cancelled_before_read_does_not_call_dependencies() {
    let f = Fake {
        events: Mutex::new(vec![]),
        stale: false,
        empty: false,
    };
    let (_tx, rx) = watch::channel(true);
    assert_eq!(run(&f, Some(rx)).await, Err(TurnError::Cancelled));
    assert!(f.events.lock().unwrap().is_empty());
}

struct CancelDuringInference(watch::Sender<bool>);
impl Dependencies for CancelDuringInference {
    fn discover(&self) -> TurnFuture<'_, Vec<Source>> {
        Box::pin(async { Ok(vec![source()]) })
    }
    fn hydrate<'a>(&'a self, _: &'a [Candidate]) -> TurnFuture<'a, Vec<Source>> {
        Box::pin(async { Ok(vec![source()]) })
    }
    fn infer<'a>(&'a self, _: &'a [Source]) -> TurnFuture<'a, String> {
        Box::pin(async move {
            self.0.send(true).unwrap();
            std::future::pending::<Result<String, TurnError>>().await
        })
    }
}
#[tokio::test]
async fn cancellation_interrupts_inference_without_returning_output() {
    let (tx, rx) = watch::channel(false);
    assert_eq!(
        run(&CancelDuringInference(tx), Some(rx)).await,
        Err(TurnError::Cancelled)
    );
}
