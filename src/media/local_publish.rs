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
    dir: Dir,
    name: String,
}
impl Drop for Stage {
    fn drop(&mut self) {
        if let Err(error) = self.dir.remove_file(&self.name) {
            if error.kind() != io::ErrorKind::NotFound {
                tracing::warn!("media upload stage cleanup failed");
            }
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
    let name = format!("publish-{}", uuid::Uuid::new_v4());
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    let mut file = temp.open_with(&name, &options)?;
    let stage = Stage { dir: temp, name };
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
            return stage.dir.hard_link(&stage.name, &target, name);
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
