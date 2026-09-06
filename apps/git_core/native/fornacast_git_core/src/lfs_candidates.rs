use std::path::Path;

use super::{
    LFS_CANDIDATE_BLOB_LIMIT, LFS_CANDIDATE_STRUCTURAL_BYTE_LIMIT, LFS_EXPANSION_CHILD_LIMIT,
    NativeError, NativeLfsCandidate, NativeLfsChild, NativeLfsExpansion, bounded_blob,
    validate_tree_entry,
};

#[rustler::nif(schedule = "DirtyIo")]
fn expand_lfs_scan_object(
    path: String,
    oid: String,
    kind_hint: String,
    offset: u64,
    limit: usize,
) -> Result<NativeLfsExpansion, NativeError> {
    expand_lfs_scan_object_impl(&path, &oid, &kind_hint, offset, limit)
}

pub(crate) fn expand_lfs_scan_object_impl(
    path: &str,
    oid: &str,
    kind_hint: &str,
    offset: u64,
    limit: usize,
) -> Result<NativeLfsExpansion, NativeError> {
    if limit == 0 {
        return Err(error(
            "invalid_input",
            "LFS object expansion limit must be positive",
        ));
    }
    validate_kind_hint(kind_hint)?;

    let repo = open_physical_bare_repository(path)?;
    let oid = parse_oid(oid, repo.object_hash())?;
    let metadata = bounded_blob::read_object_prefix(&repo, oid, 1).map_err(blob_error)?;
    validate_actual_kind(kind_hint, metadata.kind, oid)?;
    let limit = limit.min(LFS_EXPANSION_CHILD_LIMIT);

    if metadata.kind == gix_object::Kind::Blob {
        return expand_blob(&repo, oid, metadata, offset);
    }
    if metadata.size > LFS_CANDIDATE_STRUCTURAL_BYTE_LIMIT {
        return Err(error(
            "scan_byte_limit",
            format!(
                "LFS traversal structural object {oid} exceeds {} decoded bytes",
                LFS_CANDIDATE_STRUCTURAL_BYTE_LIMIT
            ),
        ));
    }

    let object = load_verified_structural_object(&repo, oid)?;
    match object.kind {
        gix_object::Kind::Commit => expand_commit(&object.data, oid, offset, limit),
        gix_object::Kind::Tree => expand_tree(&object.data, oid, offset, limit),
        gix_object::Kind::Tag => expand_tag(&object.data, oid, kind_hint, offset),
        gix_object::Kind::Blob => unreachable!("blobs are expanded without a complete decode"),
    }
}

fn expand_blob(
    repo: &gix::Repository,
    oid: gix_hash::ObjectId,
    metadata: bounded_blob::PrefixBlob,
    offset: u64,
) -> Result<NativeLfsExpansion, NativeError> {
    require_zero_offset(offset, "blob")?;
    let candidate = if metadata.size <= LFS_CANDIDATE_BLOB_LIMIT {
        let complete =
            bounded_blob::read_verified_prefix(repo, oid, metadata.size, metadata.size as usize)
                .map_err(blob_error)?;
        if complete.truncated || complete.data.len() as u64 != metadata.size {
            return Err(error(
                "corrupt_repository",
                "LFS candidate blob read was not complete",
            ));
        }
        Some((complete.data, metadata.size) as NativeLfsCandidate)
    } else {
        None
    };
    Ok(("blob".to_string(), Vec::new(), candidate, None))
}

fn expand_commit(
    data: &[u8],
    oid: gix_hash::ObjectId,
    offset: u64,
    limit: usize,
) -> Result<NativeLfsExpansion, NativeError> {
    let commit = gix_object::CommitRef::from_bytes(data, oid.kind())
        .map_err(|decode_error| error("corrupt_repository", decode_error))?;
    let mut children = Vec::new();
    children.push((commit.tree().to_string(), "tree".to_string()));
    children.extend(
        commit
            .parents()
            .map(|parent| (parent.to_string(), "commit".to_string())),
    );
    page_indexed_children("commit", children, offset, limit)
}

fn page_indexed_children(
    kind: &'static str,
    children: Vec<NativeLfsChild>,
    offset: u64,
    limit: usize,
) -> Result<NativeLfsExpansion, NativeError> {
    let start = usize::try_from(offset)
        .map_err(|_| error("invalid_input", "LFS object offset does not fit usize"))?;
    if start > children.len() {
        return Err(error(
            "invalid_input",
            "LFS object offset is past the direct-child list",
        ));
    }
    let end = start.saturating_add(limit).min(children.len());
    let page = children[start..end].to_vec();
    let next = (end < children.len()).then_some(end as u64);
    Ok((kind.to_string(), page, None, next))
}

fn expand_tree(
    data: &[u8],
    oid: gix_hash::ObjectId,
    offset: u64,
    limit: usize,
) -> Result<NativeLfsExpansion, NativeError> {
    let mut cursor = usize::try_from(offset)
        .map_err(|_| error("invalid_input", "LFS tree offset does not fit usize"))?;
    if cursor > data.len() {
        return Err(error(
            "invalid_input",
            "LFS tree offset is past the object body",
        ));
    }

    // The byte offset keeps the public cursor constant-sized. Replaying the bounded (64 MiB)
    // object prefix restores the ordering witness needed to validate the first entry on this page.
    let mut validated_cursor = 0_usize;
    let mut previous = None;
    while validated_cursor < cursor {
        let remaining = &data[validated_cursor..];
        let entry = gix_object::TreeRefIter::from_bytes(remaining, oid.kind())
            .next()
            .ok_or_else(|| error("corrupt_repository", "tree entry is missing"))?
            .map_err(|decode_error| error("corrupt_repository", decode_error))?;
        validate_tree_entry(&mut previous, entry.filename.as_ref(), entry.mode.value())?;
        let header_end = remaining
            .iter()
            .position(|byte| *byte == 0)
            .ok_or_else(|| error("corrupt_repository", "tree entry has no name terminator"))?;
        let consumed = header_end
            .checked_add(1)
            .and_then(|value| value.checked_add(entry.oid.as_bytes().len()))
            .ok_or_else(|| error("corrupt_repository", "tree entry size overflow"))?;
        validated_cursor = validated_cursor
            .checked_add(consumed)
            .ok_or_else(|| error("corrupt_repository", "tree offset overflow"))?;
        if validated_cursor > cursor {
            return Err(error(
                "invalid_input",
                "LFS tree offset is not an entry boundary",
            ));
        }
    }

    let mut children = Vec::new();
    let mut entries_read = 0_usize;
    while cursor < data.len() && entries_read < limit {
        let remaining = &data[cursor..];
        let entry = gix_object::TreeRefIter::from_bytes(remaining, oid.kind())
            .next()
            .ok_or_else(|| error("corrupt_repository", "tree entry is missing"))?
            .map_err(|decode_error| error("corrupt_repository", decode_error))?;
        validate_tree_entry(&mut previous, entry.filename.as_ref(), entry.mode.value())?;
        let header_end = remaining
            .iter()
            .position(|byte| *byte == 0)
            .ok_or_else(|| error("corrupt_repository", "tree entry has no name terminator"))?;
        let consumed = header_end
            .checked_add(1)
            .and_then(|value| value.checked_add(entry.oid.as_bytes().len()))
            .ok_or_else(|| error("corrupt_repository", "tree entry size overflow"))?;
        cursor = cursor
            .checked_add(consumed)
            .ok_or_else(|| error("corrupt_repository", "tree offset overflow"))?;
        entries_read += 1;

        let child_kind = match entry.mode.kind() {
            gix_object::tree::EntryKind::Tree => Some("tree"),
            gix_object::tree::EntryKind::Blob
            | gix_object::tree::EntryKind::BlobExecutable
            | gix_object::tree::EntryKind::Link => Some("blob"),
            gix_object::tree::EntryKind::Commit => None,
        };
        if let Some(child_kind) = child_kind {
            children.push((entry.oid.to_string(), child_kind.to_string()));
        }
    }

    let next = (cursor < data.len()).then_some(cursor as u64);
    Ok(("tree".to_string(), children, None, next))
}

fn expand_tag(
    data: &[u8],
    oid: gix_hash::ObjectId,
    kind_hint: &str,
    offset: u64,
) -> Result<NativeLfsExpansion, NativeError> {
    require_zero_offset(offset, "tag")?;
    let tag = gix_object::TagRef::from_bytes(data, oid.kind())
        .map_err(|decode_error| error("corrupt_repository", decode_error))?;
    let target = tag.target();
    let target_kind = tag.target_kind;
    if matches!(kind_hint, "tag_or_commit" | "tag")
        && !matches!(
            target_kind,
            gix_object::Kind::Tag | gix_object::Kind::Commit
        )
    {
        return Err(error(
            "target_not_commit",
            "annotated tag baseline does not resolve toward a commit",
        ));
    }
    let child_hint = if matches!(kind_hint, "tag_or_commit" | "tag") {
        match target_kind {
            gix_object::Kind::Commit => "commit",
            gix_object::Kind::Tag => "tag_or_commit",
            _ => unreachable!("root tag targets were restricted to tags and commits"),
        }
    } else {
        object_kind_name(target_kind)
    };
    Ok((
        "tag".to_string(),
        vec![(target.to_string(), child_hint.to_string())],
        None,
        None,
    ))
}

fn validate_kind_hint(kind_hint: &str) -> Result<(), NativeError> {
    match kind_hint {
        "commit" | "tree" | "blob" | "tag" | "tag_or_commit" => Ok(()),
        _ => Err(error(
            "invalid_input",
            "LFS object kind hint must be commit, tree, blob, tag, or tag_or_commit",
        )),
    }
}

fn validate_actual_kind(
    hint: &str,
    actual: gix_object::Kind,
    oid: gix_hash::ObjectId,
) -> Result<(), NativeError> {
    let accepted = match hint {
        "commit" => actual == gix_object::Kind::Commit,
        "tree" => actual == gix_object::Kind::Tree,
        "blob" => actual == gix_object::Kind::Blob,
        "tag" => actual == gix_object::Kind::Tag,
        "tag_or_commit" => matches!(actual, gix_object::Kind::Tag | gix_object::Kind::Commit),
        _ => false,
    };
    if accepted {
        Ok(())
    } else {
        let kind = if hint == "tag_or_commit" {
            "target_not_commit"
        } else {
            "corrupt_repository"
        };
        Err(error(
            kind,
            format!(
                "object {oid} is {}, expected {hint}",
                object_kind_name(actual)
            ),
        ))
    }
}

fn require_zero_offset(offset: u64, kind: &str) -> Result<(), NativeError> {
    if offset == 0 {
        Ok(())
    } else {
        Err(error(
            "invalid_input",
            format!("LFS {kind} expansion offset must be zero"),
        ))
    }
}

fn object_kind_name(kind: gix_object::Kind) -> &'static str {
    match kind {
        gix_object::Kind::Commit => "commit",
        gix_object::Kind::Tree => "tree",
        gix_object::Kind::Blob => "blob",
        gix_object::Kind::Tag => "tag",
    }
}

fn parse_oid(value: &str, hash_kind: gix_hash::Kind) -> Result<gix_hash::ObjectId, NativeError> {
    let oid = gix_hash::ObjectId::from_hex(value.as_bytes())
        .map_err(|parse_error| error("invalid_input", parse_error))?;
    if oid.kind() != hash_kind {
        return Err(error(
            "invalid_input",
            "LFS object hash kind does not match repository",
        ));
    }
    Ok(oid)
}

fn load_verified_structural_object<'repo>(
    repo: &'repo gix::Repository,
    oid: gix_hash::ObjectId,
) -> Result<gix::Object<'repo>, NativeError> {
    let object = repo
        .find_object(oid)
        .map_err(|find_error| error("corrupt_repository", find_error))?;
    let actual = gix_object::compute_hash(repo.object_hash(), object.kind, &object.data)
        .map_err(|hash_error| error("corrupt_repository", hash_error))?;
    if actual != oid {
        return Err(error(
            "corrupt_repository",
            format!("object checksum mismatch: expected {oid}, computed {actual}"),
        ));
    }
    Ok(object)
}

fn open_physical_bare_repository(path: &str) -> Result<gix::Repository, NativeError> {
    std::fs::metadata(path).map_err(|io_error| error("storage_unavailable", io_error))?;
    let mut repo =
        gix::open(Path::new(path)).map_err(|open_error| error("invalid_repository", open_error))?;
    if !repo.is_bare() {
        return Err(error("invalid_repository", "repository is not bare"));
    }
    repo.objects.ignore_replacements = true;
    Ok(repo)
}

fn blob_error(blob_error: bounded_blob::Error) -> NativeError {
    let kind = match blob_error.kind() {
        bounded_blob::ErrorKind::StorageUnavailable => "storage_unavailable",
        bounded_blob::ErrorKind::CorruptRepository => "corrupt_repository",
        bounded_blob::ErrorKind::Stopped => "scan_timeout",
    };
    error(kind, blob_error)
}

fn error(kind: &'static str, detail: impl std::fmt::Display) -> NativeError {
    (kind.to_string(), detail.to_string())
}
