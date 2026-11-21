//! Publish a request-owned temporary file under the configured local root.
use cap_std::{
    ambient_authority,
    fs::{Dir, OpenOptions},
};
use std::{
    io::{self, Read, Seek, SeekFrom},
    path::Path,
};

fn child_dir(parent: &Dir, name: &str) -> io::Result<Dir> {
    match parent.create_dir(name) {
        Ok(()) => (),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => (),
        Err(e) => return Err(e),
    }
    let metadata = parent.symlink_metadata(name)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsafe storage directory",
        ));
    }
    parent.open_dir(name)
}

struct Stage {
    parent: Dir,
    dir: Dir,
    name: String,
    directory_identity: same_file::Handle,
    file_identity: Option<same_file::Handle>,
}

impl Stage {
    fn new(parent: Dir) -> io::Result<(Self, cap_std::fs::File)> {
        let name = format!("publish-{}", uuid::Uuid::new_v4());
        let mut builder = cap_std::fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use cap_std::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        parent.create_dir_with(&name, &builder)?;
        let dir = match parent.open_dir(&name) {
            Ok(dir) => dir,
            Err(error) => {
                let _ = parent.remove_dir(&name);
                return Err(error);
            }
        };
        let directory_identity = same_file::Handle::from_file(dir.try_clone()?.into_std_file())?;
        let mut stage = Self {
            parent,
            dir,
            name,
            directory_identity,
            file_identity: None,
        };
        let mut options = OpenOptions::new();
        options.read(true).write(true).create_new(true);
        let file = stage.dir.open_with("data", &options)?;
        stage.file_identity = Some(same_file::Handle::from_file(file.try_clone()?.into_std())?);
        Ok((stage, file))
    }

    fn verify_directory(&self) -> io::Result<()> {
        let metadata = self.parent.symlink_metadata(&self.name)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(io::Error::other("stage directory changed"));
        }
        let current = self.parent.open_dir(&self.name)?;
        if same_file::Handle::from_file(current.into_std_file())? != self.directory_identity {
            return Err(io::Error::other("stage directory changed"));
        }
        Ok(())
    }

    fn verify_file(&self, original: &cap_std::fs::File) -> io::Result<()> {
        self.verify_directory()?;
        let metadata = self.dir.symlink_metadata("data")?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err(io::Error::other("stage file changed"));
        }
        let current = self.dir.open("data")?;
        let current = same_file::Handle::from_file(current.into_std())?;
        let expected = self
            .file_identity
            .as_ref()
            .ok_or_else(|| io::Error::other("stage identity unavailable"))?;
        if &current != expected
            || same_file::Handle::from_file(original.try_clone()?.into_std())? != *expected
        {
            return Err(io::Error::other("stage file changed"));
        }
        Ok(())
    }
}
impl Drop for Stage {
    fn drop(&mut self) {
        if self.verify_directory().is_err() {
            tracing::warn!("media upload stage cleanup unavailable");
            return;
        }
        if let Some(expected) = &self.file_identity {
            let checked = self
                .dir
                .symlink_metadata("data")
                .ok()
                .filter(|m| !m.file_type().is_symlink() && m.is_file())
                .and_then(|_| self.dir.open("data").ok())
                .and_then(|file| same_file::Handle::from_file(file.into_std()).ok())
                .is_some_and(|current| &current == expected);
            if !checked || self.dir.remove_file("data").is_err() {
                tracing::warn!("media upload stage cleanup unavailable");
                return;
            }
        }
        if self.parent.remove_dir(&self.name).is_err() {
            tracing::warn!("media upload stage cleanup unavailable");
        }
    }
}

/// Holds the published inode open; dropping this value never deletes the object.
pub struct PublishedMedia {
    root: Dir,
    target: Dir,
    directories: Vec<String>,
    name: String,
    identity: same_file::Handle,
}

impl PublishedMedia {
    /// Call only after a confirmed database rollback. A failed check preserves the object.
    pub fn cleanup_after_confirmed_rollback(&self) -> io::Result<()> {
        let changed = || io::Error::other("published object changed");
        let mut current = self.root.try_clone()?;
        for name in &self.directories {
            let info = current.symlink_metadata(name)?;
            if info.file_type().is_symlink() || !info.is_dir() {
                return Err(changed());
            }
            current = current.open_dir(name)?;
        }
        let actual_directory = same_file::Handle::from_file(current.into_std_file())?;
        let expected_directory =
            same_file::Handle::from_file(self.target.try_clone()?.into_std_file())?;
        if actual_directory != expected_directory {
            return Err(changed());
        }
        let info = match self.target.symlink_metadata(&self.name) {
            Ok(info) => info,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error),
        };
        if info.file_type().is_symlink() || !info.is_file() {
            return Err(changed());
        }
        let current_file = self.target.open(&self.name)?;
        if same_file::Handle::from_file(current_file.into_std())? != self.identity {
            return Err(changed());
        }
        self.target.remove_file(&self.name)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum FinalizeError {
    SchemaUnavailable,
    StoreUnavailable,
}

/// Preserve the object whenever the transaction result is missing or uncertain.
pub fn finalize<T>(
    object: PublishedMedia,
    result: Result<
        crate::media::upload_transaction::MediaUploadOutcome<T>,
        crate::auth::sessions::SessionStoreError,
    >,
) -> Result<T, FinalizeError> {
    use crate::media::upload_transaction::MediaUploadOutcome;
    match result {
        Ok(MediaUploadOutcome::Created(value)) => Ok(value),
        Ok(MediaUploadOutcome::Failed {
            cleanup_safe,
            schema_unavailable,
        }) => {
            if cleanup_safe && object.cleanup_after_confirmed_rollback().is_err() {
                tracing::warn!("media upload rollback cleanup unavailable");
            }
            Err(if schema_unavailable {
                FinalizeError::SchemaUnavailable
            } else {
                FinalizeError::StoreUnavailable
            })
        }
        Err(_) => Err(FinalizeError::StoreUnavailable),
    }
}

/// Hard-link a complete staged copy into place, without replacing a destination.
pub fn publish(
    source: &mut std::fs::File,
    size: u64,
    root: &Path,
    key: &str,
) -> io::Result<PublishedMedia> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "invalid media object");
    let key = crate::storage::local_policy::normalize_local_key(key).map_err(|_| invalid())?;
    if !(key.starts_with("posts/")
        || key.starts_with("avatars/")
        || crate::storage::local_policy::is_private_storage_key(&key))
        || size == 0
        || size > 500 << 20
        || !source.metadata()?.is_file()
        || source.metadata()?.len() != size
    {
        return Err(invalid());
    }
    let root = Dir::open_ambient_dir(root, ambient_authority())?;
    let cleanup_root = root.try_clone()?;
    let temp = child_dir(&root, "temp")?;
    let (stage, mut file) = Stage::new(temp)?;
    source.seek(SeekFrom::Start(0))?;
    let copied = io::copy(&mut source.take(size + 1), &mut file)?;
    if copied != size {
        return Err(invalid());
    }
    file.sync_all()?;
    let mut target = root;
    let mut directories = Vec::new();
    let mut parts = key.split('/').peekable();
    while let Some(name) = parts.next() {
        if parts.peek().is_none() {
            stage.verify_file(&file)?;
            let identity = same_file::Handle::from_file(file.try_clone()?.into_std())?;
            stage.dir.hard_link("data", &target, name)?;
            let result = PublishedMedia {
                root: cleanup_root,
                target,
                directories,
                name: name.to_owned(),
                identity,
            };
            let linked = result.target.open(name)?;
            if same_file::Handle::from_file(linked.into_std())? != result.identity {
                return Err(io::Error::other("published object changed"));
            }
            return Ok(result);
        }
        target = child_dir(&target, name)?;
        directories.push(name.to_owned());
    }
    Err(invalid())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Seek, SeekFrom, Write};

    #[test]
    fn transaction_outcome_controls_cleanup() {
        use crate::auth::sessions::SessionStoreError;
        use crate::media::upload_transaction::MediaUploadOutcome;
        let root = tempfile::tempdir().unwrap();
        let mut source = tempfile::tempfile().unwrap();
        source.write_all(b"hello").unwrap();
        for (index, result, retained) in [
            (0, Ok(MediaUploadOutcome::Created(7)), true),
            (
                1,
                Ok(MediaUploadOutcome::Failed {
                    cleanup_safe: true,
                    schema_unavailable: false,
                }),
                false,
            ),
            (
                2,
                Ok(MediaUploadOutcome::Failed {
                    cleanup_safe: false,
                    schema_unavailable: false,
                }),
                true,
            ),
            (3, Err(SessionStoreError), true),
            (
                4,
                Ok(MediaUploadOutcome::Failed {
                    cleanup_safe: true,
                    schema_unavailable: true,
                }),
                false,
            ),
        ] {
            let key = format!("posts/files/42/2026/01/{index}.txt");
            let object = publish(&mut source, 5, root.path(), &key).unwrap();
            let output = finalize(object, result);
            assert_eq!(output.is_ok(), index == 0);
            assert_eq!(root.path().join(key).exists(), retained, "case {index}");
            if index == 4 {
                assert!(matches!(output, Err(FinalizeError::SchemaUnavailable)));
            }
        }
    }

    #[test]
    fn confirmed_rollback_cleans_only_the_published_identity() {
        let root = tempfile::tempdir().unwrap();
        let mut source = tempfile::tempfile().unwrap();
        source.write_all(b"hello").unwrap();
        let key = "posts/files/42/2026/01/file.txt";
        let object = publish(&mut source, 5, root.path(), key).unwrap();
        object.cleanup_after_confirmed_rollback().unwrap();
        assert!(!root.path().join(key).exists());
        let object = publish(&mut source, 5, root.path(), key).unwrap();
        let path = root.path().join(key);
        std::fs::remove_file(&path).unwrap();
        std::fs::write(&path, b"replacement").unwrap();
        assert!(object.cleanup_after_confirmed_rollback().is_err());
        assert_eq!(std::fs::read(path).unwrap(), b"replacement");
    }

    #[cfg(unix)]
    #[test]
    fn rollback_does_not_remove_file_in_moved_directory() {
        let root = tempfile::tempdir().unwrap();
        let mut source = tempfile::tempfile().unwrap();
        source.write_all(b"hello").unwrap();
        let key = "posts/files/42/2026/01/file.txt";
        let object = publish(&mut source, 5, root.path(), key).unwrap();
        let folder = root.path().join("posts/files/42/2026/01");
        let moved = root.path().join("moved");
        std::fs::rename(&folder, &moved).unwrap();
        std::fs::create_dir(&folder).unwrap();
        std::fs::write(folder.join("file.txt"), b"other").unwrap();
        assert!(object.cleanup_after_confirmed_rollback().is_err());
        assert_eq!(std::fs::read(folder.join("file.txt")).unwrap(), b"other");
        assert_eq!(std::fs::read(moved.join("file.txt")).unwrap(), b"hello");
    }

    #[test]
    fn staged_replacement_is_not_published_or_removed() {
        let root = tempfile::tempdir().unwrap();
        let parent = Dir::open_ambient_dir(root.path(), ambient_authority()).unwrap();
        let (stage, mut original) = Stage::new(parent).unwrap();
        original.write_all(b"original").unwrap();
        original.sync_all().unwrap();
        let path = root.path().join(&stage.name).join("data");
        std::fs::remove_file(&path).unwrap();
        std::fs::write(&path, b"replacement").unwrap();
        assert!(stage.verify_file(&original).is_err());
        drop(stage);
        assert_eq!(std::fs::read(&path).unwrap(), b"replacement");
    }

    #[cfg(unix)]
    #[test]
    fn replaced_stage_directory_is_not_removed() {
        let root = tempfile::tempdir().unwrap();
        let parent = Dir::open_ambient_dir(root.path(), ambient_authority()).unwrap();
        let (stage, file) = Stage::new(parent).unwrap();
        let path = root.path().join(&stage.name);
        let moved = root.path().join("moved");
        std::fs::rename(&path, &moved).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("data"), b"other").unwrap();
        assert!(stage.verify_file(&file).is_err());
        drop(stage);
        assert_eq!(std::fs::read(path.join("data")).unwrap(), b"other");
        assert!(moved.join("data").exists());
    }

    #[cfg(unix)]
    #[test]
    fn stage_directory_is_private_and_cleaned() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let parent = Dir::open_ambient_dir(root.path(), ambient_authority()).unwrap();
        let (stage, file) = Stage::new(parent).unwrap();
        let path = root.path().join(&stage.name);
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o077,
            0
        );
        drop(file);
        drop(stage);
        assert!(!path.exists());
    }

    #[test]
    fn publishes_bytes_without_overwriting_an_existing_object() {
        let root = tempfile::tempdir().unwrap();
        let mut source = tempfile::tempfile().unwrap();
        source.write_all(b"hello").unwrap();
        let key = "posts/files/42/2026/01/file.txt";
        publish(&mut source, 5, root.path(), key).unwrap();
        assert_eq!(std::fs::read(root.path().join(key)).unwrap(), b"hello");
        source.seek(SeekFrom::Start(0)).unwrap();
        assert!(publish(&mut source, 5, root.path(), key).is_err());
        let mut content = String::new();
        std::fs::File::open(root.path().join(key))
            .unwrap()
            .read_to_string(&mut content)
            .unwrap();
        assert_eq!(content, "hello");
    }

    #[cfg(unix)]
    #[test]
    fn refuses_symlinked_storage_directories() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), root.path().join("posts")).unwrap();
        let mut source = tempfile::tempfile().unwrap();
        source.write_all(b"hello").unwrap();
        assert!(publish(&mut source, 5, root.path(), "posts/files/a.txt").is_err());
        assert_eq!(std::fs::read_dir(outside.path()).unwrap().count(), 0);
    }
}
