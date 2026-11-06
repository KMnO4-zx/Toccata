//! 收紧数据文件权限，让其他本机用户无法读取键盘和任务数据。
//!
//! 这不是针对同用户进程的隔离：它们仍以文件所有者身份访问这些文件。

use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

const PRIVATE_DIRECTORY: u32 = 0o700;
const PRIVATE_FILE: u32 = 0o600;

/// 服务之后新建的文件、WAL 和 socket 都不开放给其他用户。
pub fn restrict_new_files() {
    unsafe { libc::umask(0o077) };
}

/// 收紧数据目录及其中的文件（不递归）。`custom_files` 是配置指向目录外的数据库文件；
/// 这些文件所在的目录由用户选择，不修改目录本身。
pub fn harden(data_dir: &Path, custom_files: &[PathBuf]) {
    let is_home = std::env::var_os("HOME").is_some_and(|home| Path::new(&home) == data_dir);
    if !is_home {
        restrict(data_dir, PRIVATE_DIRECTORY);
        match fs::read_dir(data_dir) {
            Ok(entries) => {
                for entry in entries.flatten() {
                    if entry.file_type().is_ok_and(|kind| !kind.is_dir()) {
                        restrict(&entry.path(), PRIVATE_FILE);
                    }
                }
            }
            Err(e) => eprintln!("[toccata-core] 无法读取数据目录 {data_dir:?}: {e}"),
        }
    }
    for path in custom_files {
        restrict(path, PRIVATE_FILE);
    }
}

/// 只处理当前用户拥有的真实文件；符号链接可能指向目录之外。
fn restrict(path: &Path, mode: u32) {
    let Ok(metadata) = fs::symlink_metadata(path) else { return };
    let owner = unsafe { libc::geteuid() };
    if metadata.file_type().is_symlink() || metadata.uid() != owner {
        return;
    }
    if metadata.permissions().mode() & 0o777 == mode {
        return;
    }
    if let Err(e) = fs::set_permissions(path, fs::Permissions::from_mode(mode)) {
        eprintln!("[toccata-core] 无法收紧权限 {path:?}: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn fixture() -> PathBuf {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "toccata-permissions-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    fn mode(path: &Path) -> u32 {
        fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn data_directory_and_files_become_private() {
        let directory = fixture();
        let database = directory.join("toccata.db");
        fs::write(&database, b"data").unwrap();
        fs::set_permissions(&database, fs::Permissions::from_mode(0o644)).unwrap();

        harden(&directory, &[]);

        assert_eq!(mode(&directory), PRIVATE_DIRECTORY);
        assert_eq!(mode(&database), PRIVATE_FILE);
        fs::remove_dir_all(&directory).unwrap();
    }

    #[test]
    fn custom_database_is_hardened_without_changing_its_directory() {
        let data = fixture();
        let custom = fixture();
        let database = custom.join("keys.db");
        fs::write(&database, b"data").unwrap();
        fs::set_permissions(&database, fs::Permissions::from_mode(0o644)).unwrap();

        harden(&data, &[database.clone(), custom.join("missing.db-wal")]);

        assert_eq!(mode(&database), PRIVATE_FILE);
        assert_eq!(mode(&custom), 0o755);
        fs::remove_dir_all(&data).unwrap();
        fs::remove_dir_all(&custom).unwrap();
    }

    #[test]
    fn symlinks_and_subdirectories_are_left_alone() {
        let directory = fixture();
        let outside = fixture();
        let target = outside.join("target");
        fs::write(&target, b"data").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o644)).unwrap();
        std::os::unix::fs::symlink(&target, directory.join("link")).unwrap();
        let nested = directory.join("nested");
        fs::create_dir(&nested).unwrap();
        fs::set_permissions(&nested, fs::Permissions::from_mode(0o755)).unwrap();

        harden(&directory, &[]);

        assert_eq!(mode(&target), 0o644);
        assert_eq!(mode(&nested), 0o755);
        fs::remove_dir_all(&directory).unwrap();
        fs::remove_dir_all(&outside).unwrap();
    }
}
