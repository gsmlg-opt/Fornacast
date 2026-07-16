use std::collections::{BTreeMap, BTreeSet};
use std::io::{Cursor, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::AtomicBool;

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

    let blob = entry
        .object()
        .map_err(|error| native_error("corrupt_repository", error))?
        .try_into_blob()
        .map_err(|error| native_error("corrupt_repository", error))?;
    let size = blob.data.len() as u64;
    let read_limit = limit.clamp(1, 100_000_000);
    let truncated = blob.data.len() > read_limit;
    let data = blob.data[..std::cmp::min(blob.data.len(), read_limit)].to_vec();
    let binary = data.contains(&0);
    let name = relative_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_string();

    Ok((
        name,
        entry.object_id().to_string(),
        size,
        data,
        truncated,
        binary,
    ))
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
