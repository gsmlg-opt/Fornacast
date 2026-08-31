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

fn regular_unlink_postcheck(
    links_before: u64,
    links_after: u64,
) -> Result<(), AnchoredRemoveError> {
    if links_before > 0 && links_after.checked_add(1) == Some(links_before) {
        Ok(())
    } else {
        Err(AnchoredRemoveError::IdentityMismatch)
    }
}

fn directory_policy_check(
    effective_uid: u32,
    owner_uid: u32,
    permission_mode: u32,
) -> Result<(), AnchoredRemoveError> {
    if owner_uid != effective_uid {
        Err(AnchoredRemoveError::PermissionDenied)
    } else if permission_mode & 0o022 != 0 {
        Err(AnchoredRemoveError::ModeMismatch)
    } else {
        Ok(())
    }
}

#[cfg(target_os = "linux")]
fn directory_unlink_postcheck(links_after: u64) -> Result<(), AnchoredRemoveError> {
    if links_after == 0 {
        Ok(())
    } else {
        Err(AnchoredRemoveError::IdentityMismatch)
    }
}

#[cfg(target_os = "macos")]
fn directory_unlink_postcheck(links_after: u64) -> Result<(), AnchoredRemoveError> {
    // Darwin, like Linux, reports zero links for a held descriptor after rmdir.
    if links_after == 0 {
        Ok(())
    } else {
        Err(AnchoredRemoveError::IdentityMismatch)
    }
}

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
        MAX_TREE_DEPTH, MAX_TREE_ENTRIES, RemoveResult, directory_policy_check,
        directory_unlink_postcheck, regular_unlink_postcheck, validate_request,
    };
    use rustix::fd::OwnedFd;
    use rustix::fs::{
        AtFlags, Dir, FileType, Mode, OFlags, Stat, fstat, major, minor, open, openat, statat,
        unlinkat,
    };
    use rustix::io::{Errno, dup};
    use rustix::process::geteuid;
    use std::ffi::{CStr, CString};
    use std::time::{Duration, Instant};

    const DIRECTORY_OPEN_FLAGS: OFlags = OFlags::RDONLY
        .union(OFlags::DIRECTORY)
        .union(OFlags::NOFOLLOW)
        .union(OFlags::CLOEXEC);

    #[cfg(target_os = "linux")]
    fn regular_file_open_flags() -> OFlags {
        OFlags::PATH | OFlags::NOFOLLOW | OFlags::CLOEXEC
    }

    #[cfg(target_os = "macos")]
    fn regular_file_open_flags() -> OFlags {
        OFlags::from_bits_retain(libc::O_EVTONLY as u32) | OFlags::NOFOLLOW | OFlags::CLOEXEC
    }

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

    // POSIX cannot condition unlinkat on inode. Safety therefore depends on the approved
    // cooperative threat model: every mutable directory below the configured root is owned by
    // this effective UID and is not writable by its group or by other users. R8D additionally
    // serializes repository readers and writers before calling the destructive NIF.
    struct TraversalPolicy {
        effective_uid: u32,
    }

    impl TraversalPolicy {
        fn current() -> Self {
            Self {
                effective_uid: geteuid().as_raw(),
            }
        }
    }

    struct DirectoryManifest {
        entries: Vec<ManifestEntry>,
    }

    struct ManifestEntry {
        name: CString,
        identity: ContainedTreeIdentity,
        kind: ManifestEntryKind,
    }

    enum ManifestEntryKind {
        RegularFile,
        Directory(DirectoryManifest),
    }

    pub(super) fn contained_tree_identity(
        storage_root: String,
        relative_segments: Vec<String>,
        deadline_ms: u64,
    ) -> Result<IdentityResult, AnchoredRemoveError> {
        validate_request(&storage_root, &relative_segments)?;
        let deadline = Deadline::new(deadline_ms)?;
        let policy = TraversalPolicy::current();
        let (root_fd, root_identity) = open_storage_root(&storage_root, &policy, &deadline)?;
        let parent_fd = open_relative_parent(
            &root_fd,
            &root_identity,
            &relative_segments,
            &policy,
            &deadline,
        )?;
        let target_name = relative_segments
            .last()
            .ok_or(AnchoredRemoveError::InvalidArgument)?;

        match open_named_directory(
            &parent_fd,
            target_name,
            &root_identity,
            &policy,
            &deadline,
            true,
        )? {
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
        remove_contained_tree_with_pre_delete(
            storage_root,
            relative_segments,
            expected_proof,
            deadline_ms,
            || {},
        )
    }

    pub(super) fn remove_contained_tree_with_pre_delete<F>(
        storage_root: String,
        relative_segments: Vec<String>,
        expected_proof: ContainedTreeProof,
        deadline_ms: u64,
        before_delete: F,
    ) -> Result<RemoveResult, AnchoredRemoveError>
    where
        F: FnOnce(),
    {
        validate_request(&storage_root, &relative_segments)?;
        validate_proof(&expected_proof)?;
        let deadline = Deadline::new(deadline_ms)?;
        let policy = TraversalPolicy::current();
        let (root_fd, root_identity) = open_storage_root(&storage_root, &policy, &deadline)?;
        compare_root(root_identity, expected_proof.root)?;

        let parent_fd = open_relative_parent(
            &root_fd,
            &root_identity,
            &relative_segments,
            &policy,
            &deadline,
        )?;
        let target_name = relative_segments
            .last()
            .ok_or(AnchoredRemoveError::InvalidArgument)?;
        let Some((target_fd, target_identity)) = open_named_directory(
            &parent_fd,
            target_name,
            &root_identity,
            &policy,
            &deadline,
            true,
        )?
        else {
            return Ok(RemoveResult::Missing(root_identity));
        };
        compare_target(target_identity, expected_proof.target)?;

        let mut budget = TreeBudget { entries: 0 };
        let manifest = preflight_directory(
            &target_fd,
            &root_identity,
            &policy,
            0,
            &mut budget,
            &deadline,
        )?;
        before_delete();
        remove_manifest(&target_fd, &root_identity, &policy, &manifest, 0, &deadline)?;

        deadline.check()?;
        let (current_root_fd, current_root_identity) =
            open_storage_root(&storage_root, &policy, &deadline)?;
        compare_root(current_root_identity, expected_proof.root)?;
        let current_parent = open_relative_parent(
            &current_root_fd,
            &current_root_identity,
            &relative_segments,
            &policy,
            &deadline,
        )?;
        let Some((current_target_fd, current_target_identity)) = open_named_directory(
            &current_parent,
            target_name,
            &current_root_identity,
            &policy,
            &deadline,
            false,
        )?
        else {
            return Err(AnchoredRemoveError::IdentityMismatch);
        };
        compare_target(current_target_identity, expected_proof.target)?;
        deadline.check()?;
        unlinkat(&current_parent, target_name, AtFlags::REMOVEDIR).map_err(map_io_error)?;
        let removed_target_stat = fstat(&current_target_fd).map_err(map_io_error)?;
        compare_target(
            identity_from_stat(&removed_target_stat)?,
            expected_proof.target,
        )?;
        directory_unlink_postcheck(link_count(&removed_target_stat))?;

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
        policy: &TraversalPolicy,
        deadline: &Deadline,
    ) -> Result<(OwnedFd, ContainedTreeIdentity), AnchoredRemoveError> {
        deadline.check()?;
        let mut current = open("/", DIRECTORY_OPEN_FLAGS, Mode::empty()).map_err(map_io_error)?;

        for component in storage_root.split('/').skip(1) {
            let (next, _identity) = open_named_directory_required(&current, component, deadline)?;
            current = next;
        }

        let root_stat = fstat(&current).map_err(map_io_error)?;
        enforce_directory_policy(&root_stat, policy)?;
        let identity = identity_from_stat(&root_stat)?;
        Ok((current, identity))
    }

    fn open_relative_parent(
        root_fd: &OwnedFd,
        root_identity: &ContainedTreeIdentity,
        relative_segments: &[String],
        policy: &TraversalPolicy,
        deadline: &Deadline,
    ) -> Result<OwnedFd, AnchoredRemoveError> {
        let mut current = dup(root_fd).map_err(map_io_error)?;

        for component in relative_segments.iter().take(relative_segments.len() - 1) {
            let (next, identity) = open_named_directory_required(&current, component, deadline)?;
            ensure_same_filesystem(root_identity, &identity)?;
            enforce_opened_directory_policy(&next, policy)?;
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
        policy: &TraversalPolicy,
        deadline: &Deadline,
        allow_missing: bool,
    ) -> Result<Option<(OwnedFd, ContainedTreeIdentity)>, AnchoredRemoveError> {
        let opened = open_named_directory_unchecked(parent, name, deadline)?;
        if let Some((fd, identity)) = &opened {
            ensure_same_filesystem(root_identity, identity)?;
            enforce_opened_directory_policy(fd, policy)?;
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
        policy: &TraversalPolicy,
        depth: usize,
        budget: &mut TreeBudget,
        deadline: &Deadline,
    ) -> Result<DirectoryManifest, AnchoredRemoveError> {
        deadline.check()?;
        if depth > MAX_TREE_DEPTH {
            return Err(AnchoredRemoveError::DepthLimit);
        }

        let mut entries = Dir::read_from(directory).map_err(map_io_error)?;
        let mut manifest_entries = Vec::new();
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

            let kind = match FileType::from_raw_mode(stat.st_mode) {
                FileType::RegularFile => ManifestEntryKind::RegularFile,
                FileType::Directory => {
                    if depth == MAX_TREE_DEPTH {
                        return Err(AnchoredRemoveError::DepthLimit);
                    }
                    let child = open_child_directory(directory, name, identity, policy, deadline)?;
                    ManifestEntryKind::Directory(preflight_directory(
                        &child,
                        root_identity,
                        policy,
                        depth + 1,
                        budget,
                        deadline,
                    )?)
                }
                FileType::Symlink => return Err(AnchoredRemoveError::Symlink),
                _ => return Err(AnchoredRemoveError::SpecialFile),
            };

            manifest_entries.push(ManifestEntry {
                name: name.to_owned(),
                identity,
                kind,
            });
        }

        Ok(DirectoryManifest {
            entries: manifest_entries,
        })
    }

    fn remove_manifest(
        directory: &OwnedFd,
        root_identity: &ContainedTreeIdentity,
        policy: &TraversalPolicy,
        manifest: &DirectoryManifest,
        depth: usize,
        deadline: &Deadline,
    ) -> Result<(), AnchoredRemoveError> {
        deadline.check()?;
        if depth > MAX_TREE_DEPTH {
            return Err(AnchoredRemoveError::DepthLimit);
        }

        for entry in &manifest.entries {
            deadline.check()?;
            let stat = statat(directory, &entry.name, AtFlags::SYMLINK_NOFOLLOW)
                .map_err(map_manifest_io_error)?;
            verify_manifest_entry(&stat, root_identity, entry)?;

            match &entry.kind {
                ManifestEntryKind::RegularFile => {
                    let (opened, links_before) =
                        open_manifest_regular_file(directory, root_identity, entry, deadline)?;
                    unlinkat(directory, &entry.name, AtFlags::empty()).map_err(map_io_error)?;
                    let unlinked_stat = fstat(&opened).map_err(map_io_error)?;
                    verify_manifest_entry(&unlinked_stat, root_identity, entry)?;
                    regular_unlink_postcheck(links_before, link_count(&unlinked_stat))?;
                }
                ManifestEntryKind::Directory(children) => {
                    let child = open_child_directory(
                        directory,
                        &entry.name,
                        entry.identity,
                        policy,
                        deadline,
                    )?;
                    remove_manifest(&child, root_identity, policy, children, depth + 1, deadline)?;
                    deadline.check()?;
                    let current = statat(directory, &entry.name, AtFlags::SYMLINK_NOFOLLOW)
                        .map_err(map_manifest_io_error)?;
                    verify_manifest_entry(&current, root_identity, entry)?;
                    let reopened = open_child_directory(
                        directory,
                        &entry.name,
                        entry.identity,
                        policy,
                        deadline,
                    )?;
                    unlinkat(directory, &entry.name, AtFlags::REMOVEDIR).map_err(map_io_error)?;
                    let unlinked_stat = fstat(&reopened).map_err(map_io_error)?;
                    verify_manifest_entry(&unlinked_stat, root_identity, entry)?;
                    directory_unlink_postcheck(link_count(&unlinked_stat))?;
                }
            }
        }

        Ok(())
    }

    fn verify_manifest_entry(
        stat: &Stat,
        root_identity: &ContainedTreeIdentity,
        entry: &ManifestEntry,
    ) -> Result<(), AnchoredRemoveError> {
        let current_identity = identity_from_stat(stat)?;
        ensure_same_filesystem(root_identity, &current_identity)?;

        let kind_matches = matches!(
            (&entry.kind, FileType::from_raw_mode(stat.st_mode)),
            (ManifestEntryKind::RegularFile, FileType::RegularFile)
                | (ManifestEntryKind::Directory(_), FileType::Directory)
        );
        if !kind_matches {
            return Err(AnchoredRemoveError::IdentityMismatch);
        }

        compare_observation(current_identity, entry.identity)
    }

    fn open_manifest_regular_file(
        parent: &OwnedFd,
        root_identity: &ContainedTreeIdentity,
        entry: &ManifestEntry,
        deadline: &Deadline,
    ) -> Result<(OwnedFd, u64), AnchoredRemoveError> {
        deadline.check()?;
        let opened = openat(
            parent,
            &entry.name,
            regular_file_open_flags(),
            Mode::empty(),
        )
        .map_err(map_manifest_io_error)?;
        let opened_stat = fstat(&opened).map_err(map_io_error)?;
        verify_manifest_entry(&opened_stat, root_identity, entry)?;
        let links_before = link_count(&opened_stat);
        if links_before == 0 {
            return Err(AnchoredRemoveError::IdentityMismatch);
        }
        Ok((opened, links_before))
    }

    fn open_child_directory(
        parent: &OwnedFd,
        name: &CStr,
        named_identity: ContainedTreeIdentity,
        policy: &TraversalPolicy,
        deadline: &Deadline,
    ) -> Result<OwnedFd, AnchoredRemoveError> {
        deadline.check()?;
        let child =
            openat(parent, name, DIRECTORY_OPEN_FLAGS, Mode::empty()).map_err(map_io_error)?;
        let opened_stat = fstat(&child).map_err(map_io_error)?;
        classify_directory(&opened_stat)?;
        enforce_directory_policy(&opened_stat, policy)?;
        compare_observation(identity_from_stat(&opened_stat)?, named_identity)?;
        Ok(child)
    }

    fn enforce_opened_directory_policy(
        directory: &OwnedFd,
        policy: &TraversalPolicy,
    ) -> Result<(), AnchoredRemoveError> {
        let stat = fstat(directory).map_err(map_io_error)?;
        enforce_directory_policy(&stat, policy)
    }

    fn enforce_directory_policy(
        stat: &Stat,
        policy: &TraversalPolicy,
    ) -> Result<(), AnchoredRemoveError> {
        directory_policy_check(policy.effective_uid, stat.st_uid, permission_mode(stat))
    }

    #[cfg(target_os = "linux")]
    fn link_count(stat: &Stat) -> u64 {
        stat.st_nlink
    }

    #[cfg(target_os = "macos")]
    fn link_count(stat: &Stat) -> u64 {
        u64::from(stat.st_nlink)
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

    fn map_manifest_io_error(error: Errno) -> AnchoredRemoveError {
        match error {
            Errno::NOENT | Errno::LOOP | Errno::NOTDIR => AnchoredRemoveError::IdentityMismatch,
            _ => map_io_error(error),
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

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
fn remove_contained_tree_with_pre_delete<F>(
    storage_root: String,
    relative_segments: Vec<String>,
    expected_proof: ContainedTreeProof,
    deadline_ms: u64,
    before_delete: F,
) -> Result<RemoveResult, AnchoredRemoveError>
where
    F: FnOnce(),
{
    platform::remove_contained_tree_with_pre_delete(
        storage_root,
        relative_segments,
        expected_proof,
        deadline_ms,
        before_delete,
    )
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
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

    #[test]
    fn anchored_remove_manifest_does_not_delete_a_new_entry() {
        let root = fixture_root("manifest-new-entry");
        let target = root.join("target");
        fs::create_dir_all(&target).expect("create temp fixture");
        fs::write(target.join("old"), b"old").expect("write old entry");
        let root_string = root.to_str().expect("UTF-8 temp path").to_string();
        let segments = vec!["target".to_string()];
        let proof = present_proof(&root_string, &segments);

        let result = super::remove_contained_tree_with_pre_delete(
            root_string.clone(),
            segments.clone(),
            proof,
            5_000,
            || fs::write(target.join("new"), b"new").expect("insert post-preflight entry"),
        );

        assert!(matches!(result, Err(AnchoredRemoveError::IoError)));
        assert_eq!(
            fs::read(target.join("new")).expect("new entry remains"),
            b"new"
        );
        assert!(matches!(
            super::remove_contained_tree(root_string, segments, proof, 5_000),
            Ok(RemoveResult::Removed(removed)) if removed == proof
        ));
        fs::remove_dir(root).expect("remove fixture root");
    }

    #[test]
    fn anchored_remove_manifest_rejects_a_regular_file_swap() {
        let root = fixture_root("manifest-regular-swap");
        let target = root.join("target");
        let saved = root.join("saved");
        fs::create_dir_all(&target).expect("create temp fixture");
        fs::write(target.join("entry"), b"original").expect("write original entry");
        let root_string = root.to_str().expect("UTF-8 temp path").to_string();
        let segments = vec!["target".to_string()];
        let proof = present_proof(&root_string, &segments);

        let result = super::remove_contained_tree_with_pre_delete(
            root_string.clone(),
            segments.clone(),
            proof,
            5_000,
            || {
                fs::rename(target.join("entry"), &saved).expect("move observed entry");
                fs::write(target.join("entry"), b"replacement").expect("write replacement");
            },
        );

        assert!(matches!(result, Err(AnchoredRemoveError::IdentityMismatch)));
        assert_eq!(
            fs::read(target.join("entry")).expect("replacement remains"),
            b"replacement"
        );
        assert_eq!(fs::read(&saved).expect("original remains"), b"original");
        assert!(matches!(
            super::remove_contained_tree(root_string, segments, proof, 5_000),
            Ok(RemoveResult::Removed(removed)) if removed == proof
        ));
        fs::remove_file(saved).expect("remove saved original");
        fs::remove_dir(root).expect("remove fixture root");
    }

    #[test]
    fn anchored_remove_manifest_rejects_a_directory_swap() {
        let root = fixture_root("manifest-directory-swap");
        let target = root.join("target");
        let child = target.join("child");
        let saved = root.join("saved-child");
        fs::create_dir_all(&child).expect("create observed child");
        fs::write(child.join("original"), b"original").expect("write original child");
        let root_string = root.to_str().expect("UTF-8 temp path").to_string();
        let segments = vec!["target".to_string()];
        let proof = present_proof(&root_string, &segments);

        let result = super::remove_contained_tree_with_pre_delete(
            root_string.clone(),
            segments.clone(),
            proof,
            5_000,
            || {
                fs::rename(&child, &saved).expect("move observed directory");
                fs::create_dir(&child).expect("create replacement directory");
                fs::write(child.join("replacement"), b"replacement")
                    .expect("write replacement child");
            },
        );

        assert!(matches!(result, Err(AnchoredRemoveError::IdentityMismatch)));
        assert_eq!(
            fs::read(child.join("replacement")).expect("replacement remains"),
            b"replacement"
        );
        assert_eq!(
            fs::read(saved.join("original")).expect("original remains"),
            b"original"
        );
        assert!(matches!(
            super::remove_contained_tree(root_string, segments, proof, 5_000),
            Ok(RemoveResult::Removed(removed)) if removed == proof
        ));
        fs::remove_file(saved.join("original")).expect("remove saved child file");
        fs::remove_dir(saved).expect("remove saved child");
        fs::remove_dir(root).expect("remove fixture root");
    }

    #[test]
    fn anchored_remove_manifest_uses_one_global_entry_limit() {
        let root = fixture_root("manifest-global-limit");
        let target = root.join("target");
        fs::create_dir_all(&target).expect("create target");

        for directory_index in 0..2 {
            let directory = target.join(format!("directory-{directory_index}"));
            fs::create_dir(&directory).expect("create directory");
            for file_index in 0..5_000 {
                fs::write(directory.join(file_index.to_string()), b"").expect("write entry");
            }
        }

        let root_string = root.to_str().expect("UTF-8 temp path").to_string();
        let segments = vec!["target".to_string()];
        let proof = present_proof(&root_string, &segments);
        assert!(matches!(
            super::remove_contained_tree(root_string, segments, proof, 30_000),
            Err(AnchoredRemoveError::EntryLimit)
        ));

        for directory_index in 0..2 {
            let directory = target.join(format!("directory-{directory_index}"));
            for file_index in 0..5_000 {
                fs::remove_file(directory.join(file_index.to_string())).expect("remove entry");
            }
            fs::remove_dir(directory).expect("remove directory");
        }
        fs::remove_dir(target).expect("remove target");
        fs::remove_dir(root).expect("remove fixture root");
    }

    #[test]
    fn anchored_remove_unlink_postchecks_require_exact_link_transitions() {
        assert_eq!(super::regular_unlink_postcheck(2, 1), Ok(()));
        assert_eq!(super::regular_unlink_postcheck(1, 0), Ok(()));
        assert_eq!(
            super::regular_unlink_postcheck(2, 2),
            Err(AnchoredRemoveError::IdentityMismatch)
        );
        assert_eq!(
            super::regular_unlink_postcheck(1, 1),
            Err(AnchoredRemoveError::IdentityMismatch)
        );
        assert_eq!(super::directory_unlink_postcheck(0), Ok(()));
        assert_eq!(
            super::directory_unlink_postcheck(1),
            Err(AnchoredRemoveError::IdentityMismatch)
        );
        assert_eq!(super::directory_policy_check(1_000, 1_000, 0o755), Ok(()));
        assert_eq!(
            super::directory_policy_check(1_000, 2_000, 0o755),
            Err(AnchoredRemoveError::PermissionDenied)
        );
        assert_eq!(
            super::directory_policy_check(1_000, 1_000, 0o775),
            Err(AnchoredRemoveError::ModeMismatch)
        );
    }

    fn present_proof(root: &str, segments: &[String]) -> super::ContainedTreeProof {
        match super::contained_tree_identity(root.to_string(), segments.to_vec(), 5_000)
            .expect("observe tree")
        {
            IdentityResult::Present(proof) => proof,
            IdentityResult::Missing(_) => panic!("expected present tree"),
        }
    }
}

#[cfg(all(test, not(any(target_os = "linux", target_os = "macos"))))]
mod unsupported_platform_tests {
    use super::{
        AnchoredRemoveError, ContainedTreeIdentity, ContainedTreeProof, contained_tree_identity,
        remove_contained_tree,
    };

    #[test]
    fn public_fallbacks_compile_and_return_unsupported_without_platform_module() {
        let identity = ContainedTreeIdentity {
            mode: 0o700,
            major_device: 0,
            minor_device: 0,
            inode: 1,
        };
        let proof = ContainedTreeProof {
            root: identity,
            target: identity,
        };

        assert!(matches!(
            contained_tree_identity("/missing".to_string(), vec!["target".to_string()], 1),
            Err(AnchoredRemoveError::UnsupportedPlatform)
        ));
        assert!(matches!(
            remove_contained_tree("/missing".to_string(), vec!["target".to_string()], proof, 1),
            Err(AnchoredRemoveError::UnsupportedPlatform)
        ));
    }
}
