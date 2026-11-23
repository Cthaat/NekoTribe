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
    Forbidden,
    InvalidSource,
    SourceChanged,
    InvalidAnswer,
    InvalidCitations,
    ContextTooLarge,
    Cancelled,
    Dependency,
    Quota(super::model_quota::QuotaError),
}
pub type TurnFuture<'a, T> = Pin<Box<dyn Future<Output = Result<T, TurnError>> + Send + 'a>>;
pub struct Hit {
    pub source: Candidate,
    pub chunk: Option<usize>,
    pub(crate) indexed: bool,
}

pub(super) fn chunk_for_source(hits: &[Hit], source: &Source) -> Option<usize> {
    hits.iter()
        .find(|hit| {
            hit.source.kind == source.kind
                && hit.source.id == source.id
                && hit.source.version == source.version
        })
        .and_then(|hit| hit.chunk)
}

pub(super) fn indexed_chunk(content: &str, chunk: usize) -> Option<Vec<char>> {
    if chunk > 102 {
        return None;
    }
    let characters: Vec<char> = content.chars().skip(chunk * 640).take(768).collect();
    let excerpt: String = characters.iter().collect();
    (!crate::auth::login::js_trim(&excerpt).is_empty()).then_some(characters)
}

pub(super) fn lexical_hits(rows: &[Source]) -> Vec<Hit> {
    candidates(rows)
        .into_iter()
        .map(|source| Hit {
            source,
            chunk: None,
            indexed: false,
        })
        .collect()
}

pub trait Dependencies {
    fn discover(&self) -> TurnFuture<'_, Vec<Source>>;
    fn discover_hits(&self) -> TurnFuture<'_, Vec<Hit>> {
        let discovery = self.discover();
        Box::pin(async move { Ok(lexical_hits(&discovery.await?)) })
    }
    fn hydrate<'a>(&'a self, candidates: &'a [Candidate]) -> TurnFuture<'a, Vec<Source>>;
    fn refresh_stale(&self, _hits: &[Hit]) -> Option<TurnFuture<'_, Vec<Hit>>> {
        None
    }
    fn select_evidence(&self, sources: &[Source], _hits: &[Hit]) -> Result<Vec<Source>, TurnError> {
        Ok(sources.to_vec())
    }
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

async fn hydrate_hits(
    deps: &impl Dependencies,
    hits: &[Hit],
    signal: Option<watch::Receiver<bool>>,
) -> Result<Vec<Source>, TurnError> {
    let found: Vec<_> = hits.iter().map(|hit| hit.source.clone()).collect();
    knowledge_source::validate(1, &found).map_err(|_| TurnError::InvalidSource)?;
    let mut sources = checked(deps.hydrate(&found), signal).await?;
    check_rows(&found, &sources)?;
    sources.retain(|source| {
        chunk_for_source(hits, source)
            .is_none_or(|chunk| indexed_chunk(&source.content, chunk).is_some())
    });
    Ok(sources)
}
/// Authentication and releasing any database connection before inference are caller responsibilities.
pub async fn run(
    deps: &impl Dependencies,
    signal: Option<watch::Receiver<bool>>,
) -> Result<TurnResult, TurnError> {
    let mut hits = checked(deps.discover_hits(), signal.clone()).await?;
    let mut sources = hydrate_hits(deps, &hits, signal.clone()).await?;
    if !hits.is_empty() && sources.is_empty() {
        if let Some(refresh) = deps.refresh_stale(&hits) {
            hits = checked(refresh, signal.clone()).await?;
            sources = hydrate_hits(deps, &hits, signal.clone()).await?;
        }
    }
    if sources.is_empty() {
        return Ok(TurnResult {
            answer: None,
            sources: vec![],
        });
    }
    let evidence = deps.select_evidence(&sources, &hits)?;
    let sources = &sources[..evidence.len()];
    let used = candidates(sources);
    let answer = checked(deps.infer(&evidence), signal.clone()).await?;
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
            current.get(&(&row.kind, row.id)).is_none_or(|item| {
                item.post_id != row.post_id
                    || item.group_id != row.group_id
                    || item.content != row.content
            })
        })
    {
        return Err(TurnError::SourceChanged);
    }
    Ok(TurnResult {
        answer: Some(answer),
        sources: used,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    struct IndexedHit;

    impl Dependencies for IndexedHit {
        fn discover(&self) -> TurnFuture<'_, Vec<Source>> {
            Box::pin(async { Ok(vec![source()]) })
        }

        fn discover_hits(&self) -> TurnFuture<'_, Vec<Hit>> {
            Box::pin(async {
                let mut hits = lexical_hits(&[source()]);
                hits[0].chunk = Some(1);
                hits[0].indexed = true;
                Ok(hits)
            })
        }

        fn hydrate<'a>(&'a self, _: &'a [Candidate]) -> TurnFuture<'a, Vec<Source>> {
            self.discover()
        }

        fn refresh_stale(&self, hits: &[Hit]) -> Option<TurnFuture<'_, Vec<Hit>>> {
            assert_eq!(hits[0].chunk, Some(1));
            Some(Box::pin(async { Ok(lexical_hits(&[source()])) }))
        }

        fn select_evidence(&self, sources: &[Source], hits: &[Hit]) -> Result<Vec<Source>, TurnError> {
            assert_eq!(hits[0].chunk, None);
            Ok(sources.to_vec())
        }

        fn infer<'a>(&'a self, _: &'a [Source]) -> TurnFuture<'a, String> {
            Box::pin(async { Ok("answer".into()) })
        }
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

    #[tokio::test]
    async fn refreshes_when_indexed_chunk_is_outside_the_current_body() {
        let result = run(&IndexedHit, None).await.unwrap();
        assert_eq!(result.answer.as_deref(), Some("answer"));
        assert_eq!(result.sources, candidates(&[source()]));
    }
}
