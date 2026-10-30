//! Internal source revalidation boundary; it is not a public knowledge-answer endpoint.
use super::knowledge_source::{self, Candidate, Source};
use std::{
    collections::{HashMap, HashSet},
    future::Future,
    pin::Pin,
};
use tokio::sync::watch;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TurnError {
    InvalidSource,
    SourceChanged,
    InvalidAnswer,
    ContextTooLarge,
    Cancelled,
    Dependency,
}
pub type TurnFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T, TurnError>> + Send + 'a>>;
pub trait Dependencies {
    fn discover(&self) -> TurnFuture<'_, Vec<Source>>;
    fn hydrate<'a>(&'a self, candidates: &'a [Candidate]) -> TurnFuture<'a, Vec<Source>>;
    fn infer<'a>(&'a self, sources: &'a [Source]) -> TurnFuture<'a, String>;
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnResult {
    pub answer: Option<String>,
    pub sources: Vec<Candidate>,
}

fn candidates(rows: &[Source]) -> Vec<Candidate> {
    rows.iter()
        .map(|row| Candidate {
            kind: row.kind.clone(),
            id: row.id,
            version: row.version.clone(),
        })
        .collect()
}
fn check_rows(expected: &[Candidate], rows: &[Source]) -> Result<(), TurnError> {
    if rows.len() > expected.len() {
        return Err(TurnError::InvalidSource);
    }
    let expected: HashMap<_, _> = expected
        .iter()
        .map(|v| ((&v.kind, v.id), &v.version))
        .collect();
    let mut seen = HashSet::new();
    for row in rows {
        let key = (&row.kind, row.id);
        if !seen.insert(key) || expected.get(&key).copied() != Some(&row.version) {
            return Err(TurnError::InvalidSource);
        }
    }
    Ok(())
}
async fn cancelled(mut signal: Option<watch::Receiver<bool>>) {
    if let Some(ref mut receiver) = signal {
        loop {
            if *receiver.borrow() {
                return;
            }
            if receiver.changed().await.is_err() {
                break;
            }
        }
    }
    std::future::pending::<()>().await;
}
async fn checked<T>(
    future: TurnFuture<'_, T>,
    signal: Option<watch::Receiver<bool>>,
) -> Result<T, TurnError> {
    tokio::select! { biased; _=cancelled(signal)=>Err(TurnError::Cancelled), result=future=>result }
}
/// Authentication and releasing any database connection before inference are caller responsibilities.
pub async fn run(
    deps: &impl Dependencies,
    signal: Option<watch::Receiver<bool>>,
) -> Result<TurnResult, TurnError> {
    let discovered = checked(deps.discover(), signal.clone()).await?;
    let found = candidates(&discovered);
    knowledge_source::validate(1, &found).map_err(|_| TurnError::InvalidSource)?;
    let sources = checked(deps.hydrate(&found), signal.clone()).await?;
    check_rows(&found, &sources)?;
    if sources.is_empty() {
        return Ok(TurnResult {
            answer: None,
            sources: vec![],
        });
    }
    let used = candidates(&sources);
    let answer = checked(deps.infer(&sources), signal.clone()).await?;
    if answer.is_empty() || answer.len() > 65536 {
        return Err(TurnError::InvalidAnswer);
    }
    let after = checked(deps.hydrate(&used), signal.clone()).await?;
    check_rows(&used, &after)?;
    if signal.as_ref().is_some_and(|s| *s.borrow()) {
        return Err(TurnError::Cancelled);
    }
    let current: HashMap<_, _> = after.iter().map(|row| ((&row.kind, row.id), row)).collect();
    if after.len() != sources.len()
        || sources.iter().any(|row| {
            current
                .get(&(&row.kind, row.id))
                .is_none_or(|item| item.post_id != row.post_id || item.content != row.content)
        })
    {
        return Err(TurnError::SourceChanged);
    }
    Ok(TurnResult {
        answer: Some(answer),
        sources: used,
    })
}
