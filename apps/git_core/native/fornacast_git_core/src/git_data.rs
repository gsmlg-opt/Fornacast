//! Bounded Git-data reads and effect-free content plans. Ref publication uses the shared CAS.
use super::*;

type NativeObject<'a> = (String, String, rustler::Binary<'a>);
type NativeContent = (String, String, String, String, u64, String);
type ReadBounds = (usize, usize, u64);
const DATA_OBJECT_BYTES: u64 = 64 * 1024 * 1024;

struct TreeBudget {
    entries: usize,
    bytes: DecodedByteBudget,
}
impl TreeBudget {
    fn new() -> Self {
        Self {
            entries: 0,
            bytes: DecodedByteBudget::new(DATA_OBJECT_BYTES),
        }
    }
}

// Validate declared sizes before gix inflates an object. The isolated ODB also bounds
// intermediate packed delta allocations, including objects not retained in the result.
pub(super) fn preflight_object(
    repo: &gix::Repository,
    oid: gix_hash::ObjectId,
    expected: gix_object::Kind,
    budget: &mut DecodedByteBudget,
    deadline: Instant,
) -> Result<(), NativeError> {
    check_commit_deadline(deadline)?;
    let header = repo.find_header(oid).map_err(diff_read_error)?;
    if header.kind() != expected {
        return Err(native_error(
            "corrupt_repository",
            "object has an unexpected kind",
        ));
    }
    let size = usize::try_from(header.size())
        .map_err(|_| native_error("scan_byte_limit", "object size overflow"))?;
    budget.charge(oid, size, "Git-data decoded object budget exhausted")?;
    check_commit_deadline(deadline)
}

fn data_commit<'r>(
    repo: &'r gix::Repository,
    oid: gix_hash::ObjectId,
    position: CommitPosition,
    deadline: Instant,
) -> Result<gix::Commit<'r>, NativeError> {
    let missing = if matches!(position, CommitPosition::Tip) {
        "commit_not_found"
    } else {
        "corrupt_repository"
    };
    let header = repo
        .try_find_header(oid)
        .map_err(diff_read_error)?
        .ok_or_else(|| native_error(missing, "commit object missing"))?;
    if header.kind() != gix_object::Kind::Commit {
        return Err(native_error(missing, "object is not a commit"));
    }
    preflight_object(
        repo,
        oid,
        gix_object::Kind::Commit,
        &mut DecodedByteBudget::new(DATA_OBJECT_BYTES),
        deadline,
    )?;
    find_graph_commit(repo, oid, position)
}

#[rustler::nif(schedule = "DirtyIo")]
fn init_bare_with_branch(path: String, branch: String) -> Result<String, NativeError> {
    let full = format!("refs/heads/{branch}");
    if !valid_canonical_ref(full.as_bytes(), b"refs/heads/") {
        return Err(native_error("invalid_input", "invalid initial branch"));
    }
    let repo =
        gix::init_bare(Path::new(&path)).map_err(|e| native_error("storage_unavailable", e))?;
    repo.edit_reference(gix_ref::transaction::RefEdit {
        name: "HEAD"
            .try_into()
            .map_err(|e| native_error("invalid_input", e))?,
        deref: false,
        change: gix_ref::transaction::Change::Update {
            log: gix_ref::transaction::LogChange {
                mode: gix_ref::transaction::RefLog::AndReference,
                force_create_reflog: false,
                message: "initialize default branch".into(),
            },
            expected: gix_ref::transaction::PreviousValue::Any,
            new: gix_ref::Target::Symbolic(
                full.try_into()
                    .map_err(|e| native_error("invalid_input", e))?,
            ),
        },
    })
    .map_err(|e| native_error("storage_unavailable", e))?;
    Ok(repo.path().to_string_lossy().into_owned())
}

fn bounds(value: ReadBounds) -> Result<(usize, usize, Instant), NativeError> {
    let (commits, entries, millis) = value;
    if commits == 0
        || commits > 50_000
        || entries == 0
        || entries > 100_000
        || millis == 0
        || millis > 60_000
    {
        return Err(native_error(
            "invalid_input",
            "Git-data bounds exceed their hard ceilings",
        ));
    }
    Ok((
        commits,
        entries,
        Instant::now() + Duration::from_millis(millis),
    ))
}

fn snapshot(
    repo: &gix::Repository,
    value: &str,
    deadline: Instant,
) -> Result<gix_hash::ObjectId, NativeError> {
    check_commit_deadline(deadline)?;
    let oid = if matches!(value.len(), 40 | 64) && value.bytes().all(|b| b.is_ascii_hexdigit()) {
        gix_hash::ObjectId::from_hex(value.as_bytes())
            .map_err(|e| native_error("commit_not_found", e))?
    } else {
        let (kind, name, target) =
            if value.starts_with("refs/heads/") || value.starts_with("refs/tags/") {
                let name = value.as_bytes();
                if !valid_full_ref_name(name) {
                    return Err(native_error("ref_not_found", "invalid reference"));
                }
                (
                    if value.starts_with("refs/tags/") {
                        "tag"
                    } else {
                        "branch"
                    },
                    name.to_vec(),
                    require_direct_ref_target(repo, name)?,
                )
            } else {
                resolve_legacy_ref(repo, value.as_bytes())?
            };
        let resolved = resolve_snapshot_target(repo, target, kind == "tag", &name, deadline)?;
        gix_hash::ObjectId::from_hex(resolved.as_bytes())
            .map_err(|e| native_error("corrupt_repository", e))?
    };
    data_commit(repo, oid, CommitPosition::Tip, deadline)?;
    check_commit_deadline(deadline)?;
    Ok(oid)
}

fn tree_entries(
    repo: &gix::Repository,
    oid: gix_hash::ObjectId,
    visited: &mut TreeBudget,
    limit: usize,
    deadline: Instant,
) -> Result<Vec<gix_object::tree::Entry>, NativeError> {
    preflight_object(
        repo,
        oid,
        gix_object::Kind::Tree,
        &mut visited.bytes,
        deadline,
    )?;
    let tree = load_physical_tree(repo, oid, deadline)?;
    let mut entries = Vec::new();
    let mut previous = None;
    for entry in gix_object::TreeRefIter::from_bytes(&tree.data, tree.id.kind()) {
        check_commit_deadline(deadline)?;
        visited.entries += 1;
        if visited.entries > limit {
            return Err(native_error(
                "tree_entry_limit",
                "Git-data tree budget exhausted",
            ));
        }
        let entry = entry.map_err(|e| native_error("corrupt_repository", e))?;
        validate_tree_entry(&mut previous, entry.filename.as_ref(), entry.mode.value())?;
        entries.push(gix_object::tree::Entry {
            mode: entry.mode,
            filename: entry.filename.to_owned(),
            oid: entry.oid.to_owned(),
        });
    }
    Ok(entries)
}

fn entry_at(
    repo: &gix::Repository,
    root: gix_hash::ObjectId,
    components: &[&[u8]],
    visited: &mut TreeBudget,
    limit: usize,
    deadline: Instant,
) -> Result<Option<gix_object::tree::Entry>, NativeError> {
    let mut tree = root;
    for (index, component) in components.iter().enumerate() {
        let entries = tree_entries(repo, tree, visited, limit, deadline)?;
        let Some(entry) = entries
            .into_iter()
            .find(|entry| entry.filename.as_slice() == *component)
        else {
            return Ok(None);
        };
        if index + 1 == components.len() {
            return Ok(Some(entry));
        }
        if !entry.mode.is_tree() {
            return Err(native_error(
                "path_not_found",
                "path traverses a non-directory",
            ));
        }
        tree = entry.oid;
    }
    Ok(None)
}

#[rustler::nif(schedule = "DirtyIo")]
fn api_commit(
    path: String,
    selector: String,
    limits: ReadBounds,
) -> Result<(NativeCommit, String), NativeError> {
    let (_, _, deadline) = bounds(limits)?;
    let repo = open_bounded_physical_bare_repository(&path, DATA_OBJECT_BYTES)?;
    let oid = snapshot(&repo, &selector, deadline)?;
    let commit = data_commit(&repo, oid, CommitPosition::Tip, deadline)?;
    let tree = commit.tree_id().map_err(diff_read_error)?.to_string();
    Ok((hydrate_commit(&repo, oid, deadline)?, tree))
}

#[rustler::nif(schedule = "DirtyIo")]
fn api_commits(
    path: String,
    selector: String,
    page: usize,
    per_page: usize,
    filter_path: String,
    author: Option<String>,
    since: Option<i64>,
    until: Option<i64>,
    limits: ReadBounds,
) -> Result<(Vec<(NativeCommit, String)>, usize), NativeError> {
    let (commit_limit, entry_limit, deadline) = bounds(limits)?;
    if page == 0 || per_page == 0 || per_page > 100 {
        return Err(native_error("invalid_input", "invalid page"));
    }
    let repo = open_bounded_physical_bare_repository(&path, DATA_OBJECT_BYTES)?;
    let oid = snapshot(&repo, &selector, deadline)?;
    let mut budget = ComparisonCommitBudget::new(commit_limit, 134_217_728);
    let graph = walk_comparison_commit_graph(&repo, &oid.to_string(), deadline, &mut budget)?;
    let components = safe_git_path_components(filter_path.as_bytes())?;
    let mut visited = TreeBudget::new();
    let mut total = 0;
    let mut selected = Vec::new();
    let start = page.saturating_sub(1).saturating_mul(per_page);
    for oid in graph.ordered {
        let tuple = hydrate_commit(&repo, oid, deadline)?;
        if author.as_ref().is_some_and(|email| tuple.3.1 != *email)
            || since.is_some_and(|t| tuple.3.2 < t)
            || until.is_some_and(|t| tuple.3.2 > t)
        {
            continue;
        }
        let commit = data_commit(&repo, oid, CommitPosition::Ancestor, deadline)?;
        let tree = commit.tree_id().map_err(diff_read_error)?.detach();
        if !components.is_empty() {
            let current = entry_at(
                &repo,
                tree,
                &components,
                &mut visited,
                entry_limit,
                deadline,
            )?;
            let mut changed = tuple.5.is_empty() && current.is_some();
            for parent in &tuple.5 {
                let parent = gix_hash::ObjectId::from_hex(parent.as_bytes())
                    .map_err(|e| native_error("corrupt_repository", e))?;
                let parent_tree = data_commit(&repo, parent, CommitPosition::Ancestor, deadline)?
                    .tree_id()
                    .map_err(diff_read_error)?
                    .detach();
                if entry_at(
                    &repo,
                    parent_tree,
                    &components,
                    &mut visited,
                    entry_limit,
                    deadline,
                )? != current
                {
                    changed = true;
                }
            }
            if !changed {
                continue;
            }
        }
        if total >= start && selected.len() < per_page {
            selected.push((tuple, tree.to_string()));
        }
        total += 1;
    }
    check_commit_deadline(deadline)?;
    Ok((selected, total))
}

#[rustler::nif(schedule = "DirtyIo")]
fn api_refs(
    path: String,
    limits: ReadBounds,
) -> Result<Vec<(String, String, String)>, NativeError> {
    let (_, entry_limit, deadline) = bounds(limits)?;
    let repo = open_bounded_physical_bare_repository(&path, DATA_OBJECT_BYTES)?;
    let refs = repo
        .references()
        .map_err(|e| native_error("storage_unavailable", e))?;
    let mut result = Vec::new();
    for (index, entry) in refs
        .all()
        .map_err(|e| native_error("storage_unavailable", e))?
        .enumerate()
    {
        check_commit_deadline(deadline)?;
        if index >= entry_limit {
            return Err(native_error("tree_entry_limit", "ref budget exhausted"));
        }
        let entry = entry.map_err(|e| native_error("corrupt_repository", e))?;
        let name = entry.name().as_bstr().to_string();
        if !name.starts_with("refs/heads/") && !name.starts_with("refs/tags/") {
            continue;
        }
        if let Some(oid) = entry.target().try_id() {
            let kind = repo
                .find_header(oid)
                .map_err(diff_read_error)?
                .kind()
                .to_string();
            result.push((name, oid.to_string(), kind));
        }
    }
    result.sort();
    check_commit_deadline(deadline)?;
    Ok(result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn api_content(
    path: String,
    selector: String,
    content_path: String,
    limits: ReadBounds,
) -> Result<(bool, Vec<NativeContent>), NativeError> {
    let (_, limit, deadline) = bounds(limits)?;
    let repo = open_bounded_physical_bare_repository(&path, DATA_OBJECT_BYTES)?;
    let oid = snapshot(&repo, &selector, deadline)?;
    let root = data_commit(&repo, oid, CommitPosition::Tip, deadline)?
        .tree_id()
        .map_err(diff_read_error)?
        .detach();
    let components = safe_git_path_components(content_path.as_bytes())?;
    let mut visited = TreeBudget::new();
    let selected = if components.is_empty() {
        None
    } else {
        Some(
            entry_at(&repo, root, &components, &mut visited, limit, deadline)?
                .ok_or_else(|| native_error("path_not_found", "content path missing"))?,
        )
    };
    let directory = selected.as_ref().is_none_or(|entry| entry.mode.is_tree());
    let entries = if directory {
        tree_entries(
            &repo,
            selected.as_ref().map_or(root, |entry| entry.oid),
            &mut visited,
            limit,
            deadline,
        )?
    } else {
        vec![selected.expect("file entry")]
    };
    let mut result = Vec::new();
    for entry in entries {
        check_commit_deadline(deadline)?;
        let name = String::from_utf8(entry.filename.to_vec())
            .map_err(|_| native_error("invalid_input", "non-UTF8 content name"))?;
        let entry_path = if directory {
            if content_path.is_empty() {
                name.clone()
            } else {
                format!("{content_path}/{name}")
            }
        } else {
            content_path.clone()
        };
        let kind = match entry.mode.value() {
            0o40000 => "dir",
            0o120000 => "symlink",
            0o160000 => "submodule",
            _ => "file",
        };
        let size = if matches!(kind, "file" | "symlink") {
            repo.find_header(entry.oid).map_err(diff_read_error)?.size()
        } else {
            0
        };
        result.push((
            kind.into(),
            name,
            entry_path,
            entry.oid.to_string(),
            size,
            entry.mode.as_str().into(),
        ));
    }
    check_commit_deadline(deadline)?;
    Ok((directory, result))
}

fn edited_tree(
    repo: &gix::Repository,
    root: Option<gix_hash::ObjectId>,
    components: &[&[u8]],
    replacement: Option<gix_hash::ObjectId>,
    visited: &mut TreeBudget,
    limit: usize,
    deadline: Instant,
) -> Result<Option<gix_hash::ObjectId>, NativeError> {
    check_commit_deadline(deadline)?;
    let mut entries = match root {
        Some(oid) => tree_entries(repo, oid, visited, limit, deadline)?,
        None => Vec::new(),
    };
    let index = entries
        .iter()
        .position(|entry| entry.filename.as_slice() == components[0]);
    let prior = index.map(|index| entries.remove(index));
    let (replacement, mode) = if components.len() > 1 {
        if prior.as_ref().is_some_and(|entry| !entry.mode.is_tree()) {
            return Err(native_error(
                "invalid_input",
                "content path crosses a non-directory",
            ));
        }
        (
            edited_tree(
                repo,
                prior.as_ref().map(|entry| entry.oid),
                &components[1..],
                replacement,
                visited,
                limit,
                deadline,
            )?,
            0o40000,
        )
    } else {
        (
            replacement,
            prior.as_ref().map_or(0o100644, |entry| entry.mode.value()),
        )
    };
    if let Some(oid) = replacement {
        entries.push(gix_object::tree::Entry {
            mode: gix_object::tree::EntryMode::try_from(u32::from(mode))
                .map_err(|_| native_error("invalid_input", "invalid file mode"))?,
            filename: components[0].into(),
            oid,
        });
    }
    entries.sort();
    if entries.is_empty() {
        return Ok(None);
    }
    gix_object::Write::write(repo, &gix_object::Tree { entries })
        .map(Some)
        .map_err(merge_boxed_operation_error)
}

#[rustler::nif(schedule = "DirtyIo")]
fn plan_content<'a>(
    env: rustler::Env<'a>,
    path: String,
    action: String,
    full_ref: String,
    content_path: String,
    expected: Option<String>,
    expected_blob: Option<String>,
    content: rustler::Binary<'a>,
    author: NativeSignature,
    committer: NativeSignature,
    message: rustler::Binary<'a>,
    limits: ReadBounds,
) -> Result<
    (
        Option<String>,
        Option<String>,
        String,
        String,
        Vec<NativeObject<'a>>,
    ),
    NativeError,
> {
    let (_, limit, deadline) = bounds(limits)?;
    if content.len() > 104_857_600
        || message.is_empty()
        || message.len() > 65_536
        || message.contains(&0)
        || !valid_canonical_ref(full_ref.as_bytes(), b"refs/heads/")
    {
        return Err(native_error("invalid_input", "invalid content plan"));
    }
    let components = safe_git_path_components(content_path.as_bytes())?;
    if components.is_empty() || components.len() > 256 {
        return Err(native_error("invalid_input", "invalid content path"));
    }
    let mut repo =
        open_bounded_physical_bare_repository(&path, DATA_OBJECT_BYTES)?.with_object_memory();
    let parent = expected
        .as_ref()
        .map(|oid| snapshot(&repo, oid, deadline))
        .transpose()?;
    let tree = parent
        .map(|oid| {
            data_commit(&repo, oid, CommitPosition::Tip, deadline)
                .and_then(|c| c.tree_id().map(|id| id.detach()).map_err(diff_read_error))
        })
        .transpose()?;
    let mut visited = TreeBudget::new();
    let prior = tree
        .map(|root| entry_at(&repo, root, &components, &mut visited, limit, deadline))
        .transpose()?
        .flatten();
    if prior
        .as_ref()
        .is_some_and(|entry| !matches!(entry.mode.value(), 0o100644 | 0o100755))
    {
        return Err(native_error(
            "invalid_input",
            "content writes require a regular file",
        ));
    }
    let old_blob = prior.as_ref().map(|entry| entry.oid.to_string());
    match action.as_str() {
        "create" if old_blob.is_none() && expected_blob.is_none() => {}
        "update" | "delete" if old_blob.is_some() && expected_blob == old_blob => {}
        _ => {
            return Err(native_error(
                "invalid_input",
                "content SHA precondition failed",
            ));
        }
    }
    let proposed_blob = if action == "delete" {
        None
    } else {
        Some(
            gix_object::compute_hash(repo.object_hash(), gix_object::Kind::Blob, &content)
                .map_err(|e| native_error("invalid_input", e))?,
        )
    };
    let proposed_tree = match edited_tree(
        &repo,
        tree,
        &components,
        proposed_blob,
        &mut visited,
        limit,
        deadline,
    )? {
        Some(tree) => tree,
        None => gix_object::Write::write(
            &repo,
            &gix_object::Tree {
                entries: Vec::new(),
            },
        )
        .map_err(merge_boxed_operation_error)?,
    };
    let object = gix_object::Commit {
        tree: proposed_tree,
        parents: parent.into_iter().collect(),
        author: validated_merge_signature(author)?,
        committer: validated_merge_signature(committer)?,
        encoding: None,
        message: message.as_slice().into(),
        extra_headers: Vec::new(),
    };
    let proposed_commit =
        gix_object::Write::write(&repo, &object).map_err(merge_boxed_operation_error)?;
    let mut objects = Vec::new();
    let planned = take_merge_object_memory(&mut repo)?;
    let planned_bytes = planned
        .iter()
        .try_fold(0usize, |used, (_, (_, bytes))| {
            used.checked_add(bytes.len())
        })
        .ok_or_else(|| native_error("scan_byte_limit", "plan byte overflow"))?;
    if planned_bytes as u64 > DATA_OBJECT_BYTES {
        return Err(native_error("scan_byte_limit", "content plan too large"));
    }
    for (oid, (kind, data)) in planned {
        let mut binary = rustler::OwnedBinary::new(data.len())
            .ok_or_else(|| native_error("storage_unavailable", "cannot allocate content plan"))?;
        binary.as_mut_slice().copy_from_slice(&data);
        objects.push((oid.to_string(), kind.to_string(), binary.release(env)));
    }
    check_commit_deadline(deadline)?;
    Ok((
        old_blob,
        proposed_blob.map(|oid| oid.to_string()),
        proposed_tree.to_string(),
        proposed_commit.to_string(),
        objects,
    ))
}

#[rustler::nif(schedule = "DirtyIo")]
fn write_content_objects(
    path: String,
    objects: Vec<NativeObject<'_>>,
    limits: ReadBounds,
) -> Result<(), NativeError> {
    let (_, _, deadline) = bounds(limits)?;
    // Borrow byte slices for the scoped worker, without moving BEAM terms to another thread.
    let objects = objects
        .iter()
        .map(|(oid, kind, binary)| (oid.as_str(), kind.as_str(), binary.as_slice()))
        .collect::<Vec<_>>();
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .stack_size(MERGE_WORKER_STACK_SIZE)
            .spawn_scoped(scope, || {
                let repo = open_bounded_physical_bare_repository(&path, DATA_OBJECT_BYTES)?;
                let mut verified = Vec::new();
                let mut bytes = 0usize;
                for (oid, kind, data) in &objects {
                    check_commit_deadline(deadline)?;
                    bytes = bytes
                        .checked_add(data.len())
                        .ok_or_else(|| native_error("invalid_input", "object batch overflow"))?;
                    if bytes > 125_829_120 {
                        return Err(native_error("invalid_input", "object batch too large"));
                    }
                    let kind = match *kind {
                        "blob" => gix_object::Kind::Blob,
                        "tree" => gix_object::Kind::Tree,
                        "commit" => gix_object::Kind::Commit,
                        _ => return Err(native_error("invalid_input", "invalid plan object kind")),
                    };
                    let id = gix_hash::ObjectId::from_hex(oid.as_bytes())
                        .map_err(|e| native_error("invalid_input", e))?;
                    if gix_object::compute_hash(repo.object_hash(), kind, data)
                        .map_err(|e| native_error("invalid_input", e))?
                        != id
                    {
                        return Err(native_error(
                            "invalid_input",
                            "plan object checksum mismatch",
                        ));
                    }
                    verified.push((id, kind, data));
                }
                for (id, kind, data) in verified {
                    check_commit_deadline(deadline)?;
                    gix_object::Write::write_buf_with_known_id(&repo, kind, data, id)
                        .map_err(|e| native_error("storage_unavailable", e))?;
                }
                check_commit_deadline(deadline)
            })
            .map_err(|e| native_error("storage_unavailable", e))?
            .join()
            .map_err(|_| native_error("storage_unavailable", "object writer stopped"))?
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn api_blob<'a>(
    env: rustler::Env<'a>,
    path: String,
    oid: String,
    expected_size: u64,
    limits: ReadBounds,
) -> Result<rustler::Binary<'a>, NativeError> {
    let (_, _, deadline) = bounds(limits)?;
    if expected_size > 104_857_600 {
        return Err(native_error(
            "blob_too_large",
            "contents blob exceeds its limit",
        ));
    }
    let repo = open_bounded_physical_bare_repository(&path, DATA_OBJECT_BYTES)?;
    let oid = verified_blob_oid(&oid)?;
    let mut binary = rustler::OwnedBinary::new(expected_size as usize)
        .ok_or_else(|| native_error("storage_unavailable", "cannot allocate contents blob"))?;
    let mut written = 0usize;
    let mut overflow = false;
    let outcome = bounded_blob::visit_verified_blob(
        &repo,
        oid,
        expected_size,
        move || Instant::now() >= deadline,
        &mut |chunk: &[u8]| {
            if chunk.len() > binary.len().saturating_sub(written) {
                overflow = true;
                return;
            }
            binary.as_mut_slice()[written..written + chunk.len()].copy_from_slice(chunk);
            written += chunk.len();
        },
    )
    .map_err(bounded_blob_native_error)?;
    check_commit_deadline(deadline)?;
    match outcome {
        bounded_blob::VisitOutcome::Complete { size }
            if size == expected_size && written as u64 == expected_size && !overflow =>
        {
            Ok(binary.release(env))
        }
        bounded_blob::VisitOutcome::Stopped { .. } => Err(native_error(
            "scan_timeout",
            "contents blob deadline exhausted",
        )),
        _ => Err(native_error(
            "corrupt_repository",
            "contents blob size changed",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::process::{Command, Stdio};

    #[test]
    fn packed_commit_and_tree_sizes_are_rejected_before_materialization() {
        let path = std::env::temp_dir().join(format!(
            "fornacast-data-budget-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let repo = gix::init_bare(&path).unwrap();
        let objects = [gix_object::Kind::Commit, gix_object::Kind::Tree].map(|kind| {
            (
                gix_object::Write::write_buf(&repo, kind, &vec![b'x'; 4096]).unwrap(),
                kind,
            )
        });
        let mut pack = Command::new("git")
            .args([
                "--git-dir",
                path.to_str().unwrap(),
                "pack-objects",
                "--stdout",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        for (oid, _) in objects {
            writeln!(pack.stdin.as_mut().unwrap(), "{oid}").unwrap();
        }
        drop(pack.stdin.take());
        let packed = pack.wait_with_output().unwrap();
        assert!(packed.status.success());
        let mut index = Command::new("git")
            .args(["--git-dir", path.to_str().unwrap(), "index-pack", "--stdin"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        index
            .stdin
            .as_mut()
            .unwrap()
            .write_all(&packed.stdout)
            .unwrap();
        drop(index.stdin.take());
        assert!(index.wait().unwrap().success());
        for (oid, _) in objects {
            let hex = oid.to_string();
            std::fs::remove_file(path.join("objects").join(&hex[..2]).join(&hex[2..])).unwrap();
        }
        let repo = open_bounded_physical_bare_repository(path.to_str().unwrap(), DATA_OBJECT_BYTES)
            .unwrap();
        for (oid, kind) in objects {
            let result = preflight_object(
                &repo,
                oid,
                kind,
                &mut DecodedByteBudget::new(128),
                Instant::now() + Duration::from_secs(1),
            );
            assert_eq!(result.unwrap_err().0, "scan_byte_limit");
        }
        std::fs::remove_dir_all(path).unwrap();
    }
}
