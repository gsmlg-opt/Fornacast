use rustler::{NifMap, NifTaggedEnum, NifUnitEnum};

#[derive(Clone, Copy, Debug, Eq, NifMap, PartialEq)]
pub(crate) struct ContainedTreeIdentity {
    pub(crate) mode: u32,
    pub(crate) major_device: u32,
    pub(crate) minor_device: u32,
    pub(crate) inode: u64,
}

#[derive(Clone, Copy, Debug, Eq, NifMap, PartialEq)]
pub(crate) struct ContainedTreeProof {
    pub(crate) root: ContainedTreeIdentity,
    pub(crate) target: ContainedTreeIdentity,
}

#[derive(Debug, NifTaggedEnum)]
pub(crate) enum IdentityResult {
    Present(ContainedTreeProof),
    Missing(ContainedTreeIdentity),
}

#[derive(Debug, NifTaggedEnum)]
pub(crate) enum RemoveResult {
    Removed(ContainedTreeProof),
    Missing(ContainedTreeIdentity),
}

#[derive(Clone, Copy, Debug, Eq, NifUnitEnum, PartialEq)]
pub(crate) enum AnchoredRemoveError {
    InvalidArgument,
    UnsupportedPlatform,
    NotFound,
    Symlink,
    SpecialFile,
    FilesystemDeviceChanged,
    IdentityMismatch,
    ModeMismatch,
    RootChanged,
    DepthLimit,
    EntryLimit,
    DeadlineExceeded,
    PermissionDenied,
    IoError,
}

const MAX_SEGMENT_BYTES: usize = 255;
const MAX_STORAGE_ROOT_BYTES: usize = 4_096;
const MAX_RELATIVE_SEGMENTS: usize = 128;
const MAX_TREE_DEPTH: usize = 128;
const MAX_TREE_ENTRIES: usize = 10_000;

fn validate_request(
    storage_root: &str,
    relative_segments: &[String],
) -> Result<(), AnchoredRemoveError> {
    if storage_root == "/"
        || !storage_root.starts_with('/')
        || storage_root.len() > MAX_STORAGE_ROOT_BYTES
        || storage_root.as_bytes().contains(&0)
        || storage_root.contains('\\')
        || storage_root.ends_with('/')
        || storage_root.split('/').skip(1).any(invalid_segment)
    {
        return Err(AnchoredRemoveError::InvalidArgument);
    }

    if relative_segments.is_empty() || relative_segments.len() > MAX_RELATIVE_SEGMENTS {
        return Err(AnchoredRemoveError::InvalidArgument);
    }

    if relative_segments
        .iter()
        .any(|segment| invalid_segment(segment))
    {
        return Err(AnchoredRemoveError::InvalidArgument);
    }

    Ok(())
}

fn invalid_segment(segment: &str) -> bool {
    segment.is_empty()
        || segment == "."
        || segment == ".."
        || segment.len() > MAX_SEGMENT_BYTES
        || segment.as_bytes().contains(&0)
        || segment.contains('/')
        || segment.contains('\\')
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
mod platform {
    use super::{
        AnchoredRemoveError, ContainedTreeIdentity, ContainedTreeProof, IdentityResult,
        MAX_TREE_DEPTH, MAX_TREE_ENTRIES, RemoveResult, validate_request,
    };
    use rustix::fd::OwnedFd;
    use rustix::fs::{
        AtFlags, Dir, FileType, Mode, OFlags, Stat, fstat, major, minor, open, openat, statat,
        unlinkat,
    };
    use rustix::io::{Errno, dup};
    use std::ffi::{CStr, CString};
    use std::time::{Duration, Instant};

    const DIRECTORY_OPEN_FLAGS: OFlags = OFlags::RDONLY
        .union(OFlags::DIRECTORY)
        .union(OFlags::NOFOLLOW)
        .union(OFlags::CLOEXEC);

    struct Deadline {
        started_at: Instant,
        duration: Duration,
    }

    impl Deadline {
        fn new(deadline_ms: u64) -> Result<Self, AnchoredRemoveError> {
            if deadline_ms == 0 {
                return Err(AnchoredRemoveError::DeadlineExceeded);
            }

            Ok(Self {
                started_at: Instant::now(),
                duration: Duration::from_millis(deadline_ms),
            })
        }

        fn check(&self) -> Result<(), AnchoredRemoveError> {
            if self.started_at.elapsed() >= self.duration {
                Err(AnchoredRemoveError::DeadlineExceeded)
            } else {
                Ok(())
            }
        }
    }

    struct TreeBudget {
        entries: usize,
    }

    pub(super) fn contained_tree_identity(
        storage_root: String,
        relative_segments: Vec<String>,
        deadline_ms: u64,
    ) -> Result<IdentityResult, AnchoredRemoveError> {
        validate_request(&storage_root, &relative_segments)?;
        let deadline = Deadline::new(deadline_ms)?;
        let (root_fd, root_identity) = open_storage_root(&storage_root, &deadline)?;
        let parent_fd =
            open_relative_parent(&root_fd, &root_identity, &relative_segments, &deadline)?;
        let target_name = relative_segments
            .last()
            .ok_or(AnchoredRemoveError::InvalidArgument)?;

        match open_named_directory(&parent_fd, target_name, &root_identity, &deadline, true)? {
            Some((_target_fd, target_identity)) => {
                Ok(IdentityResult::Present(ContainedTreeProof {
                    root: root_identity,
                    target: target_identity,
                }))
            }
            None => Ok(IdentityResult::Missing(root_identity)),
        }
    }

    pub(super) fn remove_contained_tree(
        storage_root: String,
        relative_segments: Vec<String>,
        expected_proof: ContainedTreeProof,
        deadline_ms: u64,
    ) -> Result<RemoveResult, AnchoredRemoveError> {
        validate_request(&storage_root, &relative_segments)?;
        validate_proof(&expected_proof)?;
        let deadline = Deadline::new(deadline_ms)?;
        let (root_fd, root_identity) = open_storage_root(&storage_root, &deadline)?;
        compare_root(root_identity, expected_proof.root)?;

        let parent_fd =
            open_relative_parent(&root_fd, &root_identity, &relative_segments, &deadline)?;
        let target_name = relative_segments
            .last()
            .ok_or(AnchoredRemoveError::InvalidArgument)?;
        let Some((target_fd, target_identity)) =
            open_named_directory(&parent_fd, target_name, &root_identity, &deadline, true)?
        else {
            return Ok(RemoveResult::Missing(root_identity));
        };
        compare_target(target_identity, expected_proof.target)?;

        let mut budget = TreeBudget { entries: 0 };
        preflight_directory(&target_fd, &root_identity, 0, &mut budget, &deadline)?;
        remove_directory_contents(&target_fd, &root_identity, 0, &deadline)?;

        deadline.check()?;
        let (current_root_fd, current_root_identity) = open_storage_root(&storage_root, &deadline)?;
        compare_root(current_root_identity, expected_proof.root)?;
        let current_parent = open_relative_parent(
            &current_root_fd,
            &current_root_identity,
            &relative_segments,
            &deadline,
        )?;
        let Some((_current_target_fd, current_target_identity)) = open_named_directory(
            &current_parent,
            target_name,
            &current_root_identity,
            &deadline,
            false,
        )?
        else {
            return Err(AnchoredRemoveError::IdentityMismatch);
        };
        compare_target(current_target_identity, expected_proof.target)?;
        deadline.check()?;
        unlinkat(&current_parent, target_name, AtFlags::REMOVEDIR).map_err(map_io_error)?;

        Ok(RemoveResult::Removed(expected_proof))
    }

    fn validate_proof(proof: &ContainedTreeProof) -> Result<(), AnchoredRemoveError> {
        if proof.root.inode == 0 || proof.target.inode == 0 {
            Err(AnchoredRemoveError::InvalidArgument)
        } else {
            Ok(())
        }
    }

    fn open_storage_root(
        storage_root: &str,
        deadline: &Deadline,
    ) -> Result<(OwnedFd, ContainedTreeIdentity), AnchoredRemoveError> {
        deadline.check()?;
        let mut current = open("/", DIRECTORY_OPEN_FLAGS, Mode::empty()).map_err(map_io_error)?;

        for component in storage_root.split('/').skip(1) {
            let (next, _identity) = open_named_directory_required(&current, component, deadline)?;
            current = next;
        }

        let identity = identity_from_stat(&fstat(&current).map_err(map_io_error)?)?;
        Ok((current, identity))
    }

    fn open_relative_parent(
        root_fd: &OwnedFd,
        root_identity: &ContainedTreeIdentity,
        relative_segments: &[String],
        deadline: &Deadline,
    ) -> Result<OwnedFd, AnchoredRemoveError> {
        let mut current = dup(root_fd).map_err(map_io_error)?;

        for component in relative_segments.iter().take(relative_segments.len() - 1) {
            let (next, identity) = open_named_directory_required(&current, component, deadline)?;
            ensure_same_filesystem(root_identity, &identity)?;
            current = next;
        }

        Ok(current)
    }

    fn open_named_directory_required(
        parent: &OwnedFd,
        name: &str,
        deadline: &Deadline,
    ) -> Result<(OwnedFd, ContainedTreeIdentity), AnchoredRemoveError> {
        open_named_directory_unchecked(parent, name, deadline)?.ok_or(AnchoredRemoveError::NotFound)
    }

    fn open_named_directory(
        parent: &OwnedFd,
        name: &str,
        root_identity: &ContainedTreeIdentity,
        deadline: &Deadline,
        allow_missing: bool,
    ) -> Result<Option<(OwnedFd, ContainedTreeIdentity)>, AnchoredRemoveError> {
        let opened = open_named_directory_unchecked(parent, name, deadline)?;
        if let Some((_fd, identity)) = &opened {
            ensure_same_filesystem(root_identity, identity)?;
        }
        if opened.is_none() && !allow_missing {
            return Ok(None);
        }
        Ok(opened)
    }

    fn open_named_directory_unchecked(
        parent: &OwnedFd,
        name: &str,
        deadline: &Deadline,
    ) -> Result<Option<(OwnedFd, ContainedTreeIdentity)>, AnchoredRemoveError> {
        deadline.check()?;
        let named_stat = match statat(parent, name, AtFlags::SYMLINK_NOFOLLOW) {
            Ok(stat) => stat,
            Err(Errno::NOENT) => return Ok(None),
            Err(error) => return Err(map_io_error(error)),
        };
        classify_directory(&named_stat)?;
        let named_identity = identity_from_stat(&named_stat)?;
        deadline.check()?;
        let fd = openat(parent, name, DIRECTORY_OPEN_FLAGS, Mode::empty()).map_err(map_io_error)?;
        let opened_stat = fstat(&fd).map_err(map_io_error)?;
        classify_directory(&opened_stat)?;
        let opened_identity = identity_from_stat(&opened_stat)?;
        compare_observation(opened_identity, named_identity)?;
        Ok(Some((fd, opened_identity)))
    }

    fn classify_directory(stat: &Stat) -> Result<(), AnchoredRemoveError> {
        match FileType::from_raw_mode(stat.st_mode) {
            FileType::Directory => Ok(()),
            FileType::Symlink => Err(AnchoredRemoveError::Symlink),
            _ => Err(AnchoredRemoveError::SpecialFile),
        }
    }

    fn identity_from_stat(stat: &Stat) -> Result<ContainedTreeIdentity, AnchoredRemoveError> {
        let inode: u64 = stat.st_ino;
        if inode == 0 {
            return Err(AnchoredRemoveError::IoError);
        }

        Ok(ContainedTreeIdentity {
            mode: permission_mode(stat),
            major_device: major(stat.st_dev),
            minor_device: minor(stat.st_dev),
            inode,
        })
    }

    #[cfg(target_os = "linux")]
    fn permission_mode(stat: &Stat) -> u32 {
        stat.st_mode & 0o777
    }

    #[cfg(target_os = "macos")]
    fn permission_mode(stat: &Stat) -> u32 {
        u32::from(stat.st_mode) & 0o777
    }

    fn ensure_same_filesystem(
        root: &ContainedTreeIdentity,
        descendant: &ContainedTreeIdentity,
    ) -> Result<(), AnchoredRemoveError> {
        if root.major_device == descendant.major_device
            && root.minor_device == descendant.minor_device
        {
            Ok(())
        } else {
            Err(AnchoredRemoveError::FilesystemDeviceChanged)
        }
    }

    fn compare_observation(
        opened: ContainedTreeIdentity,
        named: ContainedTreeIdentity,
    ) -> Result<(), AnchoredRemoveError> {
        if opened.mode != named.mode {
            Err(AnchoredRemoveError::ModeMismatch)
        } else if opened != named {
            Err(AnchoredRemoveError::IdentityMismatch)
        } else {
            Ok(())
        }
    }

    fn compare_root(
        current: ContainedTreeIdentity,
        expected: ContainedTreeIdentity,
    ) -> Result<(), AnchoredRemoveError> {
        if current.mode != expected.mode {
            Err(AnchoredRemoveError::ModeMismatch)
        } else if current != expected {
            Err(AnchoredRemoveError::RootChanged)
        } else {
            Ok(())
        }
    }

    fn compare_target(
        current: ContainedTreeIdentity,
        expected: ContainedTreeIdentity,
    ) -> Result<(), AnchoredRemoveError> {
        if current.mode != expected.mode {
            Err(AnchoredRemoveError::ModeMismatch)
        } else if current != expected {
            Err(AnchoredRemoveError::IdentityMismatch)
        } else {
            Ok(())
        }
    }

    fn preflight_directory(
        directory: &OwnedFd,
        root_identity: &ContainedTreeIdentity,
        depth: usize,
        budget: &mut TreeBudget,
        deadline: &Deadline,
    ) -> Result<(), AnchoredRemoveError> {
        deadline.check()?;
        if depth > MAX_TREE_DEPTH {
            return Err(AnchoredRemoveError::DepthLimit);
        }

        let mut entries = Dir::read_from(directory).map_err(map_io_error)?;
        while let Some(entry) = entries.read() {
            deadline.check()?;
            let entry = entry.map_err(map_io_error)?;
            let name = entry.file_name();
            if is_dot_entry(name) {
                continue;
            }

            budget.entries = budget
                .entries
                .checked_add(1)
                .ok_or(AnchoredRemoveError::EntryLimit)?;
            if budget.entries > MAX_TREE_ENTRIES {
                return Err(AnchoredRemoveError::EntryLimit);
            }

            let stat = statat(directory, name, AtFlags::SYMLINK_NOFOLLOW).map_err(map_io_error)?;
            let identity = identity_from_stat(&stat)?;
            ensure_same_filesystem(root_identity, &identity)?;

            match FileType::from_raw_mode(stat.st_mode) {
                FileType::RegularFile => {}
                FileType::Directory => {
                    if depth == MAX_TREE_DEPTH {
                        return Err(AnchoredRemoveError::DepthLimit);
                    }
                    let child = open_child_directory(directory, name, identity, deadline)?;
                    preflight_directory(&child, root_identity, depth + 1, budget, deadline)?;
                }
                FileType::Symlink => return Err(AnchoredRemoveError::Symlink),
                _ => return Err(AnchoredRemoveError::SpecialFile),
            }
        }

        Ok(())
    }

    fn remove_directory_contents(
        directory: &OwnedFd,
        root_identity: &ContainedTreeIdentity,
        depth: usize,
        deadline: &Deadline,
    ) -> Result<(), AnchoredRemoveError> {
        deadline.check()?;
        if depth > MAX_TREE_DEPTH {
            return Err(AnchoredRemoveError::DepthLimit);
        }

        let names = directory_entry_names(directory, deadline)?;
        for name in names {
            deadline.check()?;
            let stat = statat(directory, &name, AtFlags::SYMLINK_NOFOLLOW).map_err(map_io_error)?;
            let identity = identity_from_stat(&stat)?;
            ensure_same_filesystem(root_identity, &identity)?;

            match FileType::from_raw_mode(stat.st_mode) {
                FileType::RegularFile => {
                    unlinkat(directory, &name, AtFlags::empty()).map_err(map_io_error)?;
                }
                FileType::Directory => {
                    let child = open_child_directory(directory, &name, identity, deadline)?;
                    remove_directory_contents(&child, root_identity, depth + 1, deadline)?;
                    deadline.check()?;
                    let current = statat(directory, &name, AtFlags::SYMLINK_NOFOLLOW)
                        .map_err(map_io_error)?;
                    classify_directory(&current)?;
                    compare_observation(identity_from_stat(&current)?, identity)?;
                    unlinkat(directory, &name, AtFlags::REMOVEDIR).map_err(map_io_error)?;
                }
                FileType::Symlink => return Err(AnchoredRemoveError::Symlink),
                _ => return Err(AnchoredRemoveError::SpecialFile),
            }
        }

        Ok(())
    }

    fn directory_entry_names(
        directory: &OwnedFd,
        deadline: &Deadline,
    ) -> Result<Vec<CString>, AnchoredRemoveError> {
        let mut names = Vec::new();
        let mut entries = Dir::read_from(directory).map_err(map_io_error)?;
        while let Some(entry) = entries.read() {
            deadline.check()?;
            let entry = entry.map_err(map_io_error)?;
            if !is_dot_entry(entry.file_name()) {
                if names.len() == MAX_TREE_ENTRIES {
                    return Err(AnchoredRemoveError::EntryLimit);
                }
                names.push(entry.file_name().to_owned());
            }
        }
        Ok(names)
    }

    fn open_child_directory(
        parent: &OwnedFd,
        name: &CStr,
        named_identity: ContainedTreeIdentity,
        deadline: &Deadline,
    ) -> Result<OwnedFd, AnchoredRemoveError> {
        deadline.check()?;
        let child =
            openat(parent, name, DIRECTORY_OPEN_FLAGS, Mode::empty()).map_err(map_io_error)?;
        let opened_stat = fstat(&child).map_err(map_io_error)?;
        classify_directory(&opened_stat)?;
        compare_observation(identity_from_stat(&opened_stat)?, named_identity)?;
        Ok(child)
    }

    fn is_dot_entry(name: &CStr) -> bool {
        name.to_bytes() == b"." || name.to_bytes() == b".."
    }

    fn map_io_error(error: Errno) -> AnchoredRemoveError {
        match error {
            Errno::NOENT => AnchoredRemoveError::NotFound,
            Errno::LOOP => AnchoredRemoveError::Symlink,
            Errno::ACCESS | Errno::PERM => AnchoredRemoveError::PermissionDenied,
            _ => AnchoredRemoveError::IoError,
        }
    }
}

pub(crate) fn contained_tree_identity(
    storage_root: String,
    relative_segments: Vec<String>,
    deadline_ms: u64,
) -> Result<IdentityResult, AnchoredRemoveError> {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        platform::contained_tree_identity(storage_root, relative_segments, deadline_ms)
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = (storage_root, relative_segments, deadline_ms);
        Err(AnchoredRemoveError::UnsupportedPlatform)
    }
}

pub(crate) fn remove_contained_tree(
    storage_root: String,
    relative_segments: Vec<String>,
    expected_proof: ContainedTreeProof,
    deadline_ms: u64,
) -> Result<RemoveResult, AnchoredRemoveError> {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        platform::remove_contained_tree(
            storage_root,
            relative_segments,
            expected_proof,
            deadline_ms,
        )
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = (storage_root, relative_segments, expected_proof, deadline_ms);
        Err(AnchoredRemoveError::UnsupportedPlatform)
    }
}

#[cfg(test)]
mod anchored_remove_tests {
    use super::{AnchoredRemoveError, IdentityResult, RemoveResult};
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture_root(name: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock after epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("fornacast-anchored-remove-{name}-{nonce}"))
    }

    #[test]
    fn anchored_remove_rejects_non_canonical_input() {
        assert!(matches!(
            super::contained_tree_identity("/".to_string(), vec!["target".to_string()], 1),
            Err(AnchoredRemoveError::InvalidArgument)
        ));
        assert!(matches!(
            super::contained_tree_identity("/tmp".to_string(), vec!["..".to_string()], 1),
            Err(AnchoredRemoveError::InvalidArgument)
        ));
    }

    #[test]
    fn anchored_remove_observes_removes_and_replays_a_private_temp_tree() {
        let root = fixture_root("success");
        let target = root.join("quarantine").join("repository.git");
        fs::create_dir_all(target.join("objects")).expect("create temp fixture");
        fs::write(target.join("objects").join("pack"), b"git data").expect("write fixture");

        let root_string = root.to_str().expect("UTF-8 temp path").to_string();
        let segments = vec!["quarantine".to_string(), "repository.git".to_string()];
        let proof =
            match super::contained_tree_identity(root_string.clone(), segments.clone(), 5_000)
                .expect("observe tree")
            {
                IdentityResult::Present(proof) => proof,
                IdentityResult::Missing(_) => panic!("expected present tree"),
            };

        assert!(matches!(
            super::remove_contained_tree(root_string.clone(), segments.clone(), proof, 5_000),
            Ok(RemoveResult::Removed(removed)) if removed == proof
        ));
        assert!(!target.exists());
        assert!(matches!(
            super::remove_contained_tree(root_string, segments, proof, 5_000),
            Ok(RemoveResult::Missing(root_identity)) if root_identity == proof.root
        ));

        fs::remove_dir(root.join("quarantine")).expect("remove empty quarantine parent");
        fs::remove_dir(root).expect("remove temp fixture root");
    }

    #[test]
    fn anchored_remove_zero_deadline_has_no_effect() {
        let root = fixture_root("deadline");
        let target = root.join("target");
        fs::create_dir_all(&target).expect("create temp fixture");
        let root_string = root.to_str().expect("UTF-8 temp path").to_string();

        assert!(matches!(
            super::contained_tree_identity(root_string, vec!["target".to_string()], 0),
            Err(AnchoredRemoveError::DeadlineExceeded)
        ));
        assert!(target.is_dir());

        fs::remove_dir(target).expect("remove target");
        fs::remove_dir(root).expect("remove temp fixture root");
    }
}
