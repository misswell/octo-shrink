// OctoShrink - 跨启动的文件访问授权。
//
// Direct 版没有沙盒限制，这里是直通实现。App Store 沙盒版只对用户"刚刚选中"的
// 路径持有临时授权，关闭 App 就失效，所以必须把路径存成 security-scoped
// bookmark，才能让「关闭 App → 重新打开 → 历史页恢复原图」真正可用。
//
// 每个书签单独存成一个二进制文件（<AppData>/history/bookmarks/<hash>.bookmark），
// 避免整体 JSON 重写：单个写坏只会影响一个目录，不会毁掉全部授权。

use std::path::{Path, PathBuf};
use std::sync::Arc;

/// 一次文件访问的守卫；Drop 即释放访问（沙盒下 stopAccessingSecurityScopedResource）。
pub struct AccessGuard {
    stop: Option<Box<dyn FnOnce() + Send>>,
}

impl AccessGuard {
    #[cfg(any(
        test,
        not(all(target_os = "macos", feature = "inproc-backends"))
    ))]
    fn unrestricted() -> Self {
        Self { stop: None }
    }
}

impl Drop for AccessGuard {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            stop();
        }
    }
}

pub trait FileAccess: Send + Sync {
    /// 取得 `path`（文件或目录）的访问权。授权失效时调用 `reauth` 请用户重新
    /// 授权后重试一次；返回 `None` 表示最终仍无法访问。
    fn acquire(&self, path: &Path, reauth: &mut dyn FnMut() -> bool) -> Option<AccessGuard>;

    /// 记录刚刚拿到访问权的路径（连同父目录），供以后启动使用。
    fn remember(&self, path: &Path);

    fn remember_all(&self, paths: &[String]) {
        for path in paths {
            self.remember(Path::new(path));
        }
    }
}

/// 两条产物线共用同一入口：沙盒版用书签，其余一律直通。
pub fn build_access(bookmark_dir: PathBuf) -> Arc<dyn FileAccess> {
    #[cfg(all(target_os = "macos", feature = "inproc-backends"))]
    {
        Arc::new(BookmarkAccess::new(bookmark_dir))
    }
    #[cfg(not(all(target_os = "macos", feature = "inproc-backends")))]
    {
        let _ = bookmark_dir;
        unrestricted()
    }
}

/// 不做任何沙盒处理的实现：Direct 版用它，沙盒版只有单元测试用。
#[cfg(any(
    test,
    not(all(target_os = "macos", feature = "inproc-backends"))
))]
pub fn unrestricted() -> Arc<dyn FileAccess> {
    Arc::new(UnrestrictedAccess)
}

#[cfg(any(
    test,
    not(all(target_os = "macos", feature = "inproc-backends"))
))]
struct UnrestrictedAccess;

#[cfg(any(
    test,
    not(all(target_os = "macos", feature = "inproc-backends"))
))]
impl FileAccess for UnrestrictedAccess {
    fn acquire(&self, _path: &Path, _reauth: &mut dyn FnMut() -> bool) -> Option<AccessGuard> {
        Some(AccessGuard::unrestricted())
    }

    fn remember(&self, _path: &Path) {}
}

#[cfg(any(
    test,
    all(target_os = "macos", feature = "inproc-backends")
))]
/// 从目标路径往上到根，越具体（越深）的授权优先级越高。
fn access_candidates(path: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut cursor = Some(path);
    while let Some(current) = cursor {
        out.push(current.to_path_buf());
        cursor = current.parent();
    }
    out
}

#[cfg(all(target_os = "macos", feature = "inproc-backends"))]
struct BookmarkAccess {
    dir: PathBuf,
}

#[cfg(all(target_os = "macos", feature = "inproc-backends"))]
impl BookmarkAccess {
    fn new(dir: PathBuf) -> Self {
        let _ = std::fs::create_dir_all(&dir);
        Self { dir }
    }

    fn slot(&self, path: &Path) -> PathBuf {
        self.dir.join(format!(
            "{}.bookmark",
            crate::history::HistoryStore::backup_key(path)
        ))
    }

    fn grant(
        &self,
        url: &objc2::rc::Retained<objc2_foundation::NSURL>,
    ) -> Option<AccessGuard> {
        let started = unsafe { url.startAccessingSecurityScopedResource() };
        if !started {
            return None;
        }
        let url = url.clone();
        Some(AccessGuard {
            stop: Some(Box::new(move || {
                unsafe { url.stopAccessingSecurityScopedResource() }
            })),
        })
    }
}

#[cfg(all(target_os = "macos", feature = "inproc-backends"))]
impl FileAccess for BookmarkAccess {
    fn acquire(&self, path: &Path, reauth: &mut dyn FnMut() -> bool) -> Option<AccessGuard> {
        let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        for candidate in access_candidates(&resolved) {
            if let Some(guard) = self.try_slot(&candidate) {
                return Some(guard);
            }
        }
        // 书签过期 / 从没记录过：请用户重新选一次目标文件夹，再试一遍。
        if !reauth() {
            return None;
        }
        let resolved = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        self.remember(&resolved);
        for candidate in access_candidates(&resolved) {
            if let Some(guard) = self.try_slot(&candidate) {
                return Some(guard);
            }
        }
        None
    }

    fn remember(&self, path: &Path) {
        let Ok(resolved) = path.canonicalize() else {
            return;
        };
        let slot = self.slot(&resolved);
        if slot.exists() {
            return;
        }
        self.write_bookmark(&resolved, &slot);
        // 目录授权能覆盖里面的文件，恢复时父目录这一条最常命中。
        if let Some(parent) = resolved.parent() {
            let Ok(parent) = parent.canonicalize() else {
                return;
            };
            let parent_slot = self.slot(&parent);
            if !parent_slot.exists() {
                self.write_bookmark(&parent, &parent_slot);
            }
        }
    }
}

#[cfg(all(target_os = "macos", feature = "inproc-backends"))]
impl BookmarkAccess {
    fn write_bookmark(&self, path: &Path, slot: &Path) {
        use objc2_foundation::{NSURL, NSString};

        let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
        let options = objc2_foundation::NSURLBookmarkCreationOptions::WithSecurityScope;
        let Ok(data) =
            url.bookmarkDataWithOptions_includingResourceValuesForKeys_relativeToURL_error(
                options, None, None,
            )
        else {
            return;
        };
        write_slot(&data, slot);
    }

    fn try_slot(&self, path: &Path) -> Option<AccessGuard> {
        use objc2_foundation::{NSData, NSURL, NSURLBookmarkResolutionOptions, NSString};

        let slot = self.slot(path);
        let raw = NSData::dataWithContentsOfFile(&NSString::from_str(&slot.to_string_lossy()))?;
        let mut stale = objc2::runtime::Bool::default();
        let url = unsafe {
            NSURL::URLByResolvingBookmarkData_options_relativeToURL_bookmarkDataIsStale_error(
                &raw,
                NSURLBookmarkResolutionOptions::WithSecurityScope,
                None,
                &mut stale,
            )
        }
        .ok()?;
        if stale.as_bool() {
            // 同一 URL 重新签一份书签即可续期，不需要打扰用户。
            self.write_bookmark(path, &slot);
        }
        self.grant(&url)
    }
}

#[cfg(all(target_os = "macos", feature = "inproc-backends"))]
fn write_slot(data: &objc2_foundation::NSData, slot: &std::path::Path) {
    use objc2_foundation::NSString;

    data.writeToFile_atomically(&NSString::from_str(&slot.to_string_lossy()), true);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ancestor_walk_goes_from_the_file_up_to_the_root() {
        let candidates = access_candidates(Path::new("/tmp/a/b.png"));
        assert_eq!(candidates[0], PathBuf::from("/tmp/a/b.png"));
        assert_eq!(*candidates.last().unwrap(), PathBuf::from("/"));
        assert!(candidates.windows(2).all(|w| w[1] == w[0].parent().unwrap()));
    }

    /// Direct 版没有沙盒，任何路径都必须直通放行，且不得碰文件系统。
    #[cfg(not(all(target_os = "macos", feature = "inproc-backends")))]
    #[test]
    fn non_sandbox_builds_always_grant_access() {
        let access = build_access(PathBuf::from("/unused"));
        let guard = access
            .acquire(Path::new("/does/not/matter"), &mut || false)
            .expect("直通实现必须放行");
        drop(guard);
        // 记录路径在 Direct 版是空操作，不得碰文件系统。
        access.remember(Path::new("/does/not/matter"));
    }
}
