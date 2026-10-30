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

/// Hard-link a complete staged copy into place, without replacing a destination.
pub fn publish(source: &mut std::fs::File, size: u64, root: &Path, key: &str) -> io::Result<()> {
    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "invalid media object");
    let key = crate::storage::local_policy::normalize_local_key(key).map_err(|_| invalid())?;
    if !key.starts_with("posts/")
        || size == 0
        || size > 500 << 20
        || !source.metadata()?.is_file()
        || source.metadata()?.len() != size
    {
        return Err(invalid());
    }
    let root = Dir::open_ambient_dir(root, ambient_authority())?;
    let temp = child_dir(&root, "temp")?;
    let (stage, mut file) = Stage::new(temp)?;
    source.seek(SeekFrom::Start(0))?;
    let copied = io::copy(&mut source.take(size + 1), &mut file)?;
    if copied != size {
        return Err(invalid());
    }
    file.sync_all()?;
    let mut target = root;
    let mut parts = key.split('/').peekable();
    while let Some(name) = parts.next() {
        if parts.peek().is_none() {
            stage.verify_file(&file)?;
            return stage.dir.hard_link("data", &target, name);
        }
        target = child_dir(&target, name)?;
    }
    Err(invalid())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Seek, SeekFrom, Write};

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
