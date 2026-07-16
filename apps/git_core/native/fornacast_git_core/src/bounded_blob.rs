//! Prefix-bounded decoding for loose and packed Git blobs.
//!
//! The packed path deliberately does not use gix's complete-object decoder.
//! Instead, it borrows public pack entry slices, parses delta programs locally,
//! and recursively requests only copy ranges that overlap the caller's range.

use std::fs::File;
use std::io::Read;
use std::ops::Range;
use std::path::{Path, PathBuf};

const STREAM_BUFFER_TARGET: usize = 8 * 1024;
const MAX_CHAIN_DEPTH: usize = 64;

#[derive(Debug, PartialEq, Eq)]
enum DeltaInstruction {
    Insert { size: u64 },
    Copy { offset: u64, size: u64 },
}

fn decode_delta_varint(read_byte: &mut impl FnMut() -> Result<u8, String>) -> Result<u64, String> {
    let mut value = 0_u64;

    for index in 0..10_u32 {
        let byte = read_byte()?;
        let shift = index * 7;
        let component = u64::from(byte & 0x7f);
        if component > (u64::MAX >> shift) {
            return Err("delta varint overflow".to_string());
        }
        value |= component << shift;

        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }

    Err("delta varint exceeds 64 bits".to_string())
}

fn decode_delta_instruction(
    opcode: u8,
    read_byte: &mut impl FnMut() -> Result<u8, String>,
) -> Result<DeltaInstruction, String> {
    if opcode == 0 {
        return Err("delta opcode zero is reserved".to_string());
    }
    if opcode & 0x80 == 0 {
        return Ok(DeltaInstruction::Insert {
            size: u64::from(opcode),
        });
    }

    let mut offset = 0_u64;
    for (flag, shift) in [(0x01, 0), (0x02, 8), (0x04, 16), (0x08, 24)] {
        if opcode & flag != 0 {
            offset |= u64::from(read_byte()?) << shift;
        }
    }

    let mut size = 0_u64;
    for (flag, shift) in [(0x10, 0), (0x20, 8), (0x40, 16)] {
        if opcode & flag != 0 {
            size |= u64::from(read_byte()?) << shift;
        }
    }
    if size == 0 {
        size = 0x1_0000;
    }

    Ok(DeltaInstruction::Copy { offset, size })
}

fn overlapping_base_range(
    instruction: &DeltaInstruction,
    output_start: u64,
    requested: Range<u64>,
) -> Result<Option<Range<u64>>, String> {
    if requested.start > requested.end {
        return Err("requested delta range is reversed".to_string());
    }
    let DeltaInstruction::Copy { offset, size } = instruction else {
        return Ok(None);
    };
    let output_end = output_start
        .checked_add(*size)
        .ok_or_else(|| "delta output range overflow".to_string())?;
    let overlap_start = output_start.max(requested.start);
    let overlap_end = output_end.min(requested.end);
    if overlap_start >= overlap_end {
        return Ok(None);
    }

    let source_start = offset
        .checked_add(overlap_start - output_start)
        .ok_or_else(|| "delta base range overflow".to_string())?;
    let source_end = source_start
        .checked_add(overlap_end - overlap_start)
        .ok_or_else(|| "delta base range overflow".to_string())?;
    Ok(Some(source_start..source_end))
}

#[derive(Debug)]
pub(crate) struct PrefixBlob {
    pub(crate) size: u64,
    pub(crate) data: Vec<u8>,
    pub(crate) truncated: bool,
    #[cfg(test)]
    pub(crate) allocations: AllocationInstrumentation,
}

#[cfg(test)]
#[derive(Debug, Default)]
pub(crate) struct AllocationInstrumentation {
    pub(crate) content_bytes_allocated_before_header: usize,
    pub(crate) max_intermediate_object_buffer: usize,
    pub(crate) max_decoded_object_buffer: usize,
    pub(crate) max_decoded_base_buffer: usize,
    pub(crate) max_delta_buffer: usize,
    pub(crate) max_work_buffer: usize,
}

#[derive(Clone, Copy)]
enum BufferRole {
    ReturnedObject,
    DecodedObject,
    DecodedBase,
    Delta,
    Work,
}

struct AllocationTracker {
    caller_limit: usize,
    #[cfg(test)]
    header_known: bool,
    #[cfg(test)]
    instrumentation: AllocationInstrumentation,
}

impl AllocationTracker {
    fn new(caller_limit: usize) -> Self {
        Self {
            caller_limit,
            #[cfg(test)]
            header_known: false,
            #[cfg(test)]
            instrumentation: AllocationInstrumentation::default(),
        }
    }

    fn mark_header_known(&mut self) {
        #[cfg(test)]
        {
            self.header_known = true;
        }
    }

    fn returned_object(&mut self, capacity: usize) -> Result<Vec<u8>, String> {
        self.allocate(capacity, false, BufferRole::ReturnedObject)
    }

    fn stream_buffer(&mut self, role: BufferRole) -> Result<Vec<u8>, String> {
        let capacity = self.caller_limit.min(STREAM_BUFFER_TARGET);
        if capacity == 0 {
            return Err("cannot allocate a decode buffer for a zero-byte limit".to_string());
        }
        self.allocate(capacity, true, role)
    }

    fn allocate(
        &mut self,
        capacity: usize,
        zeroed: bool,
        role: BufferRole,
    ) -> Result<Vec<u8>, String> {
        if capacity > self.caller_limit {
            return Err(format!(
                "bounded decoder requested a {capacity}-byte buffer for a {}-byte limit",
                self.caller_limit
            ));
        }

        let mut buffer = Vec::with_capacity(capacity);
        if zeroed {
            buffer.resize(capacity, 0);
        }
        let actual = buffer.capacity();
        if actual > self.caller_limit {
            return Err(format!(
                "allocator returned a {actual}-byte buffer for a {}-byte limit",
                self.caller_limit
            ));
        }
        #[cfg(test)]
        {
            if !self.header_known {
                self.instrumentation.content_bytes_allocated_before_header = self
                    .instrumentation
                    .content_bytes_allocated_before_header
                    .saturating_add(actual);
            }
            self.record_capacity(role, actual);
        }
        #[cfg(not(test))]
        let _ = role;
        Ok(buffer)
    }

    #[cfg(test)]
    fn record_capacity(&mut self, role: BufferRole, actual: usize) {
        match role {
            BufferRole::ReturnedObject => {
                self.instrumentation.max_decoded_object_buffer =
                    self.instrumentation.max_decoded_object_buffer.max(actual);
            }
            BufferRole::DecodedObject => {
                self.instrumentation.max_intermediate_object_buffer = self
                    .instrumentation
                    .max_intermediate_object_buffer
                    .max(actual);
                self.instrumentation.max_decoded_object_buffer =
                    self.instrumentation.max_decoded_object_buffer.max(actual);
            }
            BufferRole::DecodedBase => {
                self.instrumentation.max_decoded_base_buffer =
                    self.instrumentation.max_decoded_base_buffer.max(actual);
            }
            BufferRole::Delta => {
                self.instrumentation.max_delta_buffer =
                    self.instrumentation.max_delta_buffer.max(actual);
            }
            BufferRole::Work => {
                self.instrumentation.max_work_buffer =
                    self.instrumentation.max_work_buffer.max(actual);
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum ObjectSource {
    Loose {
        object_db: PathBuf,
        id: gix_hash::ObjectId,
    },
    Packed {
        index_path: PathBuf,
        pack_offset: gix_pack::data::Offset,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ObjectMetadata {
    kind: gix_object::Kind,
    size: u64,
}

struct OpenedPack {
    bundle: gix_pack::Bundle,
    entry: gix_pack::data::Entry,
    entry_end: gix_pack::data::Offset,
}

impl OpenedPack {
    fn compressed(&self) -> Result<&[u8], String> {
        self.bundle
            .pack
            .entry_slice(self.entry.data_offset..self.entry_end)
            .ok_or_else(|| {
                format!(
                    "pack entry compressed range {}..{} is outside {}",
                    self.entry.data_offset,
                    self.entry_end,
                    self.bundle.pack.path().display()
                )
            })
    }
}

enum CompressedSource<'a> {
    Slice {
        bytes: &'a [u8],
        position: usize,
    },
    File {
        file: File,
        buffer: Vec<u8>,
        position: usize,
        length: usize,
        eof: bool,
    },
}

impl CompressedSource<'_> {
    fn decompress_once(
        &mut self,
        inflate: &mut gix_features::zlib::Decompress,
        output: &mut [u8],
    ) -> Result<(gix_features::zlib::Status, usize, usize, bool), String> {
        match self {
            CompressedSource::Slice { bytes, position } => {
                let input = &bytes[*position..];
                let eof = input.is_empty();
                let before_in = inflate.total_in();
                let before_out = inflate.total_out();
                let status = inflate
                    .decompress(
                        input,
                        output,
                        if eof {
                            gix_features::zlib::FlushDecompress::Finish
                        } else {
                            gix_features::zlib::FlushDecompress::None
                        },
                    )
                    .map_err(|error| format!("inflate pack entry: {error}"))?;
                let consumed = (inflate.total_in() - before_in) as usize;
                let written = (inflate.total_out() - before_out) as usize;
                *position = position
                    .checked_add(consumed)
                    .ok_or_else(|| "compressed input position overflow".to_string())?;
                Ok((status, consumed, written, eof))
            }
            CompressedSource::File {
                file,
                buffer,
                position,
                length,
                eof,
            } => {
                if *position == *length && !*eof {
                    *length = file
                        .read(buffer)
                        .map_err(|error| format!("read loose object: {error}"))?;
                    *position = 0;
                    *eof = *length == 0;
                }

                let input = &buffer[*position..*length];
                let input_eof = input.is_empty() && *eof;
                let before_in = inflate.total_in();
                let before_out = inflate.total_out();
                let status = inflate
                    .decompress(
                        input,
                        output,
                        if input_eof {
                            gix_features::zlib::FlushDecompress::Finish
                        } else {
                            gix_features::zlib::FlushDecompress::None
                        },
                    )
                    .map_err(|error| format!("inflate loose object: {error}"))?;
                let consumed = (inflate.total_in() - before_in) as usize;
                let written = (inflate.total_out() - before_out) as usize;
                *position = position
                    .checked_add(consumed)
                    .ok_or_else(|| "compressed input position overflow".to_string())?;
                Ok((status, consumed, written, input_eof))
            }
        }
    }

    fn is_exactly_exhausted(&mut self) -> Result<bool, String> {
        match self {
            CompressedSource::Slice { bytes, position } => Ok(*position == bytes.len()),
            CompressedSource::File {
                file,
                buffer,
                position,
                length,
                eof,
            } => {
                if *position != *length {
                    return Ok(false);
                }
                if *eof {
                    return Ok(true);
                }
                let read = file
                    .read(&mut buffer[..1])
                    .map_err(|error| format!("read loose object trailer: {error}"))?;
                *position = 0;
                *length = read;
                *eof = read == 0;
                Ok(read == 0)
            }
        }
    }
}

struct InflatedStream<'a> {
    source: CompressedSource<'a>,
    inflate: gix_features::zlib::Decompress,
    output: Vec<u8>,
    output_position: usize,
    output_length: usize,
    declared_size: Option<u64>,
    ended: bool,
}

impl<'a> InflatedStream<'a> {
    fn from_slice(
        bytes: &'a [u8],
        declared_size: u64,
        tracker: &mut AllocationTracker,
        role: BufferRole,
    ) -> Result<Self, String> {
        Ok(Self {
            source: CompressedSource::Slice { bytes, position: 0 },
            inflate: gix_features::zlib::Decompress::new(),
            output: tracker.stream_buffer(role)?,
            output_position: 0,
            output_length: 0,
            declared_size: Some(declared_size),
            ended: false,
        })
    }

    fn from_file(
        file: File,
        tracker: &mut AllocationTracker,
        role: BufferRole,
    ) -> Result<Self, String> {
        let input = tracker.stream_buffer(BufferRole::Work)?;
        let output = tracker.stream_buffer(role)?;
        Ok(Self {
            source: CompressedSource::File {
                file,
                buffer: input,
                position: 0,
                length: 0,
                eof: false,
            },
            inflate: gix_features::zlib::Decompress::new(),
            output,
            output_position: 0,
            output_length: 0,
            declared_size: None,
            ended: false,
        })
    }

    fn set_declared_size(&mut self, declared_size: u64) -> Result<(), String> {
        let produced = self.inflate.total_out();
        if produced > declared_size || (self.ended && produced != declared_size) {
            return Err(format!(
                "zlib stream produced {produced} bytes for declared size {declared_size}"
            ));
        }
        self.declared_size = Some(declared_size);
        Ok(())
    }

    fn read_required_byte(&mut self) -> Result<u8, String> {
        if self.available() == 0 {
            self.refill(1)?;
        }
        if self.available() == 0 {
            return Err("zlib stream ended before requested data".to_string());
        }
        let byte = self.output[self.output_position];
        self.output_position += 1;
        Ok(byte)
    }

    fn skip_exact(&mut self, mut count: u64) -> Result<(), String> {
        while count != 0 {
            if self.available() == 0 {
                let request = count.min(self.output.len() as u64) as usize;
                self.refill(request)?;
            }
            let available = self.available();
            if available == 0 {
                return Err("zlib stream ended before requested data".to_string());
            }
            let consumed = available.min(count.min(usize::MAX as u64) as usize);
            self.output_position += consumed;
            count -= consumed as u64;
        }
        Ok(())
    }

    fn append_exact(&mut self, mut count: u64, output: &mut Vec<u8>) -> Result<(), String> {
        while count != 0 {
            if self.available() == 0 {
                let request = count.min(self.output.len() as u64) as usize;
                self.refill(request)?;
            }
            let available = self.available();
            if available == 0 {
                return Err("zlib stream ended before requested data".to_string());
            }
            let consumed = available.min(count.min(usize::MAX as u64) as usize);
            let new_length = output
                .len()
                .checked_add(consumed)
                .ok_or_else(|| "bounded output length overflow".to_string())?;
            if new_length > output.capacity() {
                return Err(format!(
                    "bounded output would grow beyond its {}-byte allocation",
                    output.capacity()
                ));
            }
            output.extend_from_slice(
                &self.output[self.output_position..self.output_position + consumed],
            );
            self.output_position += consumed;
            count -= consumed as u64;
        }
        Ok(())
    }

    fn finish_exact(&mut self) -> Result<(), String> {
        if self.available() != 0 {
            return Err("zlib stream produced unconsumed decoded bytes".to_string());
        }
        self.refill(1)?;
        if self.available() != 0 {
            return Err("zlib stream produced more bytes than declared".to_string());
        }
        if !self.ended {
            return Err("zlib stream did not reach StreamEnd".to_string());
        }
        Ok(())
    }

    fn is_ended(&self) -> bool {
        self.ended
    }

    fn available(&self) -> usize {
        self.output_length - self.output_position
    }

    fn refill(&mut self, requested: usize) -> Result<(), String> {
        if requested == 0 || self.ended {
            self.output_position = 0;
            self.output_length = 0;
            return Ok(());
        }
        if self.available() != 0 {
            return Err("attempted to refill with decoded bytes still buffered".to_string());
        }

        let output_len = requested.min(self.output.len());
        loop {
            let (status, consumed, written, input_was_eof) = self
                .source
                .decompress_once(&mut self.inflate, &mut self.output[..output_len])?;
            self.output_position = 0;
            self.output_length = written;

            if let Some(declared_size) = self.declared_size {
                let produced = self.inflate.total_out();
                if produced > declared_size {
                    return Err(format!(
                        "zlib stream produced {produced} bytes beyond declared size {declared_size}"
                    ));
                }
            }

            if status == gix_features::zlib::Status::StreamEnd {
                self.ended = true;
                if let Some(declared_size) = self.declared_size {
                    let produced = self.inflate.total_out();
                    if produced != declared_size {
                        return Err(format!(
                            "zlib StreamEnd at {produced} bytes, expected {declared_size}"
                        ));
                    }
                }
                if !self.source.is_exactly_exhausted()? {
                    return Err(
                        "zlib stream ended before the compressed entry boundary".to_string()
                    );
                }
            }

            if written != 0 || self.ended {
                return Ok(());
            }
            if consumed == 0 {
                return Err(if input_was_eof {
                    "zlib stream ended without StreamEnd".to_string()
                } else {
                    "zlib stream made no progress".to_string()
                });
            }
        }
    }
}

pub(crate) fn read_prefix(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    limit: usize,
) -> Result<PrefixBlob, String> {
    let mut tracker = AllocationTracker::new(limit);
    let header = repo.find_header(id).map_err(|error| error.to_string())?;
    if header.kind() != gix_object::Kind::Blob {
        return Err(format!("expected blob, found {}", header.kind()));
    }
    let size = header.size();
    tracker.mark_header_known();

    if limit == 0 {
        return Ok(PrefixBlob {
            size,
            data: Vec::new(),
            truncated: size != 0,
            #[cfg(test)]
            allocations: tracker.instrumentation,
        });
    }

    let source = locate_source(repo, id, None)?;
    let metadata = probe_source(repo, &source, &mut tracker, &mut Vec::new())?;
    if metadata.kind != gix_object::Kind::Blob || metadata.size != size {
        return Err(format!(
            "blob metadata mismatch: public header blob/{size}, storage {}/{}",
            metadata.kind, metadata.size
        ));
    }

    let read_limit = usize::try_from(size.min(limit as u64))
        .map_err(|_| "blob prefix does not fit usize".to_string())?;
    let mut data = tracker.returned_object(read_limit)?;
    append_source_range(
        repo,
        &source,
        metadata,
        0,
        read_limit,
        &mut data,
        &mut tracker,
        &mut Vec::new(),
    )?;
    if data.len() != read_limit || data.capacity() > limit {
        return Err(format!(
            "bounded decoder returned len={} capacity={} for limit={limit}",
            data.len(),
            data.capacity()
        ));
    }
    #[cfg(test)]
    tracker.record_capacity(BufferRole::ReturnedObject, data.capacity());

    Ok(PrefixBlob {
        size,
        truncated: size > read_limit as u64,
        data,
        #[cfg(test)]
        allocations: tracker.instrumentation,
    })
}

fn locate_source(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    preferred_index: Option<&Path>,
) -> Result<ObjectSource, String> {
    if let Some(path) = preferred_index
        && let Some(source) = packed_source_at(repo, path, id)?
    {
        return Ok(source);
    }

    let mut object_dbs = vec![repo.objects.store_ref().path().to_path_buf()];
    object_dbs.extend(
        repo.objects
            .store_ref()
            .alternate_db_paths()
            .map_err(|error| format!("load alternate object databases: {error}"))?,
    );

    for object_db in &object_dbs {
        for path in pack_index_paths(object_db)? {
            if preferred_index.is_some_and(|preferred| preferred == path) {
                continue;
            }
            if let Some(source) = packed_source_at(repo, &path, id)? {
                return Ok(source);
            }
        }
    }

    for object_db in object_dbs {
        let loose_path = loose_object_path_at(&object_db, id);
        if loose_path.is_file() {
            return Ok(ObjectSource::Loose { object_db, id });
        }
    }

    Err(format!(
        "unable to resolve object {id} from loose objects or public pack indexes"
    ))
}

fn pack_index_paths(object_db: &Path) -> Result<Vec<PathBuf>, String> {
    let pack_dir = object_db.join("pack");
    let entries = match std::fs::read_dir(&pack_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("read {}: {error}", pack_dir.display())),
    };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "idx"))
        .collect();
    paths.sort();
    Ok(paths)
}

fn packed_source_at(
    repo: &gix::Repository,
    index_path: &Path,
    id: gix_hash::ObjectId,
) -> Result<Option<ObjectSource>, String> {
    let bundle = gix_pack::Bundle::at(index_path, repo.object_hash())
        .map_err(|error| format!("open {}: {error}", index_path.display()))?;
    Ok(bundle.index.lookup(id).map(|index| ObjectSource::Packed {
        index_path: index_path.to_path_buf(),
        pack_offset: bundle.index.pack_offset_at_index(index),
    }))
}

fn open_packed(repo: &gix::Repository, source: &ObjectSource) -> Result<OpenedPack, String> {
    let ObjectSource::Packed {
        index_path,
        pack_offset,
    } = source
    else {
        return Err("attempted to open a loose object as a pack entry".to_string());
    };
    let bundle = gix_pack::Bundle::at(index_path, repo.object_hash())
        .map_err(|error| format!("open {}: {error}", index_path.display()))?;
    let mut offset_occurrences = 0_usize;
    let mut next_offset = None;
    for candidate in bundle.index.iter() {
        if candidate.pack_offset == *pack_offset {
            offset_occurrences += 1;
        } else if candidate.pack_offset > *pack_offset {
            next_offset = Some(next_offset.map_or(candidate.pack_offset, |current: u64| {
                current.min(candidate.pack_offset)
            }));
        }
    }
    if offset_occurrences != 1 {
        return Err(format!(
            "pack offset {pack_offset} occurs {offset_occurrences} times in {}",
            index_path.display(),
        ));
    }
    let entry = bundle
        .pack
        .entry(*pack_offset)
        .map_err(|error| format!("read public pack entry at {pack_offset}: {error}"))?;
    let entry_end = next_offset.unwrap_or(bundle.pack.pack_end() as u64);
    if *pack_offset >= entry.data_offset
        || entry.data_offset >= entry_end
        || entry_end > bundle.pack.pack_end() as u64
    {
        return Err(format!(
            "invalid pack entry range {}..{entry_end} at offset {pack_offset}",
            entry.data_offset
        ));
    }
    Ok(OpenedPack {
        bundle,
        entry,
        entry_end,
    })
}

fn probe_source(
    repo: &gix::Repository,
    source: &ObjectSource,
    tracker: &mut AllocationTracker,
    stack: &mut Vec<ObjectSource>,
) -> Result<ObjectMetadata, String> {
    enter_source(source, stack)?;
    let role = if stack.len() == 1 {
        BufferRole::DecodedObject
    } else {
        BufferRole::DecodedBase
    };
    let result = match source {
        ObjectSource::Loose { object_db, id } => {
            let path = loose_object_path_at(object_db, *id);
            let file = File::open(&path)
                .map_err(|error| format!("open loose object {}: {error}", path.display()))?;
            let mut stream = InflatedStream::from_file(file, tracker, role)?;
            read_loose_header(&mut stream)
        }
        ObjectSource::Packed { .. } => {
            let opened = open_packed(repo, source)?;
            if let Some(kind) = opened.entry.header.as_kind() {
                Ok(ObjectMetadata {
                    kind,
                    size: opened.entry.decompressed_size,
                })
            } else {
                let base = resolve_delta_base(repo, source, &opened)?;
                let base_metadata = probe_source(repo, &base, tracker, stack)?;
                let compressed = opened.compressed()?;
                let mut stream = InflatedStream::from_slice(
                    compressed,
                    opened.entry.decompressed_size,
                    tracker,
                    BufferRole::Delta,
                )?;
                let (declared_base_size, result_size) = read_delta_header(&mut stream)?;
                if declared_base_size != base_metadata.size {
                    return pop_result(
                        stack,
                        Err(format!(
                            "delta declares base size {declared_base_size}, resolved base has size {}",
                            base_metadata.size
                        )),
                    );
                }
                Ok(ObjectMetadata {
                    kind: base_metadata.kind,
                    size: result_size,
                })
            }
        }
    };
    pop_result(stack, result)
}

#[allow(clippy::too_many_arguments)]
fn append_source_range(
    repo: &gix::Repository,
    source: &ObjectSource,
    expected: ObjectMetadata,
    start: u64,
    length: usize,
    output: &mut Vec<u8>,
    tracker: &mut AllocationTracker,
    stack: &mut Vec<ObjectSource>,
) -> Result<(), String> {
    let end = start
        .checked_add(length as u64)
        .ok_or_else(|| "requested object range overflow".to_string())?;
    if end > expected.size {
        return Err(format!(
            "requested object range {start}..{end} exceeds size {}",
            expected.size
        ));
    }

    enter_source(source, stack)?;
    let output_start = output.len();
    let role = if stack.len() == 1 {
        BufferRole::DecodedObject
    } else {
        BufferRole::DecodedBase
    };
    let result = match source {
        ObjectSource::Loose { object_db, id } => {
            let path = loose_object_path_at(object_db, *id);
            let file = File::open(&path)
                .map_err(|error| format!("open loose object {}: {error}", path.display()))?;
            let mut stream = InflatedStream::from_file(file, tracker, role)?;
            let actual = read_loose_header(&mut stream)?;
            ensure_metadata(expected, actual)?;
            stream.skip_exact(start)?;
            stream.append_exact(length as u64, output)?;
            if end == expected.size {
                stream.finish_exact()?;
            }
            Ok(())
        }
        ObjectSource::Packed { .. } => {
            let opened = open_packed(repo, source)?;
            if let Some(kind) = opened.entry.header.as_kind() {
                let actual = ObjectMetadata {
                    kind,
                    size: opened.entry.decompressed_size,
                };
                ensure_metadata(expected, actual)?;
                let compressed = opened.compressed()?;
                let mut stream = InflatedStream::from_slice(
                    compressed,
                    opened.entry.decompressed_size,
                    tracker,
                    role,
                )?;
                stream.skip_exact(start)?;
                stream.append_exact(length as u64, output)?;
                if end == expected.size {
                    stream.finish_exact()?;
                }
                Ok(())
            } else {
                append_delta_range(
                    repo, source, &opened, expected, start, end, output, tracker, stack,
                )
            }
        }
    };

    let result = result.and_then(|()| {
        let appended = output.len() - output_start;
        if appended != length {
            Err(format!(
                "decoder appended {appended} bytes for a {length}-byte request"
            ))
        } else {
            Ok(())
        }
    });
    pop_result(stack, result)
}

#[allow(clippy::too_many_arguments)]
fn append_delta_range(
    repo: &gix::Repository,
    source: &ObjectSource,
    opened: &OpenedPack,
    expected: ObjectMetadata,
    start: u64,
    end: u64,
    output: &mut Vec<u8>,
    tracker: &mut AllocationTracker,
    stack: &mut Vec<ObjectSource>,
) -> Result<(), String> {
    let base = resolve_delta_base(repo, source, opened)?;
    let mut probe_stack = stack.clone();
    let base_metadata = probe_source(repo, &base, tracker, &mut probe_stack)?;
    let compressed = opened.compressed()?;
    let mut stream = InflatedStream::from_slice(
        compressed,
        opened.entry.decompressed_size,
        tracker,
        BufferRole::Delta,
    )?;
    let (declared_base_size, result_size) = read_delta_header(&mut stream)?;
    if declared_base_size != base_metadata.size {
        return Err(format!(
            "delta declares base size {declared_base_size}, resolved base has size {}",
            base_metadata.size
        ));
    }
    ensure_metadata(
        expected,
        ObjectMetadata {
            kind: base_metadata.kind,
            size: result_size,
        },
    )?;

    let requested = start..end;
    let mut result_position = 0_u64;
    while result_position < end {
        let opcode = stream.read_required_byte()?;
        let instruction = decode_delta_instruction(opcode, &mut || stream.read_required_byte())?;
        let instruction_size = match instruction {
            DeltaInstruction::Insert { size } | DeltaInstruction::Copy { size, .. } => size,
        };
        let instruction_end = result_position
            .checked_add(instruction_size)
            .ok_or_else(|| "delta result position overflow".to_string())?;
        if instruction_end > result_size {
            return Err(format!(
                "delta command ends at {instruction_end}, beyond result size {result_size}"
            ));
        }

        match &instruction {
            DeltaInstruction::Insert { size } => {
                if instruction_end <= start {
                    stream.skip_exact(*size)?;
                } else {
                    let overlap_start = result_position.max(start);
                    let overlap_end = instruction_end.min(end);
                    stream.skip_exact(overlap_start - result_position)?;
                    stream.append_exact(overlap_end - overlap_start, output)?;
                }
            }
            DeltaInstruction::Copy { offset, size } => {
                let base_end = offset
                    .checked_add(*size)
                    .ok_or_else(|| "delta base copy range overflow".to_string())?;
                if base_end > base_metadata.size {
                    return Err(format!(
                        "delta copy range {offset}..{base_end} exceeds base size {}",
                        base_metadata.size
                    ));
                }
                if let Some(base_range) =
                    overlapping_base_range(&instruction, result_position, requested.clone())?
                {
                    let length = usize::try_from(base_range.end - base_range.start)
                        .map_err(|_| "delta copy length does not fit usize".to_string())?;
                    append_source_range(
                        repo,
                        &base,
                        base_metadata,
                        base_range.start,
                        length,
                        output,
                        tracker,
                        stack,
                    )?;
                }
            }
        }
        result_position = instruction_end;
    }

    if stream.is_ended() && result_position < result_size {
        return Err(format!(
            "delta stream reached StreamEnd at result offset {result_position}, expected {result_size}"
        ));
    }
    if end == result_size {
        if result_position != result_size {
            return Err(format!(
                "delta result ended at {result_position}, expected {result_size}"
            ));
        }
        stream.finish_exact()?;
    }
    Ok(())
}

fn resolve_delta_base(
    repo: &gix::Repository,
    source: &ObjectSource,
    opened: &OpenedPack,
) -> Result<ObjectSource, String> {
    let ObjectSource::Packed {
        index_path,
        pack_offset,
    } = source
    else {
        return Err("a loose object cannot have a pack delta base".to_string());
    };
    match opened.entry.header {
        gix_pack::data::entry::Header::OfsDelta { base_distance } => {
            let base_pack_offset = gix_pack::data::entry::Header::verified_base_pack_offset(
                *pack_offset,
                base_distance,
            )
            .ok_or_else(|| {
                format!("invalid OFS_DELTA distance {base_distance} from pack offset {pack_offset}")
            })?;
            Ok(ObjectSource::Packed {
                index_path: index_path.clone(),
                pack_offset: base_pack_offset,
            })
        }
        gix_pack::data::entry::Header::RefDelta { base_id } => {
            if let Some(index) = opened.bundle.index.lookup(base_id) {
                return Ok(ObjectSource::Packed {
                    index_path: index_path.clone(),
                    pack_offset: opened.bundle.index.pack_offset_at_index(index),
                });
            }
            locate_source(repo, base_id, Some(index_path))
        }
        _ => Err("attempted to resolve a base for a non-delta pack entry".to_string()),
    }
}

fn read_delta_header(stream: &mut InflatedStream<'_>) -> Result<(u64, u64), String> {
    let base_size = decode_delta_varint(&mut || stream.read_required_byte())?;
    let result_size = decode_delta_varint(&mut || stream.read_required_byte())?;
    Ok((base_size, result_size))
}

fn read_loose_header(stream: &mut InflatedStream<'_>) -> Result<ObjectMetadata, String> {
    let mut kind_code = 0_u64;
    let mut kind_length = 0_usize;
    loop {
        let byte = stream.read_required_byte()?;
        if byte == b' ' {
            break;
        }
        if kind_length == 6 || !byte.is_ascii_lowercase() {
            return Err("invalid loose object kind".to_string());
        }
        kind_code = (kind_code << 8) | u64::from(byte);
        kind_length += 1;
    }
    let kind = match (kind_length, kind_code) {
        (4, 0x626c_6f62) => gix_object::Kind::Blob,
        (4, 0x7472_6565) => gix_object::Kind::Tree,
        (6, 0x636f_6d6d_6974) => gix_object::Kind::Commit,
        (3, 0x0074_6167) => gix_object::Kind::Tag,
        _ => return Err("unsupported loose object kind".to_string()),
    };

    let mut size = 0_u64;
    let mut digit_count = 0_usize;
    let mut first_digit = 0_u8;
    loop {
        let byte = stream.read_required_byte()?;
        if byte == 0 {
            break;
        }
        if !byte.is_ascii_digit() || digit_count == 20 {
            return Err("invalid loose object size".to_string());
        }
        if digit_count == 0 {
            first_digit = byte;
        }
        size = size
            .checked_mul(10)
            .and_then(|value| value.checked_add(u64::from(byte - b'0')))
            .ok_or_else(|| "loose object size overflow".to_string())?;
        digit_count += 1;
    }
    if digit_count == 0 || (digit_count > 1 && first_digit == b'0') {
        return Err("loose object size is not canonical".to_string());
    }

    let header_size = kind_length
        .checked_add(digit_count)
        .and_then(|value| value.checked_add(2))
        .ok_or_else(|| "loose object header size overflow".to_string())?
        as u64;
    stream.set_declared_size(
        header_size
            .checked_add(size)
            .ok_or_else(|| "loose object total size overflow".to_string())?,
    )?;
    Ok(ObjectMetadata { kind, size })
}

fn ensure_metadata(expected: ObjectMetadata, actual: ObjectMetadata) -> Result<(), String> {
    if expected == actual {
        Ok(())
    } else {
        Err(format!(
            "object metadata mismatch: expected {}/{}, found {}/{}",
            expected.kind, expected.size, actual.kind, actual.size
        ))
    }
}

fn enter_source(source: &ObjectSource, stack: &mut Vec<ObjectSource>) -> Result<(), String> {
    if stack.len() >= MAX_CHAIN_DEPTH {
        return Err(format!(
            "delta recursion exceeds the safe depth bound of {MAX_CHAIN_DEPTH}"
        ));
    }
    if stack.contains(source) {
        return Err("delta chain contains a cycle".to_string());
    }
    stack.push(source.clone());
    Ok(())
}

fn pop_result<T>(stack: &mut Vec<ObjectSource>, result: Result<T, String>) -> Result<T, String> {
    stack.pop();
    result
}

fn loose_object_path_at(object_db: &Path, id: gix_hash::ObjectId) -> PathBuf {
    let oid = id.to_string();
    object_db.join(Path::new(&oid[..2])).join(&oid[2..])
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::{
        DeltaInstruction, MAX_CHAIN_DEPTH, ObjectSource, decode_delta_instruction,
        decode_delta_varint, enter_source, overlapping_base_range, read_prefix,
    };

    const PREFIX_LIMIT: usize = 64 * 1024;
    const BLOB_SIZE: usize = 3 * 1024 * 1024 + 257;
    static FIXTURE_ID: AtomicU64 = AtomicU64::new(0);

    #[derive(Debug, Clone, Copy)]
    enum StorageForm {
        Loose,
        AlternateLoose,
        PackedBase,
        PackedDelta,
        PackedRefDelta,
    }

    struct Fixture {
        _temp: TempDirectory,
        repo_path: PathBuf,
        oid: gix_hash::ObjectId,
        original: Vec<u8>,
        evidence: String,
        storage: StorageForm,
    }

    struct TempDirectory(PathBuf);

    impl TempDirectory {
        fn new(label: &str) -> Self {
            let sequence = FIXTURE_ID.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "fornacast-prefix-blob-{label}-{}-{sequence}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).expect("create fixture directory");
            Self(path)
        }
    }

    impl Drop for TempDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn prefix_blob_loose_obeys_the_bounded_contract() {
        assert_bounded_contract(loose_fixture());
    }

    #[test]
    fn prefix_blob_alternate_loose_obeys_the_bounded_contract() {
        assert_bounded_contract(alternate_loose_fixture());
    }

    #[test]
    fn prefix_blob_packed_base_obeys_the_bounded_contract() {
        assert_bounded_contract(packed_base_fixture());
    }

    #[test]
    fn prefix_blob_packed_delta_obeys_the_bounded_contract() {
        assert_bounded_contract(packed_delta_fixture());
    }

    #[test]
    fn prefix_blob_packed_ref_delta_obeys_the_bounded_contract() {
        assert_bounded_contract(packed_ref_delta_fixture());
    }

    #[test]
    fn prefix_blob_limit_zero_returns_metadata_without_content_buffers() {
        let fixture = loose_fixture();
        let repo = gix::open(&fixture.repo_path).expect("open fixture repository");

        let prefix = read_prefix(&repo, fixture.oid, 0).expect("metadata-only prefix");

        assert_eq!(prefix.size, fixture.original.len() as u64);
        assert!(prefix.data.is_empty());
        assert!(prefix.truncated);
        assert_eq!(prefix.data.capacity(), 0);
        assert_eq!(prefix.allocations.max_decoded_object_buffer, 0);
        assert_eq!(prefix.allocations.max_decoded_base_buffer, 0);
    }

    #[test]
    fn prefix_blob_delta_varint_uses_little_endian_seven_bit_groups() {
        let mut bytes = [0x81, 0x01].into_iter();

        assert_eq!(
            decode_delta_varint(&mut || {
                bytes.next().ok_or_else(|| "unexpected end".to_string())
            })
            .expect("valid delta varint"),
            129
        );
    }

    #[test]
    fn prefix_blob_delta_varint_fails_closed_on_truncation_and_overflow() {
        let cases = [
            (vec![0x80], "truncated delta varint"),
            (vec![0x80; 10], "delta varint exceeds 64 bits"),
            (
                [vec![0x80; 9], vec![0x02]].concat(),
                "delta varint overflow",
            ),
        ];

        for (input, expected_error) in cases {
            let mut bytes = input.into_iter();
            let error = decode_delta_varint(&mut || {
                bytes
                    .next()
                    .ok_or_else(|| "truncated delta varint".to_string())
            })
            .expect_err("malformed delta varint must fail closed");

            assert_eq!(error, expected_error);
        }
    }

    #[test]
    fn prefix_blob_delta_opcodes_decode_insert_and_sparse_copy_fields() {
        let mut no_bytes = std::iter::empty();
        assert_eq!(
            decode_delta_instruction(5, &mut || {
                no_bytes.next().ok_or_else(|| "unexpected end".to_string())
            })
            .expect("insert opcode"),
            DeltaInstruction::Insert { size: 5 }
        );

        let mut copy_fields = [0x34, 0x12, 0x78, 0x56].into_iter();
        assert_eq!(
            decode_delta_instruction(0xb5, &mut || {
                copy_fields
                    .next()
                    .ok_or_else(|| "unexpected end".to_string())
            })
            .expect("copy opcode"),
            DeltaInstruction::Copy {
                offset: 0x0012_0034,
                size: 0x0000_5678,
            }
        );

        let mut no_bytes = std::iter::empty();
        assert!(
            decode_delta_instruction(0, &mut || {
                no_bytes.next().ok_or_else(|| "unexpected end".to_string())
            })
            .is_err(),
            "opcode zero is reserved and must fail closed"
        );
    }

    #[test]
    fn prefix_blob_delta_high_offset_copy_maps_only_the_requested_overlap() {
        let mut copy_fields = [0x0c, 0x01, 0x04].into_iter();
        let instruction = decode_delta_instruction(0x99, &mut || {
            copy_fields
                .next()
                .ok_or_else(|| "unexpected end".to_string())
        })
        .expect("high-offset copy opcode");

        assert_eq!(
            overlapping_base_range(&instruction, 20, 21..24).expect("valid overlap"),
            Some(0x0100_000d..0x0100_0010),
            "the decoder must request the high base range, not a base prefix"
        );
    }

    #[test]
    fn prefix_blob_delta_stack_rejects_cycles_and_excessive_depth() {
        let source = ObjectSource::Packed {
            index_path: PathBuf::from("fixture.idx"),
            pack_offset: 1,
        };
        let mut cycle_stack = Vec::new();
        enter_source(&source, &mut cycle_stack).expect("first visit");
        assert_eq!(
            enter_source(&source, &mut cycle_stack).expect_err("cycle must fail closed"),
            "delta chain contains a cycle"
        );

        let mut depth_stack = (0..MAX_CHAIN_DEPTH)
            .map(|offset| ObjectSource::Packed {
                index_path: PathBuf::from("fixture.idx"),
                pack_offset: offset as u64,
            })
            .collect();
        let next = ObjectSource::Packed {
            index_path: PathBuf::from("fixture.idx"),
            pack_offset: MAX_CHAIN_DEPTH as u64,
        };
        assert_eq!(
            enter_source(&next, &mut depth_stack).expect_err("depth overflow must fail closed"),
            format!("delta recursion exceeds the safe depth bound of {MAX_CHAIN_DEPTH}")
        );
    }

    fn assert_bounded_contract(fixture: Fixture) {
        eprintln!(
            "prefix_blob fixture {:?}: oid={} size={} evidence={}",
            fixture.storage,
            fixture.oid,
            fixture.original.len(),
            fixture.evidence
        );

        let repo = gix::open(&fixture.repo_path).expect("open fixture repository");
        let header = repo
            .find_header(fixture.oid)
            .expect("read exact object header");
        eprintln!(
            "gix public header: kind={} exact_size={} num_deltas={:?}",
            header.kind(),
            header.size(),
            header.num_deltas()
        );
        assert_eq!(header.kind(), gix_object::Kind::Blob);
        assert_eq!(header.size(), fixture.original.len() as u64);

        let prefix = read_prefix(&repo, fixture.oid, PREFIX_LIMIT)
            .expect("stable public APIs must decode the bounded prefix");
        assert_eq!(prefix.size, fixture.original.len() as u64);
        assert_eq!(prefix.data, fixture.original[..PREFIX_LIMIT]);
        assert!(prefix.data.len() <= PREFIX_LIMIT);
        assert!(PREFIX_LIMIT < fixture.original.len());
        assert!(prefix.truncated);
        assert_eq!(
            prefix.allocations.content_bytes_allocated_before_header, 0,
            "metadata must be known before allocating content"
        );
        assert!(
            prefix.allocations.max_intermediate_object_buffer < fixture.original.len(),
            "the largest actual intermediate object allocation must be smaller than the complete object"
        );
        assert!(
            prefix.allocations.max_decoded_base_buffer < fixture.original.len(),
            "the largest actual base allocation must be smaller than the complete base"
        );
        let max_actual_content_buffer = [
            prefix.allocations.max_decoded_object_buffer,
            prefix.allocations.max_decoded_base_buffer,
            prefix.allocations.max_delta_buffer,
            prefix.allocations.max_work_buffer,
        ]
        .into_iter()
        .max()
        .expect("allocation roles");
        assert!(
            max_actual_content_buffer <= PREFIX_LIMIT,
            "an actual decoded/output/delta/work allocation exceeded the prefix limit"
        );
        assert!(
            prefix.allocations.max_decoded_object_buffer <= PREFIX_LIMIT,
            "decoded object buffer exceeded the requested prefix"
        );
        assert!(
            prefix.allocations.max_decoded_base_buffer <= PREFIX_LIMIT,
            "decoded base buffer exceeded the requested prefix"
        );
        assert!(
            prefix.allocations.max_delta_buffer <= PREFIX_LIMIT,
            "delta buffer exceeded the requested prefix"
        );
        assert!(
            prefix.allocations.max_work_buffer <= PREFIX_LIMIT,
            "work buffer exceeded the requested prefix"
        );
        eprintln!(
            "bounded allocation evidence: returned={} pre_header={} intermediate_object={} decoded_object={} decoded_base={} delta={} work={} max_actual={}",
            prefix.data.len(),
            prefix.allocations.content_bytes_allocated_before_header,
            prefix.allocations.max_intermediate_object_buffer,
            prefix.allocations.max_decoded_object_buffer,
            prefix.allocations.max_decoded_base_buffer,
            prefix.allocations.max_delta_buffer,
            prefix.allocations.max_work_buffer,
            max_actual_content_buffer
        );

        let complete_limit = fixture.original.len() + 1;
        let complete = read_prefix(&repo, fixture.oid, complete_limit)
            .expect("a fitting limit must return the complete blob");
        assert_eq!(complete.size, fixture.original.len() as u64);
        assert_eq!(complete.data, fixture.original);
        assert!(complete.data.len() <= complete_limit);
        assert!(!complete.truncated);
        assert_eq!(
            complete.allocations.content_bytes_allocated_before_header,
            0
        );
        assert!(complete.allocations.max_intermediate_object_buffer < fixture.original.len());
        assert!(complete.allocations.max_decoded_object_buffer <= complete_limit);
        assert!(complete.allocations.max_decoded_base_buffer <= complete_limit);
        assert!(complete.allocations.max_delta_buffer <= complete_limit);
        assert!(complete.allocations.max_work_buffer <= complete_limit);
        eprintln!(
            "complete-limit allocation evidence: requested={} returned={} pre_header={} intermediate_object={} decoded_object={} decoded_base={} delta={} work={}",
            complete_limit,
            complete.data.len(),
            complete.allocations.content_bytes_allocated_before_header,
            complete.allocations.max_intermediate_object_buffer,
            complete.allocations.max_decoded_object_buffer,
            complete.allocations.max_decoded_base_buffer,
            complete.allocations.max_delta_buffer,
            complete.allocations.max_work_buffer
        );
    }

    fn loose_fixture() -> Fixture {
        let temp = TempDirectory::new("loose");
        let repo_path = temp.0.join("loose.git");
        git(
            &[
                "init",
                "--bare",
                "--object-format=sha1",
                path_str(&repo_path),
            ],
            None,
        );

        let original = deterministic_blob(0x6a09_e667_f3bc_c909);
        let oid_text = git(
            &[
                "--git-dir",
                path_str(&repo_path),
                "hash-object",
                "-w",
                "--stdin",
            ],
            Some(&original),
        );
        let oid = parse_oid(&oid_text);
        let loose_path = loose_object_path(&repo_path, &oid_text);
        assert!(
            loose_path.is_file(),
            "expected loose object at {}",
            loose_path.display()
        );
        let pack_dir = repo_path.join("objects/pack");
        assert!(
            !pack_dir.exists()
                || std::fs::read_dir(&pack_dir)
                    .expect("read pack directory")
                    .all(|entry| entry
                        .expect("pack entry")
                        .path()
                        .extension()
                        .is_none_or(|ext| ext != "idx")),
            "loose fixture unexpectedly contains a pack index"
        );

        Fixture {
            _temp: temp,
            repo_path,
            oid,
            original,
            evidence: format!(
                "loose object file {} exists and no pack index exists",
                loose_path.display()
            ),
            storage: StorageForm::Loose,
        }
    }

    fn alternate_loose_fixture() -> Fixture {
        let temp = TempDirectory::new("alternate-loose");
        let repo_path = temp.0.join("primary.git");
        let alternate_path = temp.0.join("alternate.git");
        for path in [&repo_path, &alternate_path] {
            git(
                &["init", "--bare", "--object-format=sha1", path_str(path)],
                None,
            );
        }

        let original = deterministic_blob(0x510e_527f_ade6_82d1);
        let oid_text = write_blob(&alternate_path, &original);
        let alternates_path = repo_path.join("objects/info/alternates");
        std::fs::write(
            &alternates_path,
            format!("{}\n", alternate_path.join("objects").display()),
        )
        .expect("write alternate object database path");
        assert!(loose_object_path(&alternate_path, &oid_text).is_file());

        Fixture {
            _temp: temp,
            repo_path,
            oid: parse_oid(&oid_text),
            original,
            evidence: format!(
                "loose object is stored through {}",
                alternates_path.display()
            ),
            storage: StorageForm::AlternateLoose,
        }
    }

    fn packed_base_fixture() -> Fixture {
        let temp = TempDirectory::new("packed-base");
        let repo_path = temp.0.join("packed-base.git");
        git(
            &[
                "init",
                "--bare",
                "--object-format=sha1",
                path_str(&repo_path),
            ],
            None,
        );

        let original = deterministic_blob(0xbb67_ae85_84ca_a73b);
        let oid_text = write_blob(&repo_path, &original);
        make_reachable(&repo_path, &[("packed-base.bin", &oid_text)]);
        git(
            &[
                "--git-dir",
                path_str(&repo_path),
                "repack",
                "-a",
                "-d",
                "-f",
                "--window=0",
                "--depth=0",
            ],
            None,
        );
        let verify = verify_pack(&repo_path);
        let evidence = verify_line(&verify, &oid_text);
        let fields: Vec<_> = evidence.split_whitespace().collect();
        assert_eq!(
            fields.get(1),
            Some(&"blob"),
            "verify-pack evidence: {evidence}"
        );
        assert_eq!(
            fields.get(2),
            Some(&BLOB_SIZE.to_string().as_str()),
            "verify-pack evidence: {evidence}"
        );
        assert_eq!(
            fields.len(),
            5,
            "expected packed-base five-field verify-pack line, got: {evidence}"
        );
        assert!(
            !loose_object_path(&repo_path, &oid_text).exists(),
            "packed-base object unexpectedly remains loose"
        );

        Fixture {
            _temp: temp,
            repo_path,
            oid: parse_oid(&oid_text),
            original,
            evidence,
            storage: StorageForm::PackedBase,
        }
    }

    fn packed_delta_fixture() -> Fixture {
        let temp = TempDirectory::new("packed-delta");
        let repo_path = temp.0.join("packed-delta.git");
        git(
            &[
                "init",
                "--bare",
                "--object-format=sha1",
                path_str(&repo_path),
            ],
            None,
        );

        let first = deterministic_blob(0x3c6e_f372_fe94_f82b);
        let mut second = first.clone();
        for block in [17usize, 181, 503, 701] {
            let start = block * 4096;
            for (index, byte) in second[start..start + 4096].iter_mut().enumerate() {
                *byte ^= (index as u8).wrapping_mul(31).wrapping_add(block as u8);
            }
        }

        let first_oid = write_blob(&repo_path, &first);
        let second_oid = write_blob(&repo_path, &second);
        make_reachable(
            &repo_path,
            &[("first.bin", &first_oid), ("second.bin", &second_oid)],
        );
        git(
            &[
                "--git-dir",
                path_str(&repo_path),
                "repack",
                "-a",
                "-d",
                "-f",
                "--window=50",
                "--depth=50",
            ],
            None,
        );

        let verify = verify_pack(&repo_path);
        let originals = BTreeMap::from([(first_oid, first), (second_oid, second)]);
        let (oid_text, evidence) = originals
            .keys()
            .find_map(|oid| {
                let line = verify_line(&verify, oid);
                (line.split_whitespace().count() >= 7).then_some((oid.clone(), line))
            })
            .unwrap_or_else(|| panic!("expected one verified delta object:\n{verify}"));
        let fields: Vec<_> = evidence.split_whitespace().collect();
        assert_eq!(
            fields.get(1),
            Some(&"blob"),
            "verify-pack evidence: {evidence}"
        );
        assert!(
            fields
                .get(5)
                .and_then(|depth| depth.parse::<usize>().ok())
                .is_some_and(|depth| depth >= 1),
            "expected positive delta depth: {evidence}"
        );
        assert_eq!(
            fields.get(6).map(|oid| oid.len()),
            Some(40),
            "verify-pack evidence: {evidence}"
        );
        assert!(
            !loose_object_path(&repo_path, &oid_text).exists(),
            "packed-delta object unexpectedly remains loose"
        );
        assert_delta_header(&repo_path, &oid_text, false);
        let original = originals
            .get(&oid_text)
            .expect("selected delta original")
            .clone();

        Fixture {
            _temp: temp,
            repo_path,
            oid: parse_oid(&oid_text),
            original,
            evidence,
            storage: StorageForm::PackedDelta,
        }
    }

    fn packed_ref_delta_fixture() -> Fixture {
        let temp = TempDirectory::new("packed-ref-delta");
        let repo_path = temp.0.join("packed-ref-delta.git");
        git(
            &[
                "init",
                "--bare",
                "--object-format=sha1",
                path_str(&repo_path),
            ],
            None,
        );

        let first = deterministic_blob(0x1f83_d9ab_fb41_bd6b);
        let mut second = first.clone();
        for block in [17usize, 181, 503, 701] {
            let start = block * 4096;
            for (index, byte) in second[start..start + 4096].iter_mut().enumerate() {
                *byte ^= (index as u8).wrapping_mul(31).wrapping_add(block as u8);
            }
        }

        let first_oid = write_blob(&repo_path, &first);
        let second_oid = write_blob(&repo_path, &second);
        make_reachable(
            &repo_path,
            &[("first.bin", &first_oid), ("second.bin", &second_oid)],
        );
        let pack_prefix = repo_path.join("objects/pack/pack");
        git(
            &[
                "--git-dir",
                path_str(&repo_path),
                "pack-objects",
                "--all",
                "--window=50",
                "--depth=50",
                "--no-delta-base-offset",
                path_str(&pack_prefix),
            ],
            None,
        );
        git(&["--git-dir", path_str(&repo_path), "prune-packed"], None);

        let verify = verify_pack(&repo_path);
        let originals = BTreeMap::from([(first_oid, first), (second_oid, second)]);
        let (oid_text, evidence) = originals
            .keys()
            .find_map(|oid| {
                let line = verify_line(&verify, oid);
                (line.split_whitespace().count() >= 7).then_some((oid.clone(), line))
            })
            .unwrap_or_else(|| panic!("expected one verified REF_DELTA object:\n{verify}"));
        assert_delta_header(&repo_path, &oid_text, true);
        assert!(
            !loose_object_path(&repo_path, &oid_text).exists(),
            "packed REF_DELTA object unexpectedly remains loose"
        );
        let original = originals
            .get(&oid_text)
            .expect("selected REF_DELTA original")
            .clone();

        Fixture {
            _temp: temp,
            repo_path,
            oid: parse_oid(&oid_text),
            original,
            evidence,
            storage: StorageForm::PackedRefDelta,
        }
    }

    fn assert_delta_header(repo_path: &Path, oid: &str, expected_ref: bool) {
        let pack_dir = repo_path.join("objects/pack");
        let mut indexes: Vec<_> = std::fs::read_dir(&pack_dir)
            .expect("read pack directory")
            .map(|entry| entry.expect("pack directory entry").path())
            .filter(|path| path.extension().is_some_and(|extension| extension == "idx"))
            .collect();
        indexes.sort();
        assert_eq!(indexes.len(), 1, "expected exactly one pack index");
        let bundle = gix_pack::Bundle::at(&indexes[0], gix_hash::Kind::Sha1)
            .expect("open verified pack bundle");
        let object_index = bundle
            .index
            .lookup(parse_oid(oid))
            .expect("verified delta object in pack index");
        let entry = bundle
            .pack
            .entry(bundle.index.pack_offset_at_index(object_index))
            .expect("read verified delta pack entry");
        assert_eq!(
            matches!(entry.header, gix_pack::data::entry::Header::RefDelta { .. }),
            expected_ref,
            "unexpected delta header {:?}",
            entry.header
        );
        assert_eq!(
            matches!(entry.header, gix_pack::data::entry::Header::OfsDelta { .. }),
            !expected_ref,
            "unexpected delta header {:?}",
            entry.header
        );
    }

    fn deterministic_blob(mut state: u64) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(BLOB_SIZE);
        for _ in 0..BLOB_SIZE {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            bytes.push(state as u8);
        }
        bytes
    }

    fn write_blob(repo_path: &Path, data: &[u8]) -> String {
        git(
            &[
                "--git-dir",
                path_str(repo_path),
                "hash-object",
                "-w",
                "--stdin",
            ],
            Some(data),
        )
    }

    fn make_reachable(repo_path: &Path, blobs: &[(&str, &String)]) {
        let tree_input = blobs
            .iter()
            .map(|(name, oid)| format!("100644 blob {oid}\t{name}\n"))
            .collect::<String>();
        let tree_oid = git(
            &["--git-dir", path_str(repo_path), "mktree"],
            Some(tree_input.as_bytes()),
        );
        let commit_oid = git(
            &[
                "--git-dir",
                path_str(repo_path),
                "commit-tree",
                &tree_oid,
                "-m",
                "prefix blob fixture",
            ],
            None,
        );
        git(
            &[
                "--git-dir",
                path_str(repo_path),
                "update-ref",
                "refs/heads/main",
                &commit_oid,
            ],
            None,
        );
    }

    fn verify_pack(repo_path: &Path) -> String {
        let pack_dir = repo_path.join("objects/pack");
        let mut indexes: Vec<_> = std::fs::read_dir(&pack_dir)
            .expect("read pack directory")
            .map(|entry| entry.expect("pack directory entry").path())
            .filter(|path| path.extension().is_some_and(|extension| extension == "idx"))
            .collect();
        indexes.sort();
        assert_eq!(
            indexes.len(),
            1,
            "expected exactly one pack index: {indexes:?}"
        );
        git(&["verify-pack", "-v", path_str(&indexes[0])], None)
    }

    fn verify_line(output: &str, oid: &str) -> String {
        output
            .lines()
            .find(|line| line.split_whitespace().next() == Some(oid))
            .unwrap_or_else(|| panic!("verify-pack output has no line for {oid}:\n{output}"))
            .to_string()
    }

    fn loose_object_path(repo_path: &Path, oid: &str) -> PathBuf {
        repo_path.join("objects").join(&oid[..2]).join(&oid[2..])
    }

    fn parse_oid(oid: &str) -> gix_hash::ObjectId {
        gix_hash::ObjectId::from_hex(oid.as_bytes()).expect("valid fixture object id")
    }

    fn path_str(path: &Path) -> &str {
        path.to_str().expect("UTF-8 fixture path")
    }

    fn git(args: &[&str], input: Option<&[u8]>) -> String {
        let mut command = Command::new("git");
        command
            .args(args)
            .env("GIT_AUTHOR_NAME", "Fornacast Prefix Test")
            .env("GIT_AUTHOR_EMAIL", "prefix@example.com")
            .env("GIT_COMMITTER_NAME", "Fornacast Prefix Test")
            .env("GIT_COMMITTER_EMAIL", "prefix@example.com")
            .env("GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z")
            .env("GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        if input.is_some() {
            command.stdin(Stdio::piped());
        }

        let mut child = command.spawn().expect("spawn git fixture command");
        if let Some(input) = input {
            child
                .stdin
                .take()
                .expect("git stdin")
                .write_all(input)
                .expect("write git fixture input");
        }
        let output = child
            .wait_with_output()
            .expect("wait for git fixture command");
        assert!(
            output.status.success(),
            "git {} failed with {:?}:\n{}",
            args.join(" "),
            output.status.code(),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("git fixture output is UTF-8")
            .trim()
            .to_string()
    }
}
