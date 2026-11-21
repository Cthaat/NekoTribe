use std::{
    fs::{self, File},
    io::{self, Read},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use super::model_config::ModelRouter;

const MAX_BYTES: usize = 65536;

pub(super) struct ModelFile {
    path: PathBuf,
    state: Mutex<FileState>,
}

#[derive(Default)]
struct FileState {
    next_check: Option<Instant>,
    active: Option<Arc<str>>,
    revision: u64,
}

impl PartialEq for ModelFile {
    fn eq(&self, other: &Self) -> bool {
        self.path == other.path
    }
}

impl Eq for ModelFile {}

impl ModelFile {
    pub(super) fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            state: Mutex::new(FileState::default()),
        }
    }

    pub(super) async fn load(self: Arc<Self>) -> Option<Arc<str>> {
        tokio::task::spawn_blocking(move || self.load_blocking())
            .await
            .ok()?
    }

    fn load_blocking(&self) -> Option<Arc<str>> {
        let mut state = self.state.lock().ok()?;
        let now = Instant::now();
        if state.next_check.is_none_or(|next| now >= next) {
            state.next_check = Some(now + Duration::from_secs(1));
            if let Some((raw, revision)) = read_candidate(&self.path) {
                if revision > state.revision {
                    state.active = Some(raw.into());
                    state.revision = revision;
                }
            }
        }
        state.active.clone()
    }
}

fn read_candidate(path: &Path) -> Option<(String, u64)> {
    let raw = read_utf8(path).ok()?;
    let router = ModelRouter::from_json(&raw).ok()?;
    let revision = router.select("knowledge", &[]).ok()?.configuration_revision;
    Some((raw, revision))
}

fn read_utf8(path: &Path) -> io::Result<String> {
    if !fs::metadata(path)?.is_file() {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut bytes = Vec::new();
    File::open(path)?
        .take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_BYTES {
        return Err(io::ErrorKind::InvalidData.into());
    }
    String::from_utf8(bytes).map_err(|_| io::ErrorKind::InvalidData.into())
}
