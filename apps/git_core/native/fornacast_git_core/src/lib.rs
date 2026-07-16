use std::collections::{BTreeMap, BTreeSet};
use std::io::{Cursor, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use gix_object::bstr::ByteSlice;

mod bounded_blob;

type NativeCommit = (
    String,
    String,
    String,
    (String, String, i64),
    (String, String, i64),
    Vec<String>,
);

type NativeTreeEntry = (String, String, String, String);
type NativeBlob = (String, String, u64, Vec<u8>, bool, bool);
type NativeDiffFile = (String, String, Option<String>, Option<String>, bool);
type NativeCommitDiff = (Vec<NativeDiffFile>, String, bool);
type NativeRef = (Vec<u8>, String, String);
type NativeRefSummary = (usize, usize, Vec<NativeRef>, Vec<NativeRef>, bool);
type NativeReceiveCommand = (String, String, String);
type NativeReceiveStatus = (String, String, String);
type NativeError = (String, String);

struct PackObject {
    kind: gix_object::Kind,
    data: Vec<u8>,
}

struct ReceiveCommand {
    old: String,
    new: String,
    ref_name: String,
}

#[derive(Clone)]
struct ScannedRef {
    name: Vec<u8>,
    kind: &'static str,
    target: String,
}

struct RefSummaryBuilder {
    branch_count: usize,
    tag_count: usize,
    branches: Vec<ScannedRef>,
    tags: Vec<ScannedRef>,
}

struct RouteMatch {
    reference: ScannedRef,
    selector_full_name: Vec<u8>,
    repository_path: Vec<u8>,
}

enum DirectRefTarget {
    Missing,
    Symbolic,
    Object(gix_hash::ObjectId),
}

const REF_SAMPLE_LIMIT: usize = 100;
const REF_PAGE_LIMIT: usize = 100;
const REF_SCAN_DEADLINE: Duration = Duration::from_secs(5);
// This remains independent of object size while leaving room for the complete mandatory tag
// header, including long ref-derived tag names, before an arbitrarily large message body.
const SNAPSHOT_OBJECT_PREFIX_LIMIT: usize = 64 * 1024;

#[derive(Clone)]
struct FileSnapshot {
    oid: String,
    mode: String,
    data: Option<Vec<u8>>,
}

fn to_error<E: std::fmt::Display>(error: E) -> String {
    error.to_string()
}

fn native_error(kind: &'static str, detail: impl std::fmt::Display) -> NativeError {
    (kind.to_string(), detail.to_string())
}

fn bounded_blob_native_error(error: bounded_blob::Error) -> NativeError {
    let kind = match error.kind() {
        bounded_blob::ErrorKind::StorageUnavailable => "storage_unavailable",
        bounded_blob::ErrorKind::CorruptRepository => "corrupt_repository",
    };
    native_error(kind, error)
}

fn open_repository(path: &str) -> Result<gix::Repository, NativeError> {
    std::fs::metadata(path).map_err(|error| native_error("storage_unavailable", error))?;
    gix::open(Path::new(path)).map_err(open_error)
}

fn open_error(error: gix::open::Error) -> NativeError {
    let kind = match &error {
        gix::open::Error::Io(_) => "storage_unavailable",
        gix::open::Error::Config(gix::config::Error::Io { .. }) => "storage_unavailable",
        _ => "invalid_repository",
    };

    native_error(kind, error)
}

fn open_bare_repository(path: &str) -> Result<gix::Repository, NativeError> {
    let repo = open_repository(path)?;

    if repo.is_bare() {
        Ok(repo)
    } else {
        Err(native_error("invalid_repository", "repository is not bare"))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn init_bare(path: String) -> Result<String, String> {
    let repo = gix::init_bare(Path::new(&path)).map_err(to_error)?;
    Ok(repo.path().to_string_lossy().into_owned())
}

#[rustler::nif(schedule = "DirtyIo")]
fn is_bare_repository(path: String) -> Result<bool, NativeError> {
    open_bare_repository(&path)?;
    Ok(true)
}

#[rustler::nif(schedule = "DirtyIo")]
fn empty(path: String) -> Result<bool, NativeError> {
    let repo = open_bare_repository(&path)?;
    let references = repo
        .references()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let mut refs = references
        .all()
        .map_err(|error| native_error("corrupt_repository", error))?;

    match refs.next() {
        None => Ok(true),
        Some(Ok(_reference)) => Ok(false),
        Some(Err(error)) => Err(native_error("corrupt_repository", error)),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn list_refs(path: String) -> Result<Vec<(String, String, String)>, NativeError> {
    let repo = open_bare_repository(&path)?;
    let references = repo
        .references()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let refs = references
        .all()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let mut result = Vec::new();

    for reference in refs {
        let reference = reference.map_err(|error| native_error("corrupt_repository", error))?;
        let name = reference.name().as_bstr().to_string();

        if let Some(kind) = ref_kind(&name) {
            if let Some(target) = reference.try_id() {
                result.push((name, kind.to_string(), target.to_string()));
            }
        }
    }

    Ok(result)
}

fn ref_kind(name: &str) -> Option<&'static str> {
    if name.starts_with("refs/heads/") {
        Some("branch")
    } else if name.starts_with("refs/tags/") {
        Some("tag")
    } else {
        None
    }
}

fn ref_kind_bytes(name: &[u8]) -> Option<&'static str> {
    if name.starts_with(b"refs/heads/") {
        Some("branch")
    } else if name.starts_with(b"refs/tags/") {
        Some("tag")
    } else {
        None
    }
}

impl ScannedRef {
    fn into_native(self) -> NativeRef {
        (self.name, self.kind.to_string(), self.target)
    }
}

impl RefSummaryBuilder {
    fn new() -> Self {
        Self {
            branch_count: 0,
            tag_count: 0,
            branches: Vec::with_capacity(REF_SAMPLE_LIMIT),
            tags: Vec::with_capacity(REF_SAMPLE_LIMIT),
        }
    }

    fn record(&mut self, reference: &ScannedRef) {
        match reference.kind {
            "branch" => {
                self.branch_count += 1;

                if self.branches.len() < REF_SAMPLE_LIMIT {
                    self.branches.push(reference.clone());
                }
            }
            "tag" => {
                self.tag_count += 1;

                if self.tags.len() < REF_SAMPLE_LIMIT {
                    self.tags.push(reference.clone());
                }
            }
            _ => unreachable!("only branch and tag refs reach the summary builder"),
        }
    }

    fn finish(mut self, selected: Option<ScannedRef>) -> NativeRefSummary {
        if let Some(selected) = selected {
            let sample = match selected.kind {
                "branch" => &mut self.branches,
                "tag" => &mut self.tags,
                _ => unreachable!("only branch and tag refs can be selected"),
            };

            if !sample
                .iter()
                .any(|reference| reference.name == selected.name)
            {
                sample.push(selected);
                sample.sort_by(|left, right| left.name.cmp(&right.name));
            }
        }

        let refs_truncated =
            self.branch_count > REF_SAMPLE_LIMIT || self.tag_count > REF_SAMPLE_LIMIT;

        (
            self.branch_count,
            self.tag_count,
            self.branches
                .into_iter()
                .map(ScannedRef::into_native)
                .collect(),
            self.tags.into_iter().map(ScannedRef::into_native).collect(),
            refs_truncated,
        )
    }
}

fn check_ref_deadline(deadline: Instant) -> Result<(), NativeError> {
    if Instant::now() >= deadline {
        Err(native_error(
            "scan_timeout",
            "reference scan exceeded the five-second deadline",
        ))
    } else {
        Ok(())
    }
}

fn scan_direct_refs(
    path: &str,
    deadline: Instant,
    mut visit: impl FnMut(ScannedRef),
) -> Result<(), NativeError> {
    let repo = open_bare_repository(path)?;
    check_ref_deadline(deadline)?;

    let references = repo
        .references()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let refs = references
        .all()
        .map_err(|error| native_error("corrupt_repository", error))?;

    // gix's loose-then-packed overlay iterator yields refs sorted by full-name bytes. Keeping
    // only a prefix or one requested page is therefore bounded without collecting all refs.
    for reference in refs {
        check_ref_deadline(deadline)?;
        let reference = reference.map_err(|error| native_error("corrupt_repository", error))?;
        let name = reference.name().as_bstr().to_vec();

        if let (Some(kind), Some(target)) = (ref_kind_bytes(&name), reference.try_id()) {
            visit(ScannedRef {
                name,
                kind,
                target: target.to_string(),
            });
        }
    }

    check_ref_deadline(deadline)
}

#[rustler::nif(schedule = "DirtyIo")]
fn ref_summary(
    path: String,
    selected_ref: Option<Vec<u8>>,
) -> Result<NativeRefSummary, NativeError> {
    let deadline = Instant::now() + REF_SCAN_DEADLINE;
    let mut summary = RefSummaryBuilder::new();
    let mut selected = None;

    scan_direct_refs(&path, deadline, |reference| {
        if selected_ref.as_deref() == Some(reference.name.as_slice()) {
            selected = Some(reference.clone());
        }

        summary.record(&reference);
    })?;

    Ok(summary.finish(selected))
}

#[rustler::nif(schedule = "DirtyIo")]
fn ref_page(
    path: String,
    kind: String,
    page: String,
    per_page: usize,
) -> Result<(Vec<NativeRef>, usize), NativeError> {
    if !matches!(kind.as_str(), "branch" | "tag") {
        return Err(native_error("ref_not_found", "invalid reference page"));
    }

    let page = page.parse::<usize>().unwrap_or(usize::MAX);
    if page == 0 {
        return Err(native_error("ref_not_found", "invalid reference page"));
    }

    let per_page = per_page.clamp(1, REF_PAGE_LIMIT);
    let start = page.saturating_sub(1).saturating_mul(per_page);
    let end = start.saturating_add(per_page);
    let mut total = 0usize;
    let mut page_refs = Vec::with_capacity(per_page);
    let deadline = Instant::now() + REF_SCAN_DEADLINE;

    scan_direct_refs(&path, deadline, |reference| {
        if reference.kind == kind {
            if total >= start && total < end {
                page_refs.push(reference.into_native());
            }

            total += 1;
        }
    })?;

    Ok((page_refs, total))
}

#[rustler::nif(schedule = "DirtyIo")]
fn ref_summary_for_route(
    path: String,
    route_segments: Vec<Vec<u8>>,
) -> Result<(NativeRefSummary, String, Vec<u8>, Vec<u8>), NativeError> {
    let deadline = Instant::now() + REF_SCAN_DEADLINE;
    let route_path = join_route_segments(&route_segments);
    check_ref_deadline(deadline)?;
    let declared_kind = declared_route_kind(&route_segments);
    let mut canonical_match = None;
    let mut branch_match = None;
    let mut tag_match = None;
    let mut summary = RefSummaryBuilder::new();

    scan_direct_refs(&path, deadline, |reference| {
        summary.record(&reference);

        match declared_kind {
            Some(kind) if kind == reference.kind => {
                maybe_record_route_match(
                    &mut canonical_match,
                    &route_path,
                    reference.name.clone(),
                    reference,
                );
            }
            Some(_) => {}
            None => {
                let selector_full_name = match reference.kind {
                    "branch" => reference
                        .name
                        .strip_prefix(b"refs/heads/")
                        .expect("branch refs have the branch prefix")
                        .to_vec(),
                    "tag" => reference
                        .name
                        .strip_prefix(b"refs/tags/")
                        .expect("tag refs have the tag prefix")
                        .to_vec(),
                    _ => unreachable!("only branch and tag refs reach route matching"),
                };
                let destination = if reference.kind == "branch" {
                    &mut branch_match
                } else {
                    &mut tag_match
                };

                maybe_record_route_match(destination, &route_path, selector_full_name, reference);
            }
        }
    })?;

    let (selector_kind, matched) = match declared_kind {
        Some(kind) => (kind, canonical_match),
        None => ("legacy", branch_match.or(tag_match)),
    };
    let matched = matched
        .ok_or_else(|| native_error("ref_not_found", "route does not contain an existing ref"))?;

    Ok((
        summary.finish(Some(matched.reference)),
        selector_kind.to_string(),
        matched.selector_full_name,
        matched.repository_path,
    ))
}

fn declared_route_kind(route_segments: &[Vec<u8>]) -> Option<&'static str> {
    match route_segments {
        [refs, declared_kind, ..]
            if refs.as_slice() == b"refs" && declared_kind.as_slice() == b"heads" =>
        {
            Some("branch")
        }
        [refs, declared_kind, ..]
            if refs.as_slice() == b"refs" && declared_kind.as_slice() == b"tags" =>
        {
            Some("tag")
        }
        _ => None,
    }
}

fn join_route_segments(route_segments: &[Vec<u8>]) -> Vec<u8> {
    let byte_count = route_segments.iter().map(Vec::len).sum::<usize>();
    let mut route_path =
        Vec::with_capacity(byte_count.saturating_add(route_segments.len().saturating_sub(1)));

    for (index, segment) in route_segments.iter().enumerate() {
        if index != 0 {
            route_path.push(b'/');
        }
        route_path.extend_from_slice(segment);
    }

    route_path
}

fn maybe_record_route_match(
    matched: &mut Option<RouteMatch>,
    route_path: &[u8],
    selector_full_name: Vec<u8>,
    reference: ScannedRef,
) {
    let repository_path = if route_path == selector_full_name.as_slice() {
        Some(&[][..])
    } else {
        route_path
            .strip_prefix(selector_full_name.as_slice())
            .and_then(|suffix| suffix.strip_prefix(b"/"))
    };

    if let Some(repository_path) = repository_path {
        let replace = matched
            .as_ref()
            .is_none_or(|current| selector_full_name.len() > current.selector_full_name.len());

        if replace {
            *matched = Some(RouteMatch {
                reference,
                selector_full_name,
                repository_path: repository_path.to_vec(),
            });
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn resolve_snapshot(
    path: String,
    selector_kind: String,
    full_name: Vec<u8>,
) -> Result<(String, Vec<u8>, String), NativeError> {
    let deadline = Instant::now() + REF_SCAN_DEADLINE;
    let repo = open_bare_repository(&path)?;
    check_ref_deadline(deadline)?;

    let (resolved_kind, resolved_ref, target) = match selector_kind.as_str() {
        "branch" if valid_canonical_ref(&full_name, b"refs/heads/") => (
            "branch",
            full_name.clone(),
            require_direct_ref_target(&repo, &full_name)?,
        ),
        "tag" if valid_canonical_ref(&full_name, b"refs/tags/") => (
            "tag",
            full_name.clone(),
            require_direct_ref_target(&repo, &full_name)?,
        ),
        "legacy" if !full_name.is_empty() => resolve_legacy_ref(&repo, &full_name)?,
        _ => {
            return Err(native_error(
                "ref_not_found",
                "reference selector is not canonical",
            ));
        }
    };

    let oid = resolve_snapshot_target(
        &repo,
        target,
        resolved_kind == "tag",
        &resolved_ref,
        deadline,
    )?;

    Ok((resolved_kind.to_string(), resolved_ref, oid))
}

fn resolve_legacy_ref(
    repo: &gix::Repository,
    full_name: &[u8],
) -> Result<(&'static str, Vec<u8>, gix_hash::ObjectId), NativeError> {
    let branch_ref = prefixed_ref(b"refs/heads/", full_name);

    if !valid_full_ref_name(&branch_ref) {
        return Err(native_error(
            "ref_not_found",
            "legacy reference selector is malformed",
        ));
    }

    match direct_ref_target(repo, &branch_ref)? {
        DirectRefTarget::Object(target) => return Ok(("branch", branch_ref, target)),
        DirectRefTarget::Symbolic => {
            return Err(native_error(
                "ref_not_found",
                format!(
                    "reference {:?} has no direct object target",
                    display_ref(&branch_ref)
                ),
            ));
        }
        DirectRefTarget::Missing => {}
    }

    let tag_ref = prefixed_ref(b"refs/tags/", full_name);
    let target = require_direct_ref_target(repo, &tag_ref)?;
    Ok(("tag", tag_ref, target))
}

fn valid_canonical_ref(full_name: &[u8], prefix: &[u8]) -> bool {
    full_name
        .strip_prefix(prefix)
        .is_some_and(|short_name| !short_name.is_empty())
        && valid_full_ref_name(full_name)
}

fn valid_full_ref_name(full_name: &[u8]) -> bool {
    <&gix_ref::FullNameRef>::try_from(full_name.as_bstr()).is_ok()
}

fn prefixed_ref(prefix: &[u8], full_name: &[u8]) -> Vec<u8> {
    let mut reference = Vec::with_capacity(prefix.len().saturating_add(full_name.len()));
    reference.extend_from_slice(prefix);
    reference.extend_from_slice(full_name);
    reference
}

fn display_ref(full_name: &[u8]) -> String {
    String::from_utf8_lossy(full_name).into_owned()
}

fn require_direct_ref_target(
    repo: &gix::Repository,
    full_name: &[u8],
) -> Result<gix_hash::ObjectId, NativeError> {
    match direct_ref_target(repo, full_name)? {
        DirectRefTarget::Object(target) => Ok(target),
        DirectRefTarget::Missing => Err(native_error(
            "ref_not_found",
            format!("reference {:?} was not found", display_ref(full_name)),
        )),
        DirectRefTarget::Symbolic => Err(native_error(
            "ref_not_found",
            format!(
                "reference {:?} has no direct object target",
                display_ref(full_name)
            ),
        )),
    }
}

fn direct_ref_target(
    repo: &gix::Repository,
    full_name: &[u8],
) -> Result<DirectRefTarget, NativeError> {
    match repo
        .try_find_reference(full_name.as_bstr())
        .map_err(|error| native_error("corrupt_repository", error))?
    {
        None => Ok(DirectRefTarget::Missing),
        Some(reference) => match reference.try_id() {
            Some(target) => Ok(DirectRefTarget::Object(target.detach())),
            None => Ok(DirectRefTarget::Symbolic),
        },
    }
}

fn resolve_snapshot_target(
    repo: &gix::Repository,
    target: gix_hash::ObjectId,
    peel_tags: bool,
    full_name: &[u8],
    deadline: Instant,
) -> Result<String, NativeError> {
    let mut next = target;
    let mut seen = BTreeSet::new();
    let mut expected_kind = None;

    loop {
        check_ref_deadline(deadline)?;
        let oid = next.to_string();

        if !seen.insert(oid.clone()) {
            return Err(native_error(
                "ref_not_found",
                format!(
                    "reference {:?} contains a tag cycle",
                    display_ref(full_name)
                ),
            ));
        }

        let prefix = bounded_blob::read_object_prefix(repo, next, SNAPSHOT_OBJECT_PREFIX_LIMIT)
            .map_err(bounded_blob_native_error)?;
        check_ref_deadline(deadline)?;

        if expected_kind.is_some_and(|expected_kind| prefix.kind != expected_kind) {
            return Err(native_error(
                "corrupt_repository",
                format!(
                    "tag target {oid} declares {}, found {}",
                    expected_kind.expect("checked above"),
                    prefix.kind
                ),
            ));
        }

        match prefix.kind {
            gix_object::Kind::Commit => return Ok(oid),
            gix_object::Kind::Tag if peel_tags => {
                let (target, target_kind) = tag_target_from_prefix(&prefix.data, next.kind())?;
                next = target;
                expected_kind = Some(target_kind);
            }
            gix_object::Kind::Tag | gix_object::Kind::Tree | gix_object::Kind::Blob => {
                return Err(native_error(
                    "ref_not_found",
                    format!(
                        "reference {:?} does not resolve directly to a commit",
                        display_ref(full_name)
                    ),
                ));
            }
        }
    }
}

fn tag_target_from_prefix(
    data: &[u8],
    hash_kind: gix_hash::Kind,
) -> Result<(gix_hash::ObjectId, gix_object::Kind), NativeError> {
    use gix_object::tag::ref_iter::Token;

    let mut tokens = gix_object::TagRefIter::from_bytes(data, hash_kind);
    let target = match tokens.next() {
        Some(Ok(Token::Target { id })) => id,
        Some(Ok(_)) | None => {
            return Err(native_error(
                "corrupt_repository",
                "annotated tag is missing its target",
            ));
        }
        Some(Err(error)) => return Err(native_error("corrupt_repository", error)),
    };
    let target_kind = match tokens.next() {
        Some(Ok(Token::TargetKind(kind))) => kind,
        Some(Ok(_)) | None => {
            return Err(native_error(
                "corrupt_repository",
                "annotated tag is missing its target kind",
            ));
        }
        Some(Err(error)) => return Err(native_error("corrupt_repository", error)),
    };
    match tokens.next() {
        Some(Ok(Token::Name(_))) => {}
        Some(Ok(_)) | None => {
            return Err(native_error(
                "corrupt_repository",
                "annotated tag is missing its tag name",
            ));
        }
        Some(Err(error)) => return Err(native_error("corrupt_repository", error)),
    }

    Ok((target, target_kind))
}

#[rustler::nif(schedule = "DirtyIo")]
fn commit_history(
    path: String,
    rev: String,
    limit: usize,
) -> Result<Vec<NativeCommit>, NativeError> {
    let repo = open_bare_repository(&path)?;
    let tip = resolve_ref_commit(&repo, &rev)?;
    let limit = limit.clamp(1, 200);
    let mut commits = Vec::new();
    let walk = repo
        .rev_walk([tip.id().detach()])
        .all()
        .map_err(|error| native_error("corrupt_repository", error))?;

    for info in walk.take(limit) {
        let commit = info
            .map_err(|error| native_error("corrupt_repository", error))?
            .object()
            .map_err(|error| native_error("corrupt_repository", error))?;
        commits.push(commit_to_tuple(&commit)?);
    }

    Ok(commits)
}

#[rustler::nif(schedule = "DirtyIo")]
fn commit(path: String, oid: String) -> Result<NativeCommit, NativeError> {
    let repo = open_bare_repository(&path)?;
    let commit = resolve_commit_oid(&repo, &oid)?;
    commit_to_tuple(&commit)
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_tree(
    path: String,
    rev: String,
    tree_path: String,
) -> Result<Vec<NativeTreeEntry>, NativeError> {
    let repo = open_bare_repository(&path)?;
    let relative_path = safe_relative_path(&tree_path)?;
    let root = resolve_ref_commit(&repo, &rev)?
        .tree()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let tree = tree_at_path(root, &relative_path)?;
    let mut entries = Vec::new();

    for entry in tree.iter() {
        let entry = entry.map_err(|error| native_error("corrupt_repository", error))?;
        entries.push((
            entry.filename().to_string(),
            entry_kind(entry.kind()).to_string(),
            entry.mode().as_str().to_string(),
            entry.object_id().to_string(),
        ));
    }

    entries.sort_by(|left, right| {
        let left_is_tree = left.1 == "tree";
        let right_is_tree = right.1 == "tree";
        right_is_tree
            .cmp(&left_is_tree)
            .then_with(|| left.0.cmp(&right.0))
    });

    Ok(entries)
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_blob(
    path: String,
    rev: String,
    blob_path: String,
    limit: usize,
) -> Result<NativeBlob, NativeError> {
    let repo = open_bare_repository(&path)?;
    let relative_path = safe_relative_path(&blob_path)?;

    if relative_path.as_os_str().is_empty() {
        return Err(native_error(
            "path_not_found",
            "path does not point to a blob",
        ));
    }

    let root = resolve_ref_commit(&repo, &rev)?
        .tree()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let entry = root
        .lookup_entry_by_path(&relative_path)
        .map_err(|error| native_error("corrupt_repository", error))?
        .ok_or_else(|| native_error("path_not_found", "path not found"))?;

    if !entry.mode().is_blob_or_symlink() {
        return Err(native_error(
            "path_not_found",
            "path does not point to a blob",
        ));
    }

    let read_limit = limit.clamp(1, 100_000_000);
    let oid = entry.object_id();
    let prefix =
        bounded_blob::read_prefix(&repo, oid, read_limit).map_err(bounded_blob_native_error)?;
    let size = prefix.size;
    let truncated = prefix.truncated;
    let data = prefix.data;
    let binary = data.contains(&0);
    let name = relative_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_string();

    Ok((name, oid.to_string(), size, data, truncated, binary))
}

#[rustler::nif(schedule = "DirtyIo")]
fn diff_commit(path: String, oid: String, limit: usize) -> Result<NativeCommitDiff, NativeError> {
    let repo = open_bare_repository(&path)?;
    let commit = resolve_commit_oid(&repo, &oid)?;
    let diff_limit = limit.clamp(1, 5_000_000);
    let mut old_entries = BTreeMap::new();
    let mut new_entries = BTreeMap::new();

    if let Some(parent_id) = commit.parent_ids().next() {
        let parent = parent_id
            .object()
            .map_err(|error| native_error("corrupt_repository", error))?
            .peel_to_commit()
            .map_err(|error| native_error("corrupt_repository", error))?;
        collect_tree_entries(
            parent
                .tree()
                .map_err(|error| native_error("corrupt_repository", error))?,
            "",
            &mut old_entries,
        )?;
    }

    collect_tree_entries(
        commit
            .tree()
            .map_err(|error| native_error("corrupt_repository", error))?,
        "",
        &mut new_entries,
    )?;

    let paths: BTreeSet<String> = old_entries
        .keys()
        .chain(new_entries.keys())
        .cloned()
        .collect();
    let mut files = Vec::new();
    let mut patch = String::new();
    let mut truncated = false;

    for path in paths {
        let old = old_entries.get(&path);
        let new = new_entries.get(&path);

        if old.map(|entry| &entry.oid) == new.map(|entry| &entry.oid) {
            continue;
        }

        let status = match (old, new) {
            (None, Some(_)) => "added",
            (Some(_), None) => "deleted",
            (Some(_), Some(_)) => "modified",
            (None, None) => continue,
        };
        let binary = snapshot_is_binary(old) || snapshot_is_binary(new);

        files.push((
            path.clone(),
            status.to_string(),
            old.map(|entry| entry.oid.clone()),
            new.map(|entry| entry.oid.clone()),
            binary,
        ));

        append_file_patch(
            &mut patch,
            &mut truncated,
            diff_limit,
            &path,
            status,
            old,
            new,
            binary,
        );
    }

    Ok((files, patch, truncated))
}

#[rustler::nif(schedule = "DirtyIo")]
fn pack_objects<'env>(
    env: rustler::Env<'env>,
    path: String,
    wants: Vec<String>,
) -> Result<rustler::Binary<'env>, String> {
    let repo = gix::open(Path::new(&path)).map_err(to_error)?;
    let mut queue = Vec::new();

    for oid in wants {
        queue.push(parse_object_id(&oid)?);
    }

    let objects = collect_reachable_objects(&repo, queue)?;
    let pack = encode_pack(objects)?;
    let mut binary = rustler::OwnedBinary::new(pack.len())
        .ok_or_else(|| "failed to allocate pack binary".to_string())?;

    binary.as_mut_slice().copy_from_slice(&pack);
    Ok(binary.release(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn receive_pack(
    path: String,
    pack: rustler::Binary<'_>,
    commands: Vec<NativeReceiveCommand>,
) -> Result<Vec<NativeReceiveStatus>, String> {
    let commands = parse_receive_commands(commands)?;
    let keep_path = ingest_received_pack(&path, pack.as_slice())?;
    let repo = gix::open(Path::new(&path)).map_err(to_error)?;
    let validation = validate_receive_commands(&repo, &commands);

    match validation {
        Ok(edits) => {
            if !edits.is_empty() {
                if let Err(error) = repo.edit_references(edits) {
                    let _ = remove_keep_file(keep_path);
                    return Err(to_error(error));
                }
            }

            remove_keep_file(keep_path)?;
            Ok(commands
                .iter()
                .map(|command| (command.ref_name.clone(), "ok".to_string(), String::new()))
                .collect())
        }
        Err(statuses) => {
            remove_keep_file(keep_path)?;
            Ok(statuses)
        }
    }
}

fn parse_receive_commands(
    commands: Vec<NativeReceiveCommand>,
) -> Result<Vec<ReceiveCommand>, String> {
    commands
        .into_iter()
        .map(|(old, new, ref_name)| {
            if !valid_receive_oid(&old) || !valid_receive_oid(&new) {
                return Err("invalid object id".to_string());
            }

            if ref_name.contains('\0') || ref_name.contains('\n') {
                return Err("invalid reference name".to_string());
            }

            Ok(ReceiveCommand {
                old: old.to_ascii_lowercase(),
                new: new.to_ascii_lowercase(),
                ref_name,
            })
        })
        .collect()
}

fn valid_receive_oid(oid: &str) -> bool {
    oid.len() == 40 && oid.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn ingest_received_pack(path: &str, pack: &[u8]) -> Result<Option<PathBuf>, String> {
    if pack.is_empty() {
        return Ok(None);
    }

    let repo = gix::open(Path::new(path)).map_err(to_error)?;
    let pack_dir = repo.objects.store_ref().path().join("pack");
    std::fs::create_dir_all(&pack_dir).map_err(to_error)?;

    let mut reader = Cursor::new(pack);
    let mut progress = gix_features::progress::Discard;
    let should_interrupt = AtomicBool::new(false);
    let options = gix_pack::bundle::write::Options {
        thread_limit: Some(1),
        iteration_mode: gix_pack::data::input::Mode::Verify,
        index_version: Default::default(),
        object_hash: repo.object_hash(),
    };
    let thin_pack_lookup = Box::new({
        let repo = repo.clone();
        repo.objects
    });

    let outcome = gix_pack::Bundle::write_to_directory(
        &mut reader,
        Some(&pack_dir),
        &mut progress,
        &should_interrupt,
        Some(thin_pack_lookup),
        options,
    )
    .map_err(to_error)?;

    Ok(outcome.keep_path)
}

fn remove_keep_file(path: Option<PathBuf>) -> Result<(), String> {
    if let Some(path) = path {
        match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(to_error(error)),
        }
    } else {
        Ok(())
    }
}

fn validate_receive_commands(
    repo: &gix::Repository,
    commands: &[ReceiveCommand],
) -> Result<Vec<gix_ref::transaction::RefEdit>, Vec<NativeReceiveStatus>> {
    let mut seen = BTreeSet::new();
    let mut plans = Vec::new();
    let mut errors = Vec::new();

    for command in commands {
        let result = if !seen.insert(command.ref_name.clone()) {
            Err("multiple updates for the same reference are not supported".to_string())
        } else {
            validate_receive_command(repo, command)
        };

        match result {
            Ok(edit) => {
                plans.push(edit);
                errors.push(None);
            }
            Err(message) => {
                errors.push(Some(message));
            }
        }
    }

    if errors.iter().any(Option::is_some) {
        Err(commands
            .iter()
            .zip(errors)
            .map(|(command, error)| {
                (
                    command.ref_name.clone(),
                    "ng".to_string(),
                    error.unwrap_or_else(|| "atomic push rejected".to_string()),
                )
            })
            .collect())
    } else {
        Ok(plans)
    }
}

fn validate_receive_command(
    repo: &gix::Repository,
    command: &ReceiveCommand,
) -> Result<gix_ref::transaction::RefEdit, String> {
    if is_zero_oid(&command.new) {
        return Err("deletions are not supported in this Fornacast release".to_string());
    }

    if command.ref_name.starts_with("refs/heads/") {
        branch_update(repo, command)
    } else if command.ref_name.starts_with("refs/tags/") {
        tag_update(repo, command)
    } else {
        Err("only branch and tag refs are supported".to_string())
    }
}

fn branch_update(
    repo: &gix::Repository,
    command: &ReceiveCommand,
) -> Result<gix_ref::transaction::RefEdit, String> {
    let new_id = parse_object_id(&command.new)?;
    repo.find_commit(new_id)
        .map_err(|_| "branch target must be a commit".to_string())?;

    let expected = if is_zero_oid(&command.old) {
        if current_ref_target(repo, &command.ref_name)?.is_some() {
            return Err("reference already exists".to_string());
        }

        gix_ref::transaction::PreviousValue::MustNotExist
    } else {
        let old_id = parse_object_id(&command.old)?;

        match current_ref_target(repo, &command.ref_name)? {
            Some(actual) if actual == old_id => {}
            Some(_) => return Err("stale reference update".to_string()),
            None => return Err("reference does not exist".to_string()),
        }

        repo.find_commit(old_id)
            .map_err(|_| "existing branch target must be a commit".to_string())?;

        if !is_ancestor(repo, old_id, new_id)? {
            return Err("non-fast-forward updates are not supported".to_string());
        }

        gix_ref::transaction::PreviousValue::MustExistAndMatch(gix_ref::Target::Object(old_id))
    };

    update_ref_edit(command, new_id, expected)
}

fn tag_update(
    repo: &gix::Repository,
    command: &ReceiveCommand,
) -> Result<gix_ref::transaction::RefEdit, String> {
    if !is_zero_oid(&command.old) {
        return Err("tag updates are not supported in this Fornacast release".to_string());
    }

    if current_ref_target(repo, &command.ref_name)?.is_some() {
        return Err("reference already exists".to_string());
    }

    let new_id = parse_object_id(&command.new)?;
    repo.find_object(new_id)
        .map_err(|_| "tag target object is missing".to_string())?;

    update_ref_edit(
        command,
        new_id,
        gix_ref::transaction::PreviousValue::MustNotExist,
    )
}

fn update_ref_edit(
    command: &ReceiveCommand,
    new_id: gix_hash::ObjectId,
    expected: gix_ref::transaction::PreviousValue,
) -> Result<gix_ref::transaction::RefEdit, String> {
    Ok(gix_ref::transaction::RefEdit {
        change: gix_ref::transaction::Change::Update {
            log: gix_ref::transaction::LogChange {
                mode: gix_ref::transaction::RefLog::AndReference,
                force_create_reflog: false,
                message: format!("push: {}", command.ref_name).into(),
            },
            expected,
            new: gix_ref::Target::Object(new_id),
        },
        name: command.ref_name.clone().try_into().map_err(to_error)?,
        deref: false,
    })
}

fn current_ref_target(
    repo: &gix::Repository,
    ref_name: &str,
) -> Result<Option<gix_hash::ObjectId>, String> {
    match repo.try_find_reference(ref_name).map_err(to_error)? {
        Some(reference) => Ok(reference.try_id().map(|id| id.detach())),
        None => Ok(None),
    }
}

fn is_ancestor(
    repo: &gix::Repository,
    ancestor: gix_hash::ObjectId,
    tip: gix_hash::ObjectId,
) -> Result<bool, String> {
    if ancestor == tip {
        return Ok(true);
    }

    let walk = repo.rev_walk([tip]).all().map_err(to_error)?;

    for info in walk {
        if info.map_err(to_error)?.id == ancestor {
            return Ok(true);
        }
    }

    Ok(false)
}

fn is_zero_oid(oid: &str) -> bool {
    oid.bytes().all(|byte| byte == b'0')
}

fn collect_reachable_objects(
    repo: &gix::Repository,
    mut queue: Vec<gix_hash::ObjectId>,
) -> Result<Vec<PackObject>, String> {
    let mut seen = BTreeSet::new();
    let mut objects = Vec::new();

    while let Some(id) = queue.pop() {
        if !seen.insert(id) {
            continue;
        }

        let object = repo.find_object(id).map_err(to_error)?;
        let kind = object.kind;
        let data = object.data.clone();

        enqueue_children(kind, id, &data, &mut queue)?;
        objects.push(PackObject { kind, data });
    }

    Ok(objects)
}

fn enqueue_children(
    kind: gix_object::Kind,
    id: gix_hash::ObjectId,
    data: &[u8],
    queue: &mut Vec<gix_hash::ObjectId>,
) -> Result<(), String> {
    match kind {
        gix_object::Kind::Commit => {
            let mut commit = gix_object::CommitRefIter::from_bytes(data, id.kind());
            queue.push(commit.tree_id().map_err(to_error)?);

            queue.extend(gix_object::CommitRefIter::from_bytes(data, id.kind()).parent_ids());
        }
        gix_object::Kind::Tree => {
            for entry in gix_object::TreeRefIter::from_bytes(data, id.kind()) {
                let entry = entry.map_err(to_error)?;

                match entry.mode.kind() {
                    gix_object::tree::EntryKind::Tree
                    | gix_object::tree::EntryKind::Blob
                    | gix_object::tree::EntryKind::BlobExecutable
                    | gix_object::tree::EntryKind::Link => queue.push(entry.oid.to_owned()),
                    gix_object::tree::EntryKind::Commit => {}
                }
            }
        }
        gix_object::Kind::Tag => {
            let target_id = gix_object::TagRefIter::from_bytes(data, id.kind())
                .target_id()
                .map_err(to_error)?;
            queue.push(target_id);
        }
        gix_object::Kind::Blob => {}
    }

    Ok(())
}

fn encode_pack(objects: Vec<PackObject>) -> Result<Vec<u8>, String> {
    let count =
        u32::try_from(objects.len()).map_err(|_| "too many objects for pack".to_string())?;
    let mut pack = Vec::new();

    pack.extend_from_slice(b"PACK");
    pack.extend_from_slice(&2u32.to_be_bytes());
    pack.extend_from_slice(&count.to_be_bytes());

    for object in objects {
        write_pack_object_header(
            &mut pack,
            object_type_id(object.kind)?,
            object.data.len() as u64,
        );
        pack.extend(compress_pack_object(&object.data)?);
    }

    let mut hasher = gix_hash::hasher(gix_hash::Kind::Sha1);
    hasher.update(&pack);
    let digest = hasher.try_finalize().map_err(to_error)?;
    pack.extend_from_slice(digest.as_slice());

    Ok(pack)
}

fn write_pack_object_header(pack: &mut Vec<u8>, type_id: u8, mut size: u64) {
    let mut first = ((type_id & 0b111) << 4) | ((size as u8) & 0b1111);
    size >>= 4;

    if size != 0 {
        first |= 0b1000_0000;
    }

    pack.push(first);

    while size != 0 {
        let mut byte = (size as u8) & 0b0111_1111;
        size >>= 7;

        if size != 0 {
            byte |= 0b1000_0000;
        }

        pack.push(byte);
    }
}

fn object_type_id(kind: gix_object::Kind) -> Result<u8, String> {
    match kind {
        gix_object::Kind::Commit => Ok(1),
        gix_object::Kind::Tree => Ok(2),
        gix_object::Kind::Blob => Ok(3),
        gix_object::Kind::Tag => Ok(4),
    }
}

fn compress_pack_object(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut output = gix_features::zlib::stream::deflate::Write::new(Vec::new());
    std::io::copy(&mut &*data, &mut output).map_err(to_error)?;
    output.flush().map_err(to_error)?;
    Ok(output.into_inner())
}

fn parse_object_id(oid: &str) -> Result<gix_hash::ObjectId, String> {
    if oid.len() != 40 || !oid.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("invalid object id".to_string());
    }

    gix_hash::ObjectId::from_hex(oid.as_bytes()).map_err(to_error)
}

fn resolve_commit_oid<'repo>(
    repo: &'repo gix::Repository,
    oid: &str,
) -> Result<gix::Commit<'repo>, NativeError> {
    let oid = gix_hash::ObjectId::from_hex(oid.as_bytes())
        .map_err(|error| native_error("commit_not_found", error))?;
    let object = match repo.find_object(oid) {
        Ok(object) => object,
        Err(error @ gix_object::find::existing::Error::NotFound { .. }) => {
            return Err(native_error("commit_not_found", error));
        }
        Err(error @ gix_object::find::existing::Error::Find(_)) => {
            return Err(native_error("corrupt_repository", error));
        }
    };

    object
        .try_into_commit()
        .map_err(|error| native_error("commit_not_found", error))
}

fn resolve_ref_commit<'repo>(
    repo: &'repo gix::Repository,
    rev: &str,
) -> Result<gix::Commit<'repo>, NativeError> {
    let resolved = repo
        .rev_parse_single(rev)
        .map_err(|error| native_error("ref_not_found", error))?;
    let mut object = resolved.object().map_err(|error| match error {
        error @ gix_object::find::existing::Error::NotFound { .. } => {
            native_error("corrupt_repository", error)
        }
        error @ gix_object::find::existing::Error::Find(_) => {
            native_error("corrupt_repository", error)
        }
    })?;

    loop {
        match object.kind {
            gix_object::Kind::Commit => return Ok(object.into_commit()),
            gix_object::Kind::Tag => {
                let target = object
                    .to_tag_ref_iter()
                    .target_id()
                    .map_err(|error| native_error("corrupt_repository", error))?;
                object = repo
                    .find_object(target)
                    .map_err(|error| native_error("corrupt_repository", error))?;
            }
            gix_object::Kind::Tree | gix_object::Kind::Blob => {
                return Err(native_error(
                    "ref_not_found",
                    format!("reference {rev:?} does not resolve to a commit"),
                ));
            }
        }
    }
}

fn tree_at_path<'repo>(
    root: gix::Tree<'repo>,
    relative_path: &Path,
) -> Result<gix::Tree<'repo>, NativeError> {
    if relative_path.as_os_str().is_empty() {
        return Ok(root);
    }

    let entry = root
        .lookup_entry_by_path(relative_path)
        .map_err(|error| native_error("corrupt_repository", error))?
        .ok_or_else(|| native_error("path_not_found", "path not found"))?;

    if !entry.mode().is_tree() {
        return Err(native_error(
            "path_not_found",
            "path does not point to a tree",
        ));
    }

    entry
        .object()
        .map_err(|error| native_error("corrupt_repository", error))?
        .try_into_tree()
        .map_err(|error| native_error("corrupt_repository", error))
}

fn collect_tree_entries(
    tree: gix::Tree<'_>,
    prefix: &str,
    entries: &mut BTreeMap<String, FileSnapshot>,
) -> Result<(), NativeError> {
    for entry in tree.iter() {
        let entry = entry.map_err(|error| native_error("corrupt_repository", error))?;
        let filename = entry.filename().to_string();
        let path = if prefix.is_empty() {
            filename
        } else {
            format!("{prefix}/{filename}")
        };

        match entry.kind() {
            gix::object::tree::EntryKind::Tree => {
                let child = entry
                    .object()
                    .map_err(|error| native_error("corrupt_repository", error))?
                    .try_into_tree()
                    .map_err(|error| native_error("corrupt_repository", error))?;
                collect_tree_entries(child, &path, entries)?;
            }
            gix::object::tree::EntryKind::Blob
            | gix::object::tree::EntryKind::BlobExecutable
            | gix::object::tree::EntryKind::Link => {
                let blob = entry
                    .object()
                    .map_err(|error| native_error("corrupt_repository", error))?
                    .try_into_blob()
                    .map_err(|error| native_error("corrupt_repository", error))?;

                entries.insert(
                    path,
                    FileSnapshot {
                        oid: entry.object_id().to_string(),
                        mode: format!("{:06o}", entry.mode().value()),
                        data: Some(blob.data.clone()),
                    },
                );
            }
            gix::object::tree::EntryKind::Commit => {
                entries.insert(
                    path,
                    FileSnapshot {
                        oid: entry.object_id().to_string(),
                        mode: format!("{:06o}", entry.mode().value()),
                        data: None,
                    },
                );
            }
        }
    }

    Ok(())
}

fn append_file_patch(
    patch: &mut String,
    truncated: &mut bool,
    limit: usize,
    path: &str,
    status: &str,
    old: Option<&FileSnapshot>,
    new: Option<&FileSnapshot>,
    binary: bool,
) {
    let old_path = if status == "added" {
        "/dev/null".to_string()
    } else {
        format!("a/{path}")
    };
    let new_path = if status == "deleted" {
        "/dev/null".to_string()
    } else {
        format!("b/{path}")
    };

    push_line_limited(
        patch,
        truncated,
        limit,
        &format!("diff --git a/{path} b/{path}"),
    );

    match (status, old, new) {
        ("added", _, Some(new)) => {
            push_line_limited(
                patch,
                truncated,
                limit,
                &format!("new file mode {}", new.mode),
            );
        }
        ("deleted", Some(old), _) => {
            push_line_limited(
                patch,
                truncated,
                limit,
                &format!("deleted file mode {}", old.mode),
            );
        }
        ("modified", Some(old), Some(new)) if old.mode != new.mode => {
            push_line_limited(patch, truncated, limit, &format!("old mode {}", old.mode));
            push_line_limited(patch, truncated, limit, &format!("new mode {}", new.mode));
        }
        _ => {}
    }

    if binary {
        push_line_limited(
            patch,
            truncated,
            limit,
            &format!("Binary files {old_path} and {new_path} differ"),
        );
        push_line_limited(patch, truncated, limit, "");
        return;
    }

    let old_text = snapshot_text(old).unwrap_or_default();
    let new_text = snapshot_text(new).unwrap_or_default();
    let old_lines: Vec<&str> = old_text.lines().collect();
    let new_lines: Vec<&str> = new_text.lines().collect();
    let old_start = if old_lines.is_empty() { 0 } else { 1 };
    let new_start = if new_lines.is_empty() { 0 } else { 1 };

    push_line_limited(patch, truncated, limit, &format!("--- {old_path}"));
    push_line_limited(patch, truncated, limit, &format!("+++ {new_path}"));
    push_line_limited(
        patch,
        truncated,
        limit,
        &format!(
            "@@ -{},{} +{},{} @@",
            old_start,
            old_lines.len(),
            new_start,
            new_lines.len()
        ),
    );

    for line in old_lines {
        push_line_limited(patch, truncated, limit, &format!("-{line}"));
    }

    for line in new_lines {
        push_line_limited(patch, truncated, limit, &format!("+{line}"));
    }

    push_line_limited(patch, truncated, limit, "");
}

fn snapshot_is_binary(snapshot: Option<&FileSnapshot>) -> bool {
    match snapshot.and_then(|entry| entry.data.as_ref()) {
        Some(data) => data.contains(&0) || std::str::from_utf8(data).is_err(),
        None => snapshot.is_some(),
    }
}

fn snapshot_text(snapshot: Option<&FileSnapshot>) -> Option<&str> {
    snapshot
        .and_then(|entry| entry.data.as_ref())
        .and_then(|data| std::str::from_utf8(data).ok())
}

fn push_line_limited(output: &mut String, truncated: &mut bool, limit: usize, line: &str) {
    push_limited(output, truncated, limit, line);
    push_limited(output, truncated, limit, "\n");
}

fn push_limited(output: &mut String, truncated: &mut bool, limit: usize, text: &str) {
    if *truncated {
        return;
    }

    if output.len() + text.len() <= limit {
        output.push_str(text);
        return;
    }

    let remaining = limit.saturating_sub(output.len());

    if remaining > 0 {
        let mut end = remaining.min(text.len());

        while end > 0 && !text.is_char_boundary(end) {
            end -= 1;
        }

        output.push_str(&text[..end]);
    }

    *truncated = true;
}

fn safe_relative_path(path: &str) -> Result<PathBuf, NativeError> {
    let path = path.trim_matches('/');
    let relative_path = PathBuf::from(path);

    if relative_path.is_absolute() {
        return Err(native_error("path_not_found", "path must be relative"));
    }

    for component in relative_path.components() {
        match component {
            Component::Normal(_) => {}
            Component::CurDir if path.is_empty() => {}
            _ => {
                return Err(native_error(
                    "path_not_found",
                    "path contains unsafe segments",
                ));
            }
        }
    }

    Ok(relative_path)
}

fn commit_to_tuple(commit: &gix::Commit<'_>) -> Result<NativeCommit, NativeError> {
    let author = commit
        .author()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let committer = commit
        .committer()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let author_time = author
        .time()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let committer_time = committer
        .time()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let message = commit
        .message_raw()
        .map_err(|error| native_error("corrupt_repository", error))?
        .to_string();
    let title = message.lines().next().unwrap_or_default().to_string();
    let parents = commit.parent_ids().map(|id| id.to_string()).collect();

    Ok((
        commit.id().to_string(),
        title,
        message,
        (
            author.name.to_string(),
            author.email.to_string(),
            author_time.seconds,
        ),
        (
            committer.name.to_string(),
            committer.email.to_string(),
            committer_time.seconds,
        ),
        parents,
    ))
}

fn entry_kind(kind: gix::object::tree::EntryKind) -> &'static str {
    match kind {
        gix::object::tree::EntryKind::Tree => "tree",
        gix::object::tree::EntryKind::Blob => "blob",
        gix::object::tree::EntryKind::BlobExecutable => "blob",
        gix::object::tree::EntryKind::Link => "blob",
        gix::object::tree::EntryKind::Commit => "commit",
    }
}

rustler::init!("Elixir.GitCore.Native");
