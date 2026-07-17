//! Prefix-bounded decoding for loose and packed Git blobs.
//!
//! The packed path deliberately does not use gix's complete-object decoder.
//! Instead, it borrows public pack entry slices, parses delta programs locally,
//! and recursively requests only copy ranges that overlap the caller's range.

use std::cell::{Cell, RefCell};
use std::fs::File;
use std::io::Read;
use std::ops::Range;
use std::path::{Path, PathBuf};

use gix_object::bstr::ByteSlice;

const STREAM_BUFFER_TARGET: usize = 8 * 1024;
const METADATA_BUFFER_LIMIT: usize = 32;
const PUBLIC_HEADER_OUTPUT_LIMIT: u64 = 64;
const MAX_CHAIN_DEPTH: usize = 64;
const MIB: u64 = 1024 * 1024;
const MAX_DELTA_INSTRUCTIONS: u64 = 65_536;
const MAX_SOURCE_OPENS: u64 = 4_096;
const MAX_INDEX_ENTRIES_SCANNED: u64 = 1_000_000;
const MAX_COMPRESSED_INPUT_BYTES: u64 = 256 * MIB;
const MAX_INFLATED_OUTPUT_BYTES: u64 = 512 * MIB;
const MAX_VISITOR_COMPRESSED_INPUT_BYTES: u64 =
    MAX_COMPRESSED_INPUT_BYTES + 2 * MAX_INFLATED_OUTPUT_BYTES;
const MAX_VISITOR_INFLATED_OUTPUT_BYTES: u64 =
    MAX_INFLATED_OUTPUT_BYTES + MAX_INFLATED_OUTPUT_BYTES;
const MAX_DISCOVERY_BYTES: u64 = 8 * MIB;
const MIN_PACK_INDEX_BYTES_PER_ENTRY: u64 = 24;
const BLOB_METADATA_WORK_LIMIT: usize = 100_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ErrorKind {
    StorageUnavailable,
    CorruptRepository,
    Stopped,
}

#[derive(Debug)]
pub(crate) struct Error {
    kind: ErrorKind,
    detail: String,
}

impl Error {
    fn corrupt(detail: impl std::fmt::Display) -> Self {
        Self {
            kind: ErrorKind::CorruptRepository,
            detail: detail.to_string(),
        }
    }

    fn storage(detail: impl std::fmt::Display) -> Self {
        Self {
            kind: ErrorKind::StorageUnavailable,
            detail: detail.to_string(),
        }
    }

    fn stopped() -> Self {
        Self {
            kind: ErrorKind::Stopped,
            detail: "blob visit stopped cooperatively".to_string(),
        }
    }

    #[cfg(test)]
    fn from_bundle(error: gix_pack::bundle::init::Error) -> Self {
        let kind = match &error {
            gix_pack::bundle::init::Error::Pack(gix_pack::data::header::decode::Error::Io {
                ..
            })
            | gix_pack::bundle::init::Error::Index(gix_pack::index::init::Error::Io { .. }) => {
                ErrorKind::StorageUnavailable
            }
            _ => ErrorKind::CorruptRepository,
        };
        Self {
            kind,
            detail: error.to_string(),
        }
    }

    fn from_index(error: gix_pack::index::init::Error) -> Self {
        let kind = if matches!(&error, gix_pack::index::init::Error::Io { .. }) {
            ErrorKind::StorageUnavailable
        } else {
            ErrorKind::CorruptRepository
        };
        Self {
            kind,
            detail: error.to_string(),
        }
    }

    fn from_pack(error: gix_pack::data::header::decode::Error) -> Self {
        let kind = if matches!(&error, gix_pack::data::header::decode::Error::Io { .. }) {
            ErrorKind::StorageUnavailable
        } else {
            ErrorKind::CorruptRepository
        };
        Self {
            kind,
            detail: error.to_string(),
        }
    }

    fn from_loose_header(error: gix::odb::loose::find::Error) -> Self {
        let kind = match &error {
            gix::odb::loose::find::Error::Io { .. } => ErrorKind::StorageUnavailable,
            _ => ErrorKind::CorruptRepository,
        };
        Self {
            kind,
            detail: error.to_string(),
        }
    }

    pub(crate) fn kind(&self) -> ErrorKind {
        self.kind
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.detail)
    }
}

impl std::error::Error for Error {}

impl From<String> for Error {
    fn from(detail: String) -> Self {
        Self::corrupt(detail)
    }
}

type DecodeResult<T> = Result<T, Error>;

#[derive(Debug, PartialEq, Eq)]
enum DeltaInstruction {
    Insert { size: u64 },
    Copy { offset: u64, size: u64 },
}

fn decode_delta_varint<E: From<String>>(
    read_byte: &mut impl FnMut() -> Result<u8, E>,
) -> Result<u64, E> {
    let mut value = 0_u64;

    for index in 0..10_u32 {
        let byte = read_byte()?;
        let shift = index * 7;
        let component = u64::from(byte & 0x7f);
        if component > (u64::MAX >> shift) {
            return Err("delta varint overflow".to_string().into());
        }
        value |= component << shift;

        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }

    Err("delta varint exceeds 64 bits".to_string().into())
}

fn decode_delta_instruction<E: From<String>>(
    opcode: u8,
    read_byte: &mut impl FnMut() -> Result<u8, E>,
) -> Result<DeltaInstruction, E> {
    if opcode == 0 {
        return Err("delta opcode zero is reserved".to_string().into());
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
    pub(crate) kind: gix_object::Kind,
    pub(crate) size: u64,
    pub(crate) data: Vec<u8>,
    pub(crate) truncated: bool,
    #[cfg(test)]
    pub(crate) allocations: AllocationInstrumentation,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum VisitOutcome {
    Complete { size: u64 },
    TooLarge { size: u64 },
    Stopped { bytes: u64, started: bool },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct BlobMetadata {
    pub(crate) kind: gix_object::Kind,
    pub(crate) size: u64,
}

#[cfg(test)]
#[derive(Debug, Default)]
pub(crate) struct AllocationInstrumentation {
    pub(crate) content_bytes_allocated_before_header: usize,
    pub(crate) max_metadata_buffer: usize,
    pub(crate) max_intermediate_object_buffer: usize,
    pub(crate) max_decoded_object_buffer: usize,
    pub(crate) max_decoded_base_buffer: usize,
    pub(crate) max_delta_buffer: usize,
    pub(crate) max_work_buffer: usize,
    pub(crate) delta_instructions: u64,
    pub(crate) source_opens: u64,
    pub(crate) index_entries_scanned: u64,
    pub(crate) compressed_input_bytes: u64,
    pub(crate) inflated_output_bytes: u64,
    pub(crate) skipped_output_bytes: u64,
    pub(crate) discovery_bytes: u64,
}

#[derive(Clone, Copy, Debug)]
struct DecodeWorkLimits {
    delta_instructions: u64,
    source_opens: u64,
    index_entries_scanned: u64,
    compressed_input_bytes: u64,
    inflated_output_bytes: u64,
    skipped_output_bytes: u64,
    discovery_bytes: u64,
}

struct DecodeWorkBudget {
    limits: DecodeWorkLimits,
    delta_instructions: Cell<u64>,
    source_opens: Cell<u64>,
    index_entries_scanned: Cell<u64>,
    compressed_input_bytes: Cell<u64>,
    inflated_output_bytes: Cell<u64>,
    skipped_output_bytes: Cell<u64>,
    discovery_bytes: Cell<u64>,
    stop: Option<RefCell<Box<dyn FnMut() -> bool>>>,
}

impl DecodeWorkBudget {
    fn new(caller_limit: usize) -> DecodeResult<Self> {
        Self::new_with_stop(caller_limit, None)
    }

    fn with_stop_hook(
        caller_limit: usize,
        output_allowance: u64,
        stop: impl FnMut() -> bool + 'static,
    ) -> DecodeResult<Self> {
        let mut budget = Self::new_with_stop(caller_limit, Some(Box::new(stop)))?;
        let output_allowance = output_allowance.min(MAX_INFLATED_OUTPUT_BYTES);
        budget.limits.inflated_output_bytes = budget
            .limits
            .inflated_output_bytes
            .checked_add(output_allowance)
            .map(|limit| limit.min(MAX_VISITOR_INFLATED_OUTPUT_BYTES))
            .ok_or_else(|| Error::corrupt("visitor inflated work limit overflow"))?;
        budget.limits.skipped_output_bytes = budget
            .limits
            .skipped_output_bytes
            .checked_add(output_allowance)
            .map(|limit| limit.min(MAX_VISITOR_INFLATED_OUTPUT_BYTES))
            .ok_or_else(|| Error::corrupt("visitor skipped work limit overflow"))?;
        let compressed_allowance = output_allowance
            .checked_mul(2)
            .ok_or_else(|| Error::corrupt("visitor compressed work allowance overflow"))?;
        budget.limits.compressed_input_bytes = budget
            .limits
            .compressed_input_bytes
            .checked_add(compressed_allowance)
            .map(|limit| limit.min(MAX_VISITOR_COMPRESSED_INPUT_BYTES))
            .ok_or_else(|| Error::corrupt("visitor compressed work limit overflow"))?;
        Ok(budget)
    }

    fn new_with_stop(
        caller_limit: usize,
        stop: Option<Box<dyn FnMut() -> bool>>,
    ) -> DecodeResult<Self> {
        let caller_limit = u64::try_from(caller_limit)
            .map_err(|_| Error::corrupt("caller limit does not fit the decode work counter"))?;
        let limits = DecodeWorkLimits {
            // Tiny instructions are the cheapest possible valid delta commands. Requiring
            // sixteen requested bytes per command, with a small baseline, keeps normal Git
            // deltas valid while bounding adversarial one-byte COPY programs.
            delta_instructions: scaled_work_limit(
                caller_limit,
                128,
                1,
                16,
                MAX_DELTA_INSTRUCTIONS,
            )?,
            // Source opens remain bounded independently because a COPY can otherwise reopen
            // and reinflate the same base even when its output overlaps by only one byte.
            source_opens: scaled_work_limit(caller_limit, 512, 1, 4 * 1024, MAX_SOURCE_OPENS)?,
            // Linear directory/index scans are charged per entry. The larger baseline keeps
            // ordinary repositories usable without permitting an unbounded pack walk.
            index_entries_scanned: scaled_work_limit(
                caller_limit,
                65_536,
                1,
                16,
                MAX_INDEX_ENTRIES_SCANNED,
            )?,
            compressed_input_bytes: scaled_work_limit(
                caller_limit,
                16 * MIB,
                32,
                1,
                MAX_COMPRESSED_INPUT_BYTES,
            )?,
            inflated_output_bytes: scaled_work_limit(
                caller_limit,
                32 * MIB,
                32,
                1,
                MAX_INFLATED_OUTPUT_BYTES,
            )?,
            skipped_output_bytes: scaled_work_limit(
                caller_limit,
                32 * MIB,
                32,
                1,
                MAX_INFLATED_OUTPUT_BYTES,
            )?,
            discovery_bytes: scaled_work_limit(caller_limit, 64 * 1024, 1, 1, MAX_DISCOVERY_BYTES)?,
        };
        Ok(Self {
            limits,
            delta_instructions: Cell::new(0),
            source_opens: Cell::new(0),
            index_entries_scanned: Cell::new(0),
            compressed_input_bytes: Cell::new(0),
            inflated_output_bytes: Cell::new(0),
            skipped_output_bytes: Cell::new(0),
            discovery_bytes: Cell::new(0),
            stop: stop.map(RefCell::new),
        })
    }

    fn check_stop(&self) -> DecodeResult<()> {
        if self.stop.as_ref().is_some_and(|stop| (stop.borrow_mut())()) {
            Err(Error::stopped())
        } else {
            Ok(())
        }
    }

    fn charge_delta_instruction(&self) -> DecodeResult<()> {
        self.charge(
            &self.delta_instructions,
            1,
            self.limits.delta_instructions,
            "delta instructions",
        )
    }

    fn charge_source_open(&self, count: u64) -> DecodeResult<()> {
        self.charge(
            &self.source_opens,
            count,
            self.limits.source_opens,
            "source opens",
        )
    }

    fn charge_index_entries(&self, count: u64) -> DecodeResult<()> {
        self.charge(
            &self.index_entries_scanned,
            count,
            self.limits.index_entries_scanned,
            "index entries scanned",
        )
    }

    fn charge_compressed_input(&self, count: u64) -> DecodeResult<()> {
        self.charge(
            &self.compressed_input_bytes,
            count,
            self.limits.compressed_input_bytes,
            "compressed input bytes",
        )
    }

    fn charge_inflated_output(&self, count: u64) -> DecodeResult<()> {
        self.charge(
            &self.inflated_output_bytes,
            count,
            self.limits.inflated_output_bytes,
            "inflated output bytes",
        )
    }

    fn charge_skipped_output(&self, count: u64) -> DecodeResult<()> {
        self.charge(
            &self.skipped_output_bytes,
            count,
            self.limits.skipped_output_bytes,
            "skipped output bytes",
        )
    }

    fn charge_discovery_bytes(&self, count: u64) -> DecodeResult<()> {
        self.charge(
            &self.discovery_bytes,
            count,
            self.limits.discovery_bytes,
            "discovery bytes",
        )
    }

    fn compressed_chunk(&self, requested: usize) -> DecodeResult<usize> {
        self.remaining_chunk(
            &self.compressed_input_bytes,
            self.limits.compressed_input_bytes,
            requested.min(STREAM_BUFFER_TARGET),
            "compressed input bytes",
        )
    }

    fn inflated_chunk(&self, requested: usize) -> DecodeResult<usize> {
        self.remaining_chunk(
            &self.inflated_output_bytes,
            self.limits.inflated_output_bytes,
            requested,
            "inflated output bytes",
        )
    }

    fn charge(&self, counter: &Cell<u64>, count: u64, limit: u64, label: &str) -> DecodeResult<()> {
        self.check_stop()?;
        let next = counter
            .get()
            .checked_add(count)
            .ok_or_else(|| Error::corrupt(format!("decode work counter overflow: {label}")))?;
        counter.set(next);
        if next > limit {
            return Err(Error::corrupt(format!(
                "decode work budget exhausted: {label} {next} exceed limit {limit}"
            )));
        }
        Ok(())
    }

    fn remaining_chunk(
        &self,
        counter: &Cell<u64>,
        limit: u64,
        requested: usize,
        label: &str,
    ) -> DecodeResult<usize> {
        self.check_stop()?;
        if requested == 0 {
            return Ok(0);
        }
        let remaining = limit.saturating_sub(counter.get());
        if remaining == 0 {
            self.charge(counter, 1, limit, label)?;
            unreachable!("charging past an exhausted budget must fail")
        }
        Ok(requested.min(remaining.min(usize::MAX as u64) as usize))
    }

    #[cfg(test)]
    fn instrumentation(&self) -> DecodeWorkInstrumentation {
        DecodeWorkInstrumentation {
            delta_instructions: self.delta_instructions.get(),
            source_opens: self.source_opens.get(),
            index_entries_scanned: self.index_entries_scanned.get(),
            compressed_input_bytes: self.compressed_input_bytes.get(),
            inflated_output_bytes: self.inflated_output_bytes.get(),
            skipped_output_bytes: self.skipped_output_bytes.get(),
            discovery_bytes: self.discovery_bytes.get(),
        }
    }
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Default)]
struct DecodeWorkInstrumentation {
    delta_instructions: u64,
    source_opens: u64,
    index_entries_scanned: u64,
    compressed_input_bytes: u64,
    inflated_output_bytes: u64,
    skipped_output_bytes: u64,
    discovery_bytes: u64,
}

fn scaled_work_limit(
    caller_limit: u64,
    baseline: u64,
    numerator: u64,
    denominator: u64,
    hard_cap: u64,
) -> DecodeResult<u64> {
    let scaled = caller_limit
        .checked_mul(numerator)
        .and_then(|value| value.checked_add(denominator - 1))
        .ok_or_else(|| Error::corrupt("decode work limit overflow"))?
        / denominator;
    baseline
        .checked_add(scaled)
        .map(|limit| limit.min(hard_cap))
        .ok_or_else(|| Error::corrupt("decode work limit overflow"))
}

#[derive(Clone, Copy)]
enum BufferRole {
    Metadata,
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
        let capacity = match role {
            BufferRole::Metadata => METADATA_BUFFER_LIMIT,
            _ => self.caller_limit.min(STREAM_BUFFER_TARGET),
        };
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
        let allocation_limit = match role {
            BufferRole::Metadata => METADATA_BUFFER_LIMIT,
            _ => self.caller_limit,
        };
        if capacity > allocation_limit {
            return Err(format!(
                "bounded decoder requested a {capacity}-byte buffer for a {allocation_limit}-byte limit"
            ));
        }

        let mut buffer = Vec::with_capacity(capacity);
        if zeroed {
            buffer.resize(capacity, 0);
        }
        let actual = buffer.capacity();
        if actual > allocation_limit {
            return Err(format!(
                "allocator returned a {actual}-byte buffer for a {allocation_limit}-byte limit"
            ));
        }
        #[cfg(test)]
        {
            if !self.header_known && !matches!(role, BufferRole::Metadata) {
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
            BufferRole::Metadata => {
                self.instrumentation.max_metadata_buffer =
                    self.instrumentation.max_metadata_buffer.max(actual);
            }
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

    #[cfg(test)]
    fn record_work(&mut self, budget: &DecodeWorkBudget) {
        let work = budget.instrumentation();
        self.instrumentation.delta_instructions = work.delta_instructions;
        self.instrumentation.source_opens = work.source_opens;
        self.instrumentation.index_entries_scanned = work.index_entries_scanned;
        self.instrumentation.compressed_input_bytes = work.compressed_input_bytes;
        self.instrumentation.inflated_output_bytes = work.inflated_output_bytes;
        self.instrumentation.skipped_output_bytes = work.skipped_output_bytes;
        self.instrumentation.discovery_bytes = work.discovery_bytes;
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

#[derive(Debug)]
struct GuardedMetadata {
    object: ObjectMetadata,
    delta_bases: Vec<VerifiedDeltaBase>,
    pack_entries: Vec<VerifiedPackEntry>,
}

#[derive(Debug)]
struct VerifiedDeltaBase {
    delta: ObjectSource,
    base: ObjectSource,
    metadata: ObjectMetadata,
    ref_base_id: Option<gix_hash::ObjectId>,
}

#[derive(Debug)]
struct VerifiedPackEntry {
    source: ObjectSource,
    entry_end: gix_pack::data::Offset,
}

impl GuardedMetadata {
    fn delta_base(&self, source: &ObjectSource) -> DecodeResult<&VerifiedDeltaBase> {
        self.delta_bases
            .iter()
            .find(|candidate| candidate.delta == *source)
            .ok_or_else(|| Error::corrupt("guarded delta chain has no base for source"))
    }

    fn ref_base_kind(&self, id: &gix_hash::oid) -> Option<gix_object::Kind> {
        self.delta_bases.iter().find_map(|candidate| {
            candidate
                .ref_base_id
                .as_ref()
                .filter(|candidate_id| candidate_id.as_ref() == id)
                .map(|_| candidate.metadata.kind)
        })
    }

    fn pack_entry_end(&self, source: &ObjectSource) -> DecodeResult<gix_pack::data::Offset> {
        self.pack_entries
            .iter()
            .find(|candidate| candidate.source == *source)
            .map(|candidate| candidate.entry_end)
            .ok_or_else(|| Error::corrupt("guarded pack metadata has no entry for source"))
    }
}

struct OpenedPack {
    pack: gix_pack::data::File,
    index: Option<gix_pack::index::File>,
    entry: gix_pack::data::Entry,
    entry_end: gix_pack::data::Offset,
}

impl OpenedPack {
    fn compressed(&self) -> Result<&[u8], String> {
        self.pack
            .entry_slice(self.entry.data_offset..self.entry_end)
            .ok_or_else(|| {
                format!(
                    "pack entry compressed range {}..{} is outside {}",
                    self.entry.data_offset,
                    self.entry_end,
                    self.pack.path().display()
                )
            })
    }

    fn index(&self) -> DecodeResult<&gix_pack::index::File> {
        self.index
            .as_ref()
            .ok_or_else(|| Error::corrupt("guarded pack reopen has no index"))
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
        budget: &DecodeWorkBudget,
    ) -> DecodeResult<(gix_features::zlib::Status, usize, usize, bool)> {
        match self {
            CompressedSource::Slice { bytes, position } => {
                let remaining = &bytes[*position..];
                let input_len = budget.compressed_chunk(remaining.len())?;
                let input = &remaining[..input_len];
                let eof = remaining.is_empty();
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
                    .map_err(|error| Error::corrupt(format!("inflate pack entry: {error}")))?;
                let consumed = (inflate.total_in() - before_in) as usize;
                let written = (inflate.total_out() - before_out) as usize;
                budget.charge_compressed_input(consumed as u64)?;
                budget.charge_inflated_output(written as u64)?;
                *position = position
                    .checked_add(consumed)
                    .ok_or_else(|| Error::corrupt("compressed input position overflow"))?;
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
                    let read_limit = budget.compressed_chunk(buffer.len())?;
                    *length = file
                        .read(&mut buffer[..read_limit])
                        .map_err(|error| Error::storage(format!("read loose object: {error}")))?;
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
                    .map_err(|error| Error::corrupt(format!("inflate loose object: {error}")))?;
                let consumed = (inflate.total_in() - before_in) as usize;
                let written = (inflate.total_out() - before_out) as usize;
                budget.charge_compressed_input(consumed as u64)?;
                budget.charge_inflated_output(written as u64)?;
                *position = position
                    .checked_add(consumed)
                    .ok_or_else(|| Error::corrupt("compressed input position overflow"))?;
                Ok((status, consumed, written, input_eof))
            }
        }
    }

    fn is_exactly_exhausted(&mut self, budget: &DecodeWorkBudget) -> DecodeResult<bool> {
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
                let read_limit = budget.compressed_chunk(1)?;
                let read = file.read(&mut buffer[..read_limit]).map_err(|error| {
                    Error::storage(format!("read loose object trailer: {error}"))
                })?;
                budget.charge_compressed_input(read as u64)?;
                *position = 0;
                *length = read;
                *eof = read == 0;
                Ok(read == 0)
            }
        }
    }
}

trait DecodeSink {
    fn position(&self) -> u64;
    fn append(&mut self, bytes: &[u8]) -> DecodeResult<()>;
}

struct RetainedSink<'a> {
    output: &'a mut Vec<u8>,
}

impl DecodeSink for RetainedSink<'_> {
    fn position(&self) -> u64 {
        self.output.len() as u64
    }

    fn append(&mut self, bytes: &[u8]) -> DecodeResult<()> {
        let new_length = self
            .output
            .len()
            .checked_add(bytes.len())
            .ok_or_else(|| Error::corrupt("bounded output length overflow"))?;
        if new_length > self.output.capacity() {
            return Err(Error::corrupt(format!(
                "bounded output would grow beyond its {}-byte allocation",
                self.output.capacity()
            )));
        }
        self.output.extend_from_slice(bytes);
        Ok(())
    }
}

struct VerifiedVisitorSink<'a, F> {
    hasher: Option<gix_hash::Hasher>,
    visitor: &'a mut F,
    bytes: u64,
}

impl<F> VerifiedVisitorSink<'_, F>
where
    F: FnMut(&[u8]),
{
    fn new(
        hash_kind: gix_hash::Kind,
        size: u64,
        visitor: &mut F,
    ) -> DecodeResult<VerifiedVisitorSink<'_, F>> {
        let mut hasher = gix_hash::hasher(hash_kind);
        hasher.update(format!("blob {size}\0").as_bytes());
        Ok(VerifiedVisitorSink {
            hasher: Some(hasher),
            visitor,
            bytes: 0,
        })
    }

    fn finalize(mut self) -> DecodeResult<gix_hash::ObjectId> {
        self.hasher
            .take()
            .expect("verified visitor hasher is present until completion")
            .try_finalize()
            .map_err(Error::corrupt)
    }
}

impl<F> DecodeSink for VerifiedVisitorSink<'_, F>
where
    F: FnMut(&[u8]),
{
    fn position(&self) -> u64 {
        self.bytes
    }

    fn append(&mut self, bytes: &[u8]) -> DecodeResult<()> {
        if bytes.len() > STREAM_BUFFER_TARGET {
            return Err(Error::corrupt(format!(
                "streaming blob visitor received a {}-byte chunk",
                bytes.len()
            )));
        }
        self.hasher
            .as_mut()
            .expect("verified visitor hasher is present while decoding")
            .update(bytes);
        (self.visitor)(bytes);
        self.bytes = self
            .bytes
            .checked_add(bytes.len() as u64)
            .ok_or_else(|| Error::corrupt("streaming blob byte count overflow"))?;
        Ok(())
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
    ) -> DecodeResult<Self> {
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
    ) -> DecodeResult<Self> {
        let input_role = match role {
            BufferRole::Metadata => BufferRole::Metadata,
            _ => BufferRole::Work,
        };
        let input = tracker.stream_buffer(input_role)?;
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

    fn set_declared_size(&mut self, declared_size: u64) -> DecodeResult<()> {
        let produced = self.inflate.total_out();
        if produced > declared_size || (self.ended && produced != declared_size) {
            return Err(Error::corrupt(format!(
                "zlib stream produced {produced} bytes for declared size {declared_size}"
            )));
        }
        self.declared_size = Some(declared_size);
        Ok(())
    }

    fn read_required_byte(&mut self, budget: &DecodeWorkBudget) -> DecodeResult<u8> {
        budget.check_stop()?;
        if self.available() == 0 {
            self.refill(1, budget)?;
        }
        if self.available() == 0 {
            return Err(Error::corrupt("zlib stream ended before requested data"));
        }
        let byte = self.output[self.output_position];
        self.output_position += 1;
        Ok(byte)
    }

    fn skip_exact(&mut self, mut count: u64, budget: &DecodeWorkBudget) -> DecodeResult<()> {
        while count != 0 {
            budget.check_stop()?;
            if self.available() == 0 {
                let request = count.min(self.output.len() as u64) as usize;
                self.refill(request, budget)?;
            }
            let available = self.available();
            if available == 0 {
                return Err(Error::corrupt("zlib stream ended before requested data"));
            }
            let consumed = available.min(count.min(usize::MAX as u64) as usize);
            budget.charge_skipped_output(consumed as u64)?;
            self.output_position += consumed;
            count -= consumed as u64;
        }
        Ok(())
    }

    fn append_exact<S>(
        &mut self,
        mut count: u64,
        output: &mut S,
        budget: &DecodeWorkBudget,
    ) -> DecodeResult<()>
    where
        S: DecodeSink + ?Sized,
    {
        while count != 0 {
            budget.check_stop()?;
            if self.available() == 0 {
                let request = count.min(self.output.len() as u64) as usize;
                self.refill(request, budget)?;
            }
            let available = self.available();
            if available == 0 {
                return Err(Error::corrupt("zlib stream ended before requested data"));
            }
            let consumed = available.min(count.min(usize::MAX as u64) as usize);
            output.append(&self.output[self.output_position..self.output_position + consumed])?;
            self.output_position += consumed;
            count -= consumed as u64;
        }
        Ok(())
    }

    fn finish_exact(&mut self, budget: &DecodeWorkBudget) -> DecodeResult<()> {
        if self.available() != 0 {
            return Err(Error::corrupt(
                "zlib stream produced unconsumed decoded bytes",
            ));
        }
        self.refill(1, budget)?;
        if self.available() != 0 {
            return Err(Error::corrupt(
                "zlib stream produced more bytes than declared",
            ));
        }
        if !self.ended {
            return Err(Error::corrupt("zlib stream did not reach StreamEnd"));
        }
        Ok(())
    }

    fn is_ended(&self) -> bool {
        self.ended
    }

    fn available(&self) -> usize {
        self.output_length - self.output_position
    }

    fn refill(&mut self, requested: usize, budget: &DecodeWorkBudget) -> DecodeResult<()> {
        if requested == 0 || self.ended {
            self.output_position = 0;
            self.output_length = 0;
            return Ok(());
        }
        if self.available() != 0 {
            return Err(Error::corrupt(
                "attempted to refill with decoded bytes still buffered",
            ));
        }

        let output_len = budget.inflated_chunk(requested.min(self.output.len()))?;
        loop {
            budget.check_stop()?;
            let (status, consumed, written, input_was_eof) = self.source.decompress_once(
                &mut self.inflate,
                &mut self.output[..output_len],
                budget,
            )?;
            self.output_position = 0;
            self.output_length = written;

            if let Some(declared_size) = self.declared_size {
                let produced = self.inflate.total_out();
                if produced > declared_size {
                    return Err(Error::corrupt(format!(
                        "zlib stream produced {produced} bytes beyond declared size {declared_size}"
                    )));
                }
            }

            if status == gix_features::zlib::Status::StreamEnd {
                self.ended = true;
                if let Some(declared_size) = self.declared_size {
                    let produced = self.inflate.total_out();
                    if produced != declared_size {
                        return Err(Error::corrupt(format!(
                            "zlib StreamEnd at {produced} bytes, expected {declared_size}"
                        )));
                    }
                }
                if !self.source.is_exactly_exhausted(budget)? {
                    return Err(Error::corrupt(
                        "zlib stream ended before the compressed entry boundary",
                    ));
                }
            }

            if written != 0 || self.ended {
                return Ok(());
            }
            if consumed == 0 {
                return Err(Error::corrupt(if input_was_eof {
                    "zlib stream ended without StreamEnd"
                } else {
                    "zlib stream made no progress"
                }));
            }
        }
    }
}

#[cfg(test)]
pub(crate) fn read_prefix(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    limit: usize,
) -> DecodeResult<PrefixBlob> {
    read_prefix_impl(repo, id, limit, Some(gix_object::Kind::Blob), None)
}

pub(crate) fn read_object_prefix(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    limit: usize,
) -> DecodeResult<PrefixBlob> {
    read_prefix_impl(repo, id, limit, None, None)
}

pub(crate) fn read_blob_metadata(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
) -> DecodeResult<BlobMetadata> {
    let mut tracker = AllocationTracker::new(0);
    let budget = DecodeWorkBudget::new(BLOB_METADATA_WORK_LIMIT)?;
    let (_source, guarded) = inspect_object_metadata(repo, id, &mut tracker, &budget)?;
    let metadata = guarded.object;
    if metadata.kind != gix_object::Kind::Blob {
        return Err(Error::corrupt(format!(
            "expected {}, found {}",
            gix_object::Kind::Blob,
            metadata.kind,
        )));
    }

    Ok(BlobMetadata {
        kind: metadata.kind,
        size: metadata.size,
    })
}

pub(crate) fn read_verified_prefix(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    expected_size: u64,
    limit: usize,
) -> DecodeResult<PrefixBlob> {
    read_prefix_impl(
        repo,
        id,
        limit,
        Some(gix_object::Kind::Blob),
        Some(expected_size),
    )
}

pub(crate) fn visit_verified_blob<F, S>(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    max_size: u64,
    should_stop: S,
    visitor: &mut F,
) -> DecodeResult<VisitOutcome>
where
    F: FnMut(&[u8]),
    S: FnMut() -> bool + 'static,
{
    visit_verified_blob_impl(repo, id, max_size, should_stop, visitor).map(|(outcome, _)| outcome)
}

#[cfg(test)]
fn visit_verified_blob_instrumented<F, S>(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    max_size: u64,
    should_stop: S,
    visitor: &mut F,
) -> DecodeResult<(VisitOutcome, AllocationInstrumentation)>
where
    F: FnMut(&[u8]),
    S: FnMut() -> bool + 'static,
{
    visit_verified_blob_impl(repo, id, max_size, should_stop, visitor)
        .map(|(outcome, tracker)| (outcome, tracker.instrumentation))
}

fn visit_verified_blob_impl<F, S>(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    max_size: u64,
    should_stop: S,
    visitor: &mut F,
) -> DecodeResult<(VisitOutcome, AllocationTracker)>
where
    F: FnMut(&[u8]),
    S: FnMut() -> bool + 'static,
{
    let work_limit = usize::try_from(max_size.max(BLOB_METADATA_WORK_LIMIT as u64))
        .map_err(|_| Error::corrupt("streaming blob limit does not fit usize"))?;
    let mut tracker = AllocationTracker::new(STREAM_BUFFER_TARGET);
    let budget = DecodeWorkBudget::with_stop_hook(work_limit, max_size, should_stop)?;
    let (source, guarded) = match inspect_local_object_metadata(repo, id, &mut tracker, &budget) {
        Ok(inspected) => inspected,
        Err(error) if error.kind() == ErrorKind::Stopped => {
            #[cfg(test)]
            tracker.record_work(&budget);
            return Ok((
                VisitOutcome::Stopped {
                    bytes: 0,
                    started: false,
                },
                tracker,
            ));
        }
        Err(error) => return Err(error),
    };
    let metadata = guarded.object;
    if metadata.kind != gix_object::Kind::Blob {
        return Err(Error::corrupt(format!(
            "expected {}, found {}",
            gix_object::Kind::Blob,
            metadata.kind,
        )));
    }
    if metadata.size > max_size {
        #[cfg(test)]
        tracker.record_work(&budget);
        return Ok((
            VisitOutcome::TooLarge {
                size: metadata.size,
            },
            tracker,
        ));
    }
    let public = match public_metadata_for_source(repo, &source, &guarded, &budget) {
        Ok(public) => public,
        Err(error) if error.kind() == ErrorKind::Stopped => {
            #[cfg(test)]
            tracker.record_work(&budget);
            return Ok((
                VisitOutcome::Stopped {
                    bytes: 0,
                    started: false,
                },
                tracker,
            ));
        }
        Err(error) => return Err(error),
    };
    ensure_local_public_metadata(metadata, public)?;
    match budget.check_stop() {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::Stopped => {
            #[cfg(test)]
            tracker.record_work(&budget);
            return Ok((
                VisitOutcome::Stopped {
                    bytes: 0,
                    started: false,
                },
                tracker,
            ));
        }
        Err(error) => return Err(error),
    }

    let length = usize::try_from(metadata.size)
        .map_err(|_| Error::corrupt("streaming blob size does not fit usize"))?;
    tracker.mark_header_known();
    let mut sink = VerifiedVisitorSink::new(id.kind(), metadata.size, visitor)?;
    let result = append_source_range_to_sink(
        repo,
        &source,
        metadata,
        0,
        length,
        &mut sink,
        &mut tracker,
        &mut Vec::new(),
        &guarded,
        &budget,
    );

    let outcome = match result {
        Ok(()) => {
            if sink.bytes != metadata.size {
                return Err(Error::corrupt(format!(
                    "streaming blob decoder returned {} bytes for declared size {}",
                    sink.bytes, metadata.size
                )));
            }
            let actual = sink.finalize()?;
            if actual != id {
                return Err(Error::corrupt(format!(
                    "object checksum mismatch: expected {id}, computed {actual}"
                )));
            }
            Ok(VisitOutcome::Complete {
                size: metadata.size,
            })
        }
        Err(error) if error.kind() == ErrorKind::Stopped => Ok(VisitOutcome::Stopped {
            bytes: sink.bytes,
            started: sink.bytes != 0,
        }),
        Err(error) => Err(error),
    }?;
    #[cfg(test)]
    tracker.record_work(&budget);
    Ok((outcome, tracker))
}

fn read_prefix_impl(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    limit: usize,
    expected_kind: Option<gix_object::Kind>,
    expected_size: Option<u64>,
) -> DecodeResult<PrefixBlob> {
    let verifies_zero_body = limit == 0 && expected_size == Some(0);
    let decode_limit = if verifies_zero_body { 1 } else { limit };
    let mut tracker = AllocationTracker::new(decode_limit);
    let budget = DecodeWorkBudget::new(decode_limit)?;
    let (source, guarded) = inspect_object_metadata(repo, id, &mut tracker, &budget)?;
    let metadata = guarded.object;
    if expected_kind.is_some_and(|expected_kind| metadata.kind != expected_kind) {
        return Err(Error::corrupt(format!(
            "expected {}, found {}",
            expected_kind.expect("checked above"),
            metadata.kind,
        )));
    }
    if expected_size.is_some_and(|expected_size| metadata.size != expected_size) {
        return Err(Error::corrupt(format!(
            "blob size changed between metadata and body reads: expected {}, found {}",
            expected_size.expect("checked above"),
            metadata.size,
        )));
    }
    let kind = metadata.kind;
    let size = metadata.size;
    tracker.mark_header_known();

    if limit == 0 {
        if verifies_zero_body {
            let mut data = Vec::new();
            append_source_range(
                repo,
                &source,
                metadata,
                0,
                0,
                &mut data,
                &mut tracker,
                &mut Vec::new(),
                &guarded,
                &budget,
            )?;
            verify_complete_object_hash(repo, id, metadata, &data)?;
        }
        #[cfg(test)]
        tracker.record_work(&budget);
        return Ok(PrefixBlob {
            kind,
            size,
            data: Vec::new(),
            truncated: size != 0,
            #[cfg(test)]
            allocations: tracker.instrumentation,
        });
    }

    let read_limit = usize::try_from(size.min(limit as u64))
        .map_err(|_| Error::corrupt("blob prefix does not fit usize"))?;
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
        &guarded,
        &budget,
    )?;
    if data.len() != read_limit || data.capacity() > limit {
        return Err(Error::corrupt(format!(
            "bounded decoder returned len={} capacity={} for limit={limit}",
            data.len(),
            data.capacity()
        )));
    }
    #[cfg(test)]
    {
        tracker.record_capacity(BufferRole::ReturnedObject, data.capacity());
        tracker.record_work(&budget);
    }

    if expected_size.is_some() && size == read_limit as u64 {
        verify_complete_object_hash(repo, id, metadata, &data)?;
    }

    Ok(PrefixBlob {
        kind,
        size,
        truncated: size > read_limit as u64,
        data,
        #[cfg(test)]
        allocations: tracker.instrumentation,
    })
}

fn verify_complete_object_hash(
    repo: &gix::Repository,
    expected_id: gix_hash::ObjectId,
    metadata: ObjectMetadata,
    data: &[u8],
) -> DecodeResult<()> {
    let actual = gix_object::compute_hash(repo.object_hash(), metadata.kind, data)
        .map_err(|error| Error::corrupt(format!("hash complete object: {error}")))?;
    if actual != expected_id {
        return Err(Error::corrupt(format!(
            "object checksum mismatch: expected {expected_id}, computed {actual}"
        )));
    }
    Ok(())
}

fn inspect_object_metadata(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    tracker: &mut AllocationTracker,
    budget: &DecodeWorkBudget,
) -> DecodeResult<(ObjectSource, GuardedMetadata)> {
    let source = locate_source(repo, id, None, budget)?;
    let guarded = validate_local_metadata_before_public_header(
        || probe_guarded_source(repo, &source, tracker, budget),
        |guarded| public_metadata_for_source(repo, &source, guarded, budget),
    )?;
    Ok((source, guarded))
}

fn inspect_local_object_metadata(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    tracker: &mut AllocationTracker,
    budget: &DecodeWorkBudget,
) -> DecodeResult<(ObjectSource, GuardedMetadata)> {
    let source = locate_source(repo, id, None, budget)?;
    let guarded = probe_guarded_source(repo, &source, tracker, budget)?;
    Ok((source, guarded))
}

fn validate_local_metadata_before_public_header(
    local_probe: impl FnOnce() -> DecodeResult<GuardedMetadata>,
    public_header: impl FnOnce(&GuardedMetadata) -> DecodeResult<ObjectMetadata>,
) -> DecodeResult<GuardedMetadata> {
    let local = local_probe()?;
    let public = public_header(&local)?;
    ensure_local_public_metadata(local.object, public)?;
    Ok(local)
}

fn ensure_local_public_metadata(local: ObjectMetadata, public: ObjectMetadata) -> DecodeResult<()> {
    if local != public {
        return Err(Error::corrupt(format!(
            "object metadata mismatch: public header {}/{}, storage {}/{}",
            public.kind, public.size, local.kind, local.size
        )));
    }
    Ok(())
}

fn public_metadata_for_source(
    repo: &gix::Repository,
    source: &ObjectSource,
    guarded: &GuardedMetadata,
    budget: &DecodeWorkBudget,
) -> DecodeResult<ObjectMetadata> {
    match source {
        ObjectSource::Loose { object_db, id } => {
            let path = loose_object_path_at(object_db, *id);
            budget.charge_source_open(1)?;
            let compressed_len = std::fs::metadata(&path)
                .map_err(|error| {
                    Error::storage(format!(
                        "inspect guarded loose object {}: {error}",
                        path.display()
                    ))
                })?
                .len();
            // The exact loose-store API mmaps the object and gives the whole mapping to a
            // single bounded-output inflate call. Reserve the complete compressed file so
            // that call cannot bypass the request-wide input budget.
            budget.charge_compressed_input(compressed_len)?;
            budget.charge_inflated_output(PUBLIC_HEADER_OUTPUT_LIMIT)?;
            budget.charge_source_open(1)?;
            let store = gix::odb::loose::Store::at(
                object_db.clone(),
                repo.object_hash(),
                Some(METADATA_BUFFER_LIMIT),
            );
            let (size, kind) = store
                .try_header(id.as_ref())
                .map_err(Error::from_loose_header)?
                .ok_or_else(|| Error::corrupt("guarded loose source disappeared"))?;
            Ok(ObjectMetadata { kind, size })
        }
        ObjectSource::Packed { .. } => {
            let opened = open_guarded_packed(repo, source, guarded, budget)?;
            public_metadata_for_opened_pack(&opened, guarded, budget)
        }
    }
}

fn public_metadata_for_opened_pack(
    opened: &OpenedPack,
    guarded: &GuardedMetadata,
    budget: &DecodeWorkBudget,
) -> DecodeResult<ObjectMetadata> {
    let resolver_error = std::cell::RefCell::new(None);
    let resolve = |base_id: &gix_hash::oid| {
        if let Err(error) = budget.charge_index_entries(1) {
            *resolver_error.borrow_mut() = Some(error);
            return None;
        }
        guarded.ref_base_kind(base_id).map(|kind| {
            gix_pack::data::decode::header::ResolvedBase::OutOfPack {
                kind,
                num_deltas: None,
            }
        })
    };
    let mut inflate = gix_features::zlib::Inflate::default();
    let outcome = if opened.entry.header.as_kind().is_some() {
        // Base-object headers do not touch compressed input, so the original public
        // data file is safe and also supports packs too small for a truncated view.
        opened
            .pack
            .decode_header(opened.entry.clone(), &mut inflate, &resolve)
    } else {
        let public_pack = bounded_public_header_pack(opened, budget)?;
        public_pack.decode_header(opened.entry.clone(), &mut inflate, &resolve)
    };
    if let Some(error) = resolver_error.into_inner() {
        return Err(error);
    }
    let outcome = outcome.map_err(Error::corrupt)?;
    Ok(ObjectMetadata {
        kind: outcome.kind,
        size: outcome.object_size,
    })
}

fn bounded_public_header_pack<'a>(
    opened: &'a OpenedPack,
    budget: &DecodeWorkBudget,
) -> DecodeResult<gix_pack::data::File<&'a [u8]>> {
    let object_hash = opened.pack.object_hash();
    let view_end = opened.entry_end;
    let data = opened.pack.entry_slice(0..view_end).ok_or_else(|| {
        Error::corrupt(format!(
            "bounded public pack view 0..{view_end} is outside {}",
            opened.pack.path().display()
        ))
    })?;

    let accepted_input = view_end
        .checked_sub(opened.entry.data_offset)
        .ok_or_else(|| Error::corrupt("bounded public pack input range underflow"))?;
    // gix's public delta-header probe passes its complete backing suffix to one
    // inflate call. The constructor accepts this borrowed prefix even though its
    // synthetic pack_end excludes a hash-sized trailer; decode_header reads backing
    // data directly, so ending the slice at entry_end is the exact input boundary.
    budget.charge_compressed_input(accepted_input)?;
    budget.charge_inflated_output(PUBLIC_HEADER_OUTPUT_LIMIT)?;

    let bounded =
        gix_pack::data::File::from_data(data, opened.pack.path().to_path_buf(), object_hash)
            .map_err(Error::from_pack)?;
    if bounded.data_len() as u64 != opened.entry_end {
        return Err(Error::corrupt(format!(
            "bounded public pack data ends at {}, expected {}",
            bounded.data_len(),
            opened.entry_end
        )));
    }
    Ok(bounded)
}

fn locate_source(
    repo: &gix::Repository,
    id: gix_hash::ObjectId,
    preferred_index: Option<&Path>,
    budget: &DecodeWorkBudget,
) -> DecodeResult<ObjectSource> {
    let mut deferred_storage_error = None;
    if let Some(path) = preferred_index {
        match packed_source_at(repo, path, id, budget) {
            Ok(Some(source)) => return Ok(source),
            Ok(None) => {}
            Err(error) if error.kind() == ErrorKind::StorageUnavailable => {
                deferred_storage_error = Some(error);
            }
            Err(error) => return Err(error),
        }
    }

    let primary_object_db = repo.objects.store_ref().path().to_path_buf();
    let mut object_dbs = vec![primary_object_db.clone()];
    object_dbs.extend(alternate_object_dbs(
        &primary_object_db,
        repo.current_dir(),
        budget,
    )?);

    for object_db in &object_dbs {
        for path in pack_index_paths(object_db, budget)? {
            if preferred_index.is_some_and(|preferred| preferred == path) {
                continue;
            }
            match packed_source_at(repo, &path, id, budget) {
                Ok(Some(source)) => return Ok(source),
                Ok(None) => {}
                Err(error) if error.kind() == ErrorKind::StorageUnavailable => {
                    deferred_storage_error.get_or_insert(error);
                }
                Err(error) => return Err(error),
            }
        }
    }

    for object_db in object_dbs {
        let loose_path = loose_object_path_at(&object_db, id);
        budget.charge_source_open(1)?;
        match std::fs::metadata(&loose_path) {
            Ok(metadata) if metadata.is_file() => {
                return Ok(ObjectSource::Loose { object_db, id });
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(Error::storage(format!(
                    "inspect loose object {}: {error}",
                    loose_path.display()
                )));
            }
        }
    }

    Err(deferred_storage_error.unwrap_or_else(|| {
        Error::corrupt(format!(
            "unable to resolve object {id} from loose objects or public pack indexes"
        ))
    }))
}

fn alternate_object_dbs(
    primary_object_db: &Path,
    current_dir: &Path,
    budget: &DecodeWorkBudget,
) -> DecodeResult<Vec<PathBuf>> {
    budget.charge_source_open(1)?;
    let primary_canonical = resolve_alternate_path(primary_object_db, current_dir)?;
    let mut pending = vec![(0_usize, primary_object_db.to_path_buf())];
    let mut object_dbs = Vec::new();
    let mut seen = vec![primary_canonical];

    // Match gix's DFS/LIFO alternate ordering while putting all discovery I/O,
    // input bytes, path visits, recursion, and cycles under this request's budget.
    while let Some((depth, object_db)) = pending.pop() {
        if depth > MAX_CHAIN_DEPTH {
            return Err(Error::corrupt(format!(
                "alternate recursion exceeds the safe depth bound of {MAX_CHAIN_DEPTH}"
            )));
        }

        let alternates_path = object_db.join("info/alternates");
        budget.charge_source_open(1)?;
        let mut file = match File::open(&alternates_path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if depth != 0 {
                    object_dbs.push(object_db);
                }
                continue;
            }
            Err(error) => {
                return Err(Error::storage(format!(
                    "open alternate object databases {}: {error}",
                    alternates_path.display()
                )));
            }
        };

        let input_len = file
            .metadata()
            .map_err(|error| {
                Error::storage(format!(
                    "inspect alternate object databases {}: {error}",
                    alternates_path.display()
                ))
            })?
            .len();
        budget.charge_discovery_bytes(input_len)?;
        let input_len = usize::try_from(input_len)
            .map_err(|_| Error::corrupt("alternate discovery input does not fit usize"))?;
        let mut input = Vec::with_capacity(input_len);
        file.by_ref()
            .take(input_len as u64)
            .read_to_end(&mut input)
            .map_err(|error| {
                Error::storage(format!(
                    "read alternate object databases {}: {error}",
                    alternates_path.display()
                ))
            })?;
        let mut extra = [0_u8; 1];
        if file.read(&mut extra).map_err(|error| {
            Error::storage(format!(
                "finish reading alternate object databases {}: {error}",
                alternates_path.display()
            ))
        })? != 0
        {
            return Err(Error::corrupt(format!(
                "alternate object database list {} grew while reading",
                alternates_path.display()
            )));
        }

        for alternate in parse_alternate_paths(&input, budget)? {
            let alternate = primary_object_db.join(alternate);
            budget.charge_source_open(1)?;
            let alternate_canonical = resolve_alternate_path(&alternate, current_dir)?;
            if seen.contains(&alternate_canonical) {
                return Err(Error::corrupt(format!(
                    "alternate object databases form a cycle through {}",
                    alternate.display()
                )));
            }
            seen.push(alternate_canonical);
            pending.push((depth + 1, alternate));
        }

        if depth != 0 {
            object_dbs.push(object_db);
        }
    }
    Ok(object_dbs)
}

fn resolve_alternate_path(path: &Path, current_dir: &Path) -> DecodeResult<PathBuf> {
    gix::path::realpath_opts(path, current_dir, gix::path::realpath::MAX_SYMLINKS).map_err(
        |error| {
            let detail = format!(
                "resolve alternate object database {}: {error}",
                path.display()
            );
            match error {
                gix::path::realpath::Error::ReadLink(_)
                | gix::path::realpath::Error::CurrentWorkingDir(_) => Error::storage(detail),
                gix::path::realpath::Error::MaxSymlinksExceeded { .. }
                | gix::path::realpath::Error::ExcessiveComponentCount { .. }
                | gix::path::realpath::Error::EmptyPath
                | gix::path::realpath::Error::MissingParent => Error::corrupt(detail),
            }
        },
    )
}

fn parse_alternate_paths(input: &[u8], budget: &DecodeWorkBudget) -> DecodeResult<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for line in input.split(|byte| *byte == b'\n') {
        let line = line.as_bstr();
        if line.is_empty() || line.starts_with(b"#") {
            continue;
        }
        // Charge each non-comment path before unquoting or allocating it, so a tiny
        // many-line file cannot amplify into an unbounded Vec<PathBuf> first.
        budget.charge_source_open(1)?;
        let unquoted = gix_quote::ansi_c::undo(line)
            .map_err(|error| {
                Error::corrupt(format!("parse alternate object database path: {error}"))
            })?
            .0;
        let path = gix::path::try_from_bstr(unquoted)
            .map_err(|_| {
                Error::corrupt(format!(
                    "alternate object database path is not representable: {}",
                    String::from_utf8_lossy(line)
                ))
            })?
            .into_owned();
        paths.push(path);
    }
    Ok(paths)
}

fn pack_index_paths(object_db: &Path, budget: &DecodeWorkBudget) -> DecodeResult<Vec<PathBuf>> {
    let pack_dir = object_db.join("pack");
    budget.charge_source_open(1)?;
    let entries = match std::fs::read_dir(&pack_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(Error::storage(format!(
                "read {}: {error}",
                pack_dir.display()
            )));
        }
    };
    let mut paths = Vec::new();
    for entry in entries {
        budget.charge_index_entries(1)?;
        let path = entry
            .map(|entry| entry.path())
            .map_err(|error| Error::storage(format!("read {}: {error}", pack_dir.display())))?;
        if path.extension().is_some_and(|extension| extension == "idx") {
            paths.push(path);
        }
    }
    paths.sort();
    Ok(paths)
}

fn packed_source_at(
    repo: &gix::Repository,
    index_path: &Path,
    id: gix_hash::ObjectId,
    budget: &DecodeWorkBudget,
) -> DecodeResult<Option<ObjectSource>> {
    let index = open_pack_index(repo, index_path, budget)?;
    let Some(entry_index) = index.lookup(id) else {
        return Ok(None);
    };
    let pack_offset = index.pack_offset_at_index(entry_index);
    open_pack_data(repo, index_path, budget)?;
    Ok(Some(ObjectSource::Packed {
        index_path: index_path.to_path_buf(),
        pack_offset,
    }))
}

fn open_pack_index(
    repo: &gix::Repository,
    index_path: &Path,
    budget: &DecodeWorkBudget,
) -> DecodeResult<gix_pack::index::File> {
    budget.charge_source_open(1)?;
    let index_bytes = std::fs::metadata(index_path)
        .map_err(|error| {
            Error::storage(format!(
                "inspect pack index {}: {error}",
                index_path.display()
            ))
        })?
        .len();

    // A SHA-1 v1 entry is the smallest valid pack-index entry: four offset bytes
    // plus twenty object-id bytes. Charging ceil(file_size / 24) is therefore a
    // conservative upper bound on the number of entries that gix can scan while
    // validating any supported valid index. The path-based mmap API assumes pack
    // indexes are immutable; the length check below catches replacement around the
    // open, but cannot make mutation of an already-mapped index safe.
    let validation_entries = index_bytes.div_ceil(MIN_PACK_INDEX_BYTES_PER_ENTRY);
    budget.charge_index_entries(validation_entries)?;
    budget.charge_source_open(1)?;
    let index =
        gix_pack::index::File::at(index_path, repo.object_hash()).map_err(Error::from_index)?;

    budget.charge_source_open(1)?;
    let observed_bytes = std::fs::metadata(index_path)
        .map_err(|error| {
            Error::storage(format!(
                "reinspect pack index {}: {error}",
                index_path.display()
            ))
        })?
        .len();
    if observed_bytes != index_bytes {
        return Err(Error::corrupt(format!(
            "pack index {} changed size while opening: {index_bytes} to {observed_bytes}",
            index_path.display()
        )));
    }
    if u64::from(index.num_objects()) > validation_entries {
        return Err(Error::corrupt(format!(
            "pack index {} declared {} objects beyond the charged validation bound {validation_entries}",
            index_path.display(),
            index.num_objects()
        )));
    }
    Ok(index)
}

fn open_pack_data(
    repo: &gix::Repository,
    index_path: &Path,
    budget: &DecodeWorkBudget,
) -> DecodeResult<gix_pack::data::File> {
    budget.charge_source_open(1)?;
    gix_pack::data::File::at(index_path.with_extension("pack"), repo.object_hash())
        .map_err(Error::from_pack)
}

fn open_packed(
    repo: &gix::Repository,
    source: &ObjectSource,
    budget: &DecodeWorkBudget,
) -> DecodeResult<OpenedPack> {
    let ObjectSource::Packed {
        index_path,
        pack_offset,
    } = source
    else {
        return Err(Error::corrupt(
            "attempted to open a loose object as a pack entry",
        ));
    };
    let index = open_pack_index(repo, index_path, budget)?;
    let pack = open_pack_data(repo, index_path, budget)?;
    let mut offset_occurrences = 0_usize;
    let mut next_offset = None;
    for candidate in index.iter() {
        budget.charge_index_entries(1)?;
        if candidate.pack_offset == *pack_offset {
            offset_occurrences += 1;
        } else if candidate.pack_offset > *pack_offset {
            next_offset = Some(next_offset.map_or(candidate.pack_offset, |current: u64| {
                current.min(candidate.pack_offset)
            }));
        }
    }
    if offset_occurrences != 1 {
        return Err(Error::corrupt(format!(
            "pack offset {pack_offset} occurs {offset_occurrences} times in {}",
            index_path.display(),
        )));
    }
    let entry_end = next_offset.unwrap_or(pack.pack_end() as u64);
    opened_pack_from_parts(source, pack, Some(index), entry_end)
}

fn open_guarded_packed(
    repo: &gix::Repository,
    source: &ObjectSource,
    guarded: &GuardedMetadata,
    budget: &DecodeWorkBudget,
) -> DecodeResult<OpenedPack> {
    let ObjectSource::Packed { index_path, .. } = source else {
        return Err(Error::corrupt(
            "attempted to open a loose object as a guarded pack entry",
        ));
    };
    let entry_end = guarded.pack_entry_end(source)?;
    let pack = open_pack_data(repo, index_path, budget)?;
    opened_pack_from_parts(source, pack, None, entry_end)
}

fn opened_pack_from_parts(
    source: &ObjectSource,
    pack: gix_pack::data::File,
    index: Option<gix_pack::index::File>,
    entry_end: gix_pack::data::Offset,
) -> DecodeResult<OpenedPack> {
    let ObjectSource::Packed { pack_offset, .. } = source else {
        return Err(Error::corrupt(
            "attempted to validate a loose object as a pack entry",
        ));
    };
    let entry = pack.entry(*pack_offset).map_err(Error::corrupt)?;
    if *pack_offset >= entry.data_offset
        || entry.data_offset >= entry_end
        || entry_end > pack.pack_end() as u64
    {
        return Err(Error::corrupt(format!(
            "invalid pack entry range {}..{entry_end} at offset {pack_offset}",
            entry.data_offset
        )));
    }
    Ok(OpenedPack {
        pack,
        index,
        entry,
        entry_end,
    })
}

fn probe_guarded_source(
    repo: &gix::Repository,
    source: &ObjectSource,
    tracker: &mut AllocationTracker,
    budget: &DecodeWorkBudget,
) -> DecodeResult<GuardedMetadata> {
    let mut delta_bases = Vec::new();
    let mut pack_entries = Vec::new();
    let object = probe_source(
        repo,
        source,
        tracker,
        &mut Vec::new(),
        &mut delta_bases,
        &mut pack_entries,
        budget,
    )?;
    Ok(GuardedMetadata {
        object,
        delta_bases,
        pack_entries,
    })
}

fn probe_source(
    repo: &gix::Repository,
    source: &ObjectSource,
    tracker: &mut AllocationTracker,
    stack: &mut Vec<ObjectSource>,
    delta_bases: &mut Vec<VerifiedDeltaBase>,
    pack_entries: &mut Vec<VerifiedPackEntry>,
    budget: &DecodeWorkBudget,
) -> DecodeResult<ObjectMetadata> {
    enter_source(source, stack)?;
    let result = match source {
        ObjectSource::Loose { object_db, id } => {
            let path = loose_object_path_at(object_db, *id);
            budget.charge_source_open(1)?;
            let file = File::open(&path).map_err(|error| {
                Error::storage(format!("open loose object {}: {error}", path.display()))
            })?;
            let mut stream = InflatedStream::from_file(file, tracker, BufferRole::Metadata)?;
            read_loose_header(&mut stream, budget)
        }
        ObjectSource::Packed { .. } => {
            let opened = open_packed(repo, source, budget)?;
            let entry_end = opened.entry_end;
            let packed_result = if let Some(kind) = opened.entry.header.as_kind() {
                Ok(ObjectMetadata {
                    kind,
                    size: opened.entry.decompressed_size,
                })
            } else {
                let ref_base_id = match opened.entry.header {
                    gix_pack::data::entry::Header::RefDelta { base_id } => Some(base_id),
                    _ => None,
                };
                let base = resolve_delta_base(repo, source, &opened, budget)?;
                let base_metadata = probe_source(
                    repo,
                    &base,
                    tracker,
                    stack,
                    delta_bases,
                    pack_entries,
                    budget,
                )?;
                let compressed = opened.compressed()?;
                let mut stream = InflatedStream::from_slice(
                    compressed,
                    opened.entry.decompressed_size,
                    tracker,
                    BufferRole::Metadata,
                )?;
                let (declared_base_size, result_size) = read_delta_header(&mut stream, budget)?;
                if declared_base_size != base_metadata.size {
                    return pop_result(
                        stack,
                        Err(Error::corrupt(format!(
                            "delta declares base size {declared_base_size}, resolved base has size {}",
                            base_metadata.size
                        ))),
                    );
                }
                delta_bases.push(VerifiedDeltaBase {
                    delta: source.clone(),
                    base,
                    metadata: base_metadata,
                    ref_base_id,
                });
                Ok(ObjectMetadata {
                    kind: base_metadata.kind,
                    size: result_size,
                })
            };
            if packed_result.is_ok() {
                pack_entries.push(VerifiedPackEntry {
                    source: source.clone(),
                    entry_end,
                });
            }
            packed_result
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
    guarded: &GuardedMetadata,
    budget: &DecodeWorkBudget,
) -> DecodeResult<()> {
    let mut sink = RetainedSink { output };
    append_source_range_to_sink(
        repo, source, expected, start, length, &mut sink, tracker, stack, guarded, budget,
    )
}

#[allow(clippy::too_many_arguments)]
fn append_source_range_to_sink<S>(
    repo: &gix::Repository,
    source: &ObjectSource,
    expected: ObjectMetadata,
    start: u64,
    length: usize,
    output: &mut S,
    tracker: &mut AllocationTracker,
    stack: &mut Vec<ObjectSource>,
    guarded: &GuardedMetadata,
    budget: &DecodeWorkBudget,
) -> DecodeResult<()>
where
    S: DecodeSink + ?Sized,
{
    let end = start
        .checked_add(length as u64)
        .ok_or_else(|| Error::corrupt("requested object range overflow"))?;
    if end > expected.size {
        return Err(Error::corrupt(format!(
            "requested object range {start}..{end} exceeds size {}",
            expected.size
        )));
    }

    enter_source(source, stack)?;
    let output_start = output.position();
    let role = if stack.len() == 1 {
        BufferRole::DecodedObject
    } else {
        BufferRole::DecodedBase
    };
    let result = match source {
        ObjectSource::Loose { object_db, id } => {
            let path = loose_object_path_at(object_db, *id);
            budget.charge_source_open(1)?;
            let file = File::open(&path).map_err(|error| {
                Error::storage(format!("open loose object {}: {error}", path.display()))
            })?;
            let mut stream = InflatedStream::from_file(file, tracker, role)?;
            let actual = read_loose_header(&mut stream, budget)?;
            ensure_metadata(expected, actual)?;
            stream.skip_exact(start, budget)?;
            stream.append_exact(length as u64, output, budget)?;
            if end == expected.size {
                stream.finish_exact(budget)?;
            }
            Ok(())
        }
        ObjectSource::Packed { .. } => {
            let opened = open_guarded_packed(repo, source, guarded, budget)?;
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
                stream.skip_exact(start, budget)?;
                stream.append_exact(length as u64, output, budget)?;
                if end == expected.size {
                    stream.finish_exact(budget)?;
                }
                Ok(())
            } else {
                append_delta_range(
                    repo, source, &opened, expected, start, end, output, tracker, stack, guarded,
                    budget,
                )
            }
        }
    };

    let result = result.and_then(|()| {
        let appended = output
            .position()
            .checked_sub(output_start)
            .ok_or_else(|| Error::corrupt("decoder output position moved backwards"))?;
        if appended != length as u64 {
            Err(Error::corrupt(format!(
                "decoder appended {appended} bytes for a {length}-byte request"
            )))
        } else {
            Ok(())
        }
    });
    pop_result(stack, result)
}

#[allow(clippy::too_many_arguments)]
fn append_delta_range<S>(
    repo: &gix::Repository,
    source: &ObjectSource,
    opened: &OpenedPack,
    expected: ObjectMetadata,
    start: u64,
    end: u64,
    output: &mut S,
    tracker: &mut AllocationTracker,
    stack: &mut Vec<ObjectSource>,
    guarded: &GuardedMetadata,
    budget: &DecodeWorkBudget,
) -> DecodeResult<()>
where
    S: DecodeSink + ?Sized,
{
    let verified_base = guarded.delta_base(source)?;
    let base = &verified_base.base;
    let base_metadata = verified_base.metadata;
    let compressed = opened.compressed()?;
    let mut stream = InflatedStream::from_slice(
        compressed,
        opened.entry.decompressed_size,
        tracker,
        BufferRole::Delta,
    )?;
    let (declared_base_size, result_size) = read_delta_header(&mut stream, budget)?;
    if declared_base_size != base_metadata.size {
        return Err(Error::corrupt(format!(
            "delta declares base size {declared_base_size}, resolved base has size {}",
            base_metadata.size
        )));
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
        budget.charge_delta_instruction()?;
        let opcode = stream.read_required_byte(budget)?;
        let instruction =
            decode_delta_instruction(opcode, &mut || stream.read_required_byte(budget))?;
        let instruction_size = match instruction {
            DeltaInstruction::Insert { size } | DeltaInstruction::Copy { size, .. } => size,
        };
        let instruction_end = result_position
            .checked_add(instruction_size)
            .ok_or_else(|| Error::corrupt("delta result position overflow"))?;
        if instruction_end > result_size {
            return Err(Error::corrupt(format!(
                "delta command ends at {instruction_end}, beyond result size {result_size}"
            )));
        }

        match &instruction {
            DeltaInstruction::Insert { size } => {
                if instruction_end <= start {
                    stream.skip_exact(*size, budget)?;
                } else {
                    let overlap_start = result_position.max(start);
                    let overlap_end = instruction_end.min(end);
                    stream.skip_exact(overlap_start - result_position, budget)?;
                    stream.append_exact(overlap_end - overlap_start, output, budget)?;
                }
            }
            DeltaInstruction::Copy { offset, size } => {
                let base_end = offset
                    .checked_add(*size)
                    .ok_or_else(|| Error::corrupt("delta base copy range overflow"))?;
                if base_end > base_metadata.size {
                    return Err(Error::corrupt(format!(
                        "delta copy range {offset}..{base_end} exceeds base size {}",
                        base_metadata.size
                    )));
                }
                if let Some(base_range) =
                    overlapping_base_range(&instruction, result_position, requested.clone())?
                {
                    let length = usize::try_from(base_range.end - base_range.start)
                        .map_err(|_| Error::corrupt("delta copy length does not fit usize"))?;
                    append_source_range_to_sink(
                        repo,
                        base,
                        base_metadata,
                        base_range.start,
                        length,
                        output,
                        tracker,
                        stack,
                        guarded,
                        budget,
                    )?;
                }
            }
        }
        result_position = instruction_end;
    }

    if stream.is_ended() && result_position < result_size {
        return Err(Error::corrupt(format!(
            "delta stream reached StreamEnd at result offset {result_position}, expected {result_size}"
        )));
    }
    if end == result_size {
        if result_position != result_size {
            return Err(Error::corrupt(format!(
                "delta result ended at {result_position}, expected {result_size}"
            )));
        }
        stream.finish_exact(budget)?;
    }
    Ok(())
}

fn resolve_delta_base(
    repo: &gix::Repository,
    source: &ObjectSource,
    opened: &OpenedPack,
    budget: &DecodeWorkBudget,
) -> DecodeResult<ObjectSource> {
    let ObjectSource::Packed {
        index_path,
        pack_offset,
    } = source
    else {
        return Err(Error::corrupt(
            "a loose object cannot have a pack delta base",
        ));
    };
    match opened.entry.header {
        gix_pack::data::entry::Header::OfsDelta { base_distance } => {
            let base_pack_offset = gix_pack::data::entry::Header::verified_base_pack_offset(
                *pack_offset,
                base_distance,
            )
            .ok_or_else(|| {
                Error::corrupt(format!(
                    "invalid OFS_DELTA distance {base_distance} from pack offset {pack_offset}"
                ))
            })?;
            Ok(ObjectSource::Packed {
                index_path: index_path.clone(),
                pack_offset: base_pack_offset,
            })
        }
        gix_pack::data::entry::Header::RefDelta { base_id } => {
            budget.charge_index_entries(1)?;
            let index = opened.index()?;
            if let Some(entry_index) = index.lookup(base_id) {
                return Ok(ObjectSource::Packed {
                    index_path: index_path.clone(),
                    pack_offset: index.pack_offset_at_index(entry_index),
                });
            }
            locate_source(repo, base_id, Some(index_path), budget)
        }
        _ => Err(Error::corrupt(
            "attempted to resolve a base for a non-delta pack entry",
        )),
    }
}

fn read_delta_header(
    stream: &mut InflatedStream<'_>,
    budget: &DecodeWorkBudget,
) -> DecodeResult<(u64, u64)> {
    let base_size = decode_delta_varint(&mut || stream.read_required_byte(budget))?;
    let result_size = decode_delta_varint(&mut || stream.read_required_byte(budget))?;
    Ok((base_size, result_size))
}

fn read_loose_header(
    stream: &mut InflatedStream<'_>,
    budget: &DecodeWorkBudget,
) -> DecodeResult<ObjectMetadata> {
    let mut kind_code = 0_u64;
    let mut kind_length = 0_usize;
    loop {
        let byte = stream.read_required_byte(budget)?;
        if byte == b' ' {
            break;
        }
        if kind_length == 6 || !byte.is_ascii_lowercase() {
            return Err(Error::corrupt("invalid loose object kind"));
        }
        kind_code = (kind_code << 8) | u64::from(byte);
        kind_length += 1;
    }
    let kind = match (kind_length, kind_code) {
        (4, 0x626c_6f62) => gix_object::Kind::Blob,
        (4, 0x7472_6565) => gix_object::Kind::Tree,
        (6, 0x636f_6d6d_6974) => gix_object::Kind::Commit,
        (3, 0x0074_6167) => gix_object::Kind::Tag,
        _ => return Err(Error::corrupt("unsupported loose object kind")),
    };

    let mut size = 0_u64;
    let mut digit_count = 0_usize;
    let mut first_digit = 0_u8;
    loop {
        let byte = stream.read_required_byte(budget)?;
        if byte == 0 {
            break;
        }
        if !byte.is_ascii_digit() || digit_count == 20 {
            return Err(Error::corrupt("invalid loose object size"));
        }
        if digit_count == 0 {
            first_digit = byte;
        }
        size = size
            .checked_mul(10)
            .and_then(|value| value.checked_add(u64::from(byte - b'0')))
            .ok_or_else(|| Error::corrupt("loose object size overflow"))?;
        digit_count += 1;
    }
    if digit_count == 0 || (digit_count > 1 && first_digit == b'0') {
        return Err(Error::corrupt("loose object size is not canonical"));
    }

    let header_size = kind_length
        .checked_add(digit_count)
        .and_then(|value| value.checked_add(2))
        .ok_or_else(|| Error::corrupt("loose object header size overflow"))?
        as u64;
    stream.set_declared_size(
        header_size
            .checked_add(size)
            .ok_or_else(|| Error::corrupt("loose object total size overflow"))?,
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

fn pop_result<T, E>(stack: &mut Vec<ObjectSource>, result: Result<T, E>) -> Result<T, E> {
    stack.pop();
    result
}

fn loose_object_path_at(object_db: &Path, id: gix_hash::ObjectId) -> PathBuf {
    let oid = id.to_string();
    object_db.join(Path::new(&oid[..2])).join(&oid[2..])
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::collections::BTreeMap;
    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::rc::Rc;
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::{
        AllocationTracker, DecodeWorkBudget, DecodeWorkLimits, DeltaInstruction, Error, ErrorKind,
        GuardedMetadata, MAX_CHAIN_DEPTH, MAX_INFLATED_OUTPUT_BYTES,
        MAX_VISITOR_COMPRESSED_INPUT_BYTES, MAX_VISITOR_INFLATED_OUTPUT_BYTES,
        METADATA_BUFFER_LIMIT, MIB, ObjectMetadata, ObjectSource, PUBLIC_HEADER_OUTPUT_LIMIT,
        STREAM_BUFFER_TARGET, VerifiedDeltaBase, VerifiedPackEntry, VisitOutcome,
        append_source_range, decode_delta_instruction, decode_delta_varint, enter_source,
        locate_source, loose_object_path_at, opened_pack_from_parts, overlapping_base_range,
        pack_index_paths, parse_alternate_paths, probe_guarded_source,
        public_metadata_for_opened_pack, read_object_prefix, read_prefix, resolve_alternate_path,
        validate_local_metadata_before_public_header, visit_verified_blob,
        visit_verified_blob_instrumented,
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
    fn prefix_object_reads_a_large_non_blob_without_materializing_it() {
        let temp = TempDirectory::new("large-tag-object");
        let repo_path = temp.0.join("large-tag.git");
        git(
            &[
                "init",
                "--bare",
                "--object-format=sha1",
                path_str(&repo_path),
            ],
            None,
        );

        let mut original =
            b"object 0000000000000000000000000000000000000000\ntype commit\ntag large\n\n".to_vec();
        original.extend(std::iter::repeat_n(b'x', 3 * 1024 * 1024));
        let oid_text = git(
            &[
                "--git-dir",
                path_str(&repo_path),
                "hash-object",
                "--literally",
                "-t",
                "tag",
                "-w",
                "--stdin",
            ],
            Some(&original),
        );
        let repo = gix::open(&repo_path).expect("open large tag fixture");
        let prefix = read_object_prefix(&repo, parse_oid(&oid_text), 128)
            .expect("read bounded non-blob prefix");

        assert_eq!(prefix.kind, gix_object::Kind::Tag);
        assert_eq!(prefix.size, original.len() as u64);
        assert_eq!(prefix.data, original[..128]);
        assert!(prefix.truncated);
        assert!(prefix.allocations.max_decoded_object_buffer <= 128);
        assert!(prefix.allocations.max_intermediate_object_buffer < original.len());
    }

    #[test]
    fn prefix_blob_dangling_unrelated_alternate_does_not_block_primary_loose_object() {
        let fixture = loose_fixture();
        let alternates_path = fixture.repo_path.join("objects/info/alternates");
        let missing_object_db = fixture.repo_path.join("missing.git/objects");
        std::fs::write(
            &alternates_path,
            format!("{}\n", missing_object_db.display()),
        )
        .expect("write dangling alternate");
        let repo = gix::open(&fixture.repo_path).expect("open fixture repository");

        let prefix = read_prefix(&repo, fixture.oid, PREFIX_LIMIT)
            .expect("a dangling unrelated alternate must not block a primary loose object");

        assert_eq!(prefix.size, fixture.original.len() as u64);
        assert_eq!(prefix.data, fixture.original[..PREFIX_LIMIT]);
        assert!(prefix.truncated);
    }

    #[cfg(unix)]
    #[test]
    fn prefix_blob_alternate_symlink_loop_is_corruption() {
        use std::os::unix::fs::symlink;

        let temp = TempDirectory::new("alternate-symlink-loop");
        let first = temp.0.join("first");
        let second = temp.0.join("second");
        symlink(&second, &first).expect("create first symlink");
        symlink(&first, &second).expect("create second symlink");

        let error = resolve_alternate_path(&first, &temp.0)
            .expect_err("a symlink loop must fail alternate resolution");

        assert_eq!(error.kind(), ErrorKind::CorruptRepository);
        assert!(error.to_string().contains("maximum allowed number"));
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
    fn verified_blob_visitor_streams_every_storage_form_in_eight_kib_chunks() {
        for fixture in [
            loose_fixture(),
            alternate_loose_fixture(),
            packed_base_fixture(),
            packed_delta_fixture(),
            packed_ref_delta_fixture(),
        ] {
            let repo = gix::open(&fixture.repo_path).expect("open streaming fixture");
            let mut visited = 0_u64;
            let mut max_chunk = 0_usize;
            let mut visitor = |chunk: &[u8]| {
                assert!(!chunk.is_empty());
                visited += chunk.len() as u64;
                max_chunk = max_chunk.max(chunk.len());
            };

            let outcome = visit_verified_blob(
                &repo,
                fixture.oid,
                fixture.original.len() as u64,
                || false,
                &mut visitor,
            )
            .expect("stream and verify complete blob");

            assert_eq!(
                outcome,
                VisitOutcome::Complete {
                    size: fixture.original.len() as u64
                },
                "{}",
                fixture.evidence
            );
            assert_eq!(visited, fixture.original.len() as u64);
            assert!(max_chunk <= STREAM_BUFFER_TARGET);
        }
    }

    #[test]
    fn verified_blob_visitor_preflights_size_and_retains_only_bounded_buffers() {
        let fixture = packed_delta_fixture();
        let repo = gix::open(&fixture.repo_path).expect("open streaming fixture");
        let mut too_large_calls = 0_usize;
        let too_large = visit_verified_blob(
            &repo,
            fixture.oid,
            fixture.original.len() as u64 - 1,
            || false,
            &mut |_| too_large_calls += 1,
        )
        .expect("preflight oversized blob");

        assert_eq!(
            too_large,
            VisitOutcome::TooLarge {
                size: fixture.original.len() as u64
            }
        );
        assert_eq!(too_large_calls, 0, "oversized bodies must not be visited");

        let mut visited = 0_u64;
        let (complete, allocations) = visit_verified_blob_instrumented(
            &repo,
            fixture.oid,
            fixture.original.len() as u64,
            || false,
            &mut |chunk: &[u8]| visited += chunk.len() as u64,
        )
        .expect("visit exact-size packed delta");

        assert_eq!(
            complete,
            VisitOutcome::Complete {
                size: fixture.original.len() as u64
            }
        );
        assert_eq!(visited, fixture.original.len() as u64);
        assert_eq!(allocations.content_bytes_allocated_before_header, 0);
        assert!(allocations.max_metadata_buffer <= METADATA_BUFFER_LIMIT);
        for allocation in [
            allocations.max_intermediate_object_buffer,
            allocations.max_decoded_object_buffer,
            allocations.max_decoded_base_buffer,
            allocations.max_delta_buffer,
            allocations.max_work_buffer,
        ] {
            assert!(
                allocation <= STREAM_BUFFER_TARGET,
                "streaming visitor retained a {allocation}-byte content buffer"
            );
            assert!(allocation < fixture.original.len());
        }
        assert!(allocations.source_opens > 0);
        assert!(allocations.index_entries_scanned > 0);
        assert!(allocations.delta_instructions > 0);
        assert!(allocations.compressed_input_bytes > 0);
        assert!(allocations.inflated_output_bytes > 0);
    }

    #[test]
    fn verified_blob_visitor_rejects_large_loose_size_before_public_file_charge() {
        let temp = TempDirectory::new("sparse-oversized-loose");
        let repo_path = temp.0.join("sparse-oversized-loose.git");
        git(
            &[
                "init",
                "--bare",
                "--object-format=sha1",
                path_str(&repo_path),
            ],
            None,
        );
        let fake_oid = parse_oid("2222222222222222222222222222222222222222");
        let object_path = loose_object_path_at(&repo_path.join("objects"), fake_oid);
        std::fs::create_dir_all(object_path.parent().expect("fake loose parent"))
            .expect("create fake loose parent");
        let mut object = std::fs::File::create(&object_path).expect("create sparse loose object");
        object
            .write_all(&zlib(b"blob 10\0x"))
            .expect("write loose object prefix");
        let sparse_size = super::MAX_COMPRESSED_INPUT_BYTES + 1;
        object
            .set_len(sparse_size)
            .expect("extend sparse loose object");
        drop(object);
        let repo = gix::open(&repo_path).expect("open sparse loose repository");

        for max_size in [0, 1] {
            let mut visitor_calls = 0_usize;
            let (outcome, allocations) =
                visit_verified_blob_instrumented(&repo, fake_oid, max_size, || false, &mut |_| {
                    visitor_calls += 1
                })
                .expect("declared size must stop before whole-file public-header work");

            assert_eq!(outcome, VisitOutcome::TooLarge { size: 10 });
            assert_eq!(visitor_calls, 0);
            assert!(
                allocations.compressed_input_bytes < sparse_size,
                "oversized preflight charged the complete sparse loose file"
            );
        }
    }

    #[test]
    fn verified_blob_visitor_honors_an_immediate_stop_before_body_work() {
        for fixture in [
            loose_fixture(),
            alternate_loose_fixture(),
            packed_base_fixture(),
            packed_delta_fixture(),
            packed_ref_delta_fixture(),
        ] {
            let repo = gix::open(&fixture.repo_path).expect("open immediate-stop fixture");
            let mut visitor_calls = 0_usize;
            let outcome = visit_verified_blob(
                &repo,
                fixture.oid,
                fixture.original.len() as u64,
                || true,
                &mut |_| visitor_calls += 1,
            )
            .expect("immediate cooperative stop");

            assert_eq!(
                outcome,
                VisitOutcome::Stopped {
                    bytes: 0,
                    started: false
                }
            );
            assert_eq!(visitor_calls, 0);
        }
    }

    #[test]
    fn verified_blob_visitor_never_marks_zero_emitted_bytes_as_started() {
        let fixture = loose_fixture();
        let repo = gix::open(&fixture.repo_path).expect("open call-count stop fixture");
        let stop_calls = Rc::new(Cell::new(0_usize));
        let stop_counter = Rc::clone(&stop_calls);
        let mut visitor_calls = 0_usize;

        let outcome = visit_verified_blob(
            &repo,
            fixture.oid,
            fixture.original.len() as u64,
            move || {
                let call = stop_counter.get() + 1;
                stop_counter.set(call);
                call == 2
            },
            &mut |_| visitor_calls += 1,
        )
        .expect("second cooperative checkpoint stops cleanly");

        assert_eq!(stop_calls.get(), 2);
        assert_eq!(visitor_calls, 0);
        assert_eq!(
            outcome,
            VisitOutcome::Stopped {
                bytes: 0,
                started: false
            }
        );
    }

    #[test]
    fn verified_blob_visitor_stops_inside_repeated_high_offset_delta_copies() {
        let fixture = repeated_high_offset_copy_fixture(4);
        let repo = gix::open(&fixture.repo_path).expect("open high-offset fixture");
        let visited = Rc::new(Cell::new(0_u64));
        let stop_at = Rc::clone(&visited);
        let visitor_count = Rc::clone(&visited);

        let outcome = visit_verified_blob(
            &repo,
            fixture.oid,
            fixture.original.len() as u64,
            move || stop_at.get() != 0,
            &mut move |chunk: &[u8]| {
                visitor_count.set(visitor_count.get() + chunk.len() as u64);
            },
        )
        .expect("stop cooperatively during a high-offset COPY program");

        assert_eq!(
            outcome,
            VisitOutcome::Stopped {
                bytes: 1,
                started: true
            }
        );
        assert_eq!(visited.get(), 1);
        assert!(visited.get() < fixture.original.len() as u64);
    }

    #[test]
    fn streaming_budget_accepts_the_exact_analysis_maximum_and_remains_finite() {
        let body = 512 * MIB;
        let header = b"blob 536870912\0".len() as u64;
        let budget =
            DecodeWorkBudget::with_stop_hook(super::BLOB_METADATA_WORK_LIMIT, body, || false)
                .expect("visitor work budget");

        budget
            .charge_inflated_output(header)
            .expect("local metadata header");
        budget
            .charge_inflated_output(PUBLIC_HEADER_OUTPUT_LIMIT)
            .expect("public metadata header");
        budget
            .charge_inflated_output(header)
            .expect("body reopen header");
        budget
            .charge_inflated_output(body)
            .expect("exact 512 MiB body");
        assert!(budget.inflated_output_bytes.get() > MAX_INFLATED_OUTPUT_BYTES);
        let inflated_remainder =
            MAX_VISITOR_INFLATED_OUTPUT_BYTES - budget.inflated_output_bytes.get();
        budget
            .charge_inflated_output(inflated_remainder)
            .expect("finite inflated visitor reserve");
        assert!(budget.charge_inflated_output(1).is_err());

        budget
            .charge_compressed_input(body)
            .expect("guarded compressed object");
        budget
            .charge_compressed_input(body)
            .expect("streamed compressed object");
        let compressed_remainder =
            MAX_VISITOR_COMPRESSED_INPUT_BYTES - budget.compressed_input_bytes.get();
        budget
            .charge_compressed_input(compressed_remainder)
            .expect("finite compressed visitor reserve");
        assert!(budget.charge_compressed_input(1).is_err());
    }

    #[test]
    fn verified_blob_visitor_stops_mid_file_without_finalizing_a_false_oid() {
        let fixture = loose_fixture();
        let fake_oid = parse_oid("1111111111111111111111111111111111111111");
        let object_db = fixture.repo_path.join("objects");
        let source = loose_object_path_at(&object_db, fixture.oid);
        let target = loose_object_path_at(&object_db, fake_oid);
        std::fs::create_dir_all(target.parent().expect("fake loose parent"))
            .expect("create fake loose parent");
        std::fs::copy(source, target).expect("alias loose blob under false oid");
        let repo = gix::open(&fixture.repo_path).expect("open false-oid fixture");
        let visited = Rc::new(Cell::new(0_u64));
        let stop_at = Rc::clone(&visited);
        let visitor_count = Rc::clone(&visited);
        let mut visitor = move |chunk: &[u8]| {
            visitor_count.set(visitor_count.get() + chunk.len() as u64);
        };

        let outcome = visit_verified_blob(
            &repo,
            fake_oid,
            fixture.original.len() as u64,
            move || stop_at.get() != 0,
            &mut visitor,
        )
        .expect("cooperative stop is not corruption");

        assert_eq!(
            outcome,
            VisitOutcome::Stopped {
                bytes: visited.get(),
                started: true
            }
        );
        assert!(visited.get() > 0);
        assert!(visited.get() < fixture.original.len() as u64);

        let error = visit_verified_blob(
            &repo,
            fake_oid,
            fixture.original.len() as u64,
            || false,
            &mut |_| {},
        )
        .expect_err("a complete visit must compare the physical blob oid");
        assert_eq!(error.kind(), ErrorKind::CorruptRepository);
        assert!(error.to_string().contains("checksum mismatch"));
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
        assert!(prefix.allocations.max_metadata_buffer > 0);
        assert!(prefix.allocations.max_metadata_buffer <= METADATA_BUFFER_LIMIT);
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
    fn prefix_blob_repeated_high_offset_copies_stop_at_the_cumulative_work_budget() {
        let fixture = repeated_high_offset_copy_fixture(256);
        let repo = gix::open(&fixture.repo_path).expect("open fixture repository");

        let error = read_prefix(&repo, fixture.oid, fixture.original.len())
            .expect_err("repeated high-offset copies must exhaust bounded decode work");

        assert_eq!(error.kind(), ErrorKind::CorruptRepository);
        assert_eq!(
            error.to_string(),
            "decode work budget exhausted: delta instructions 145 exceed limit 144"
        );
    }

    #[test]
    fn prefix_blob_index_validation_work_is_counted_without_copy_rescans() {
        let counts = [1, 64].map(|copy_count| {
            let fixture = repeated_high_offset_copy_fixture(copy_count);
            let repo = gix::open(&fixture.repo_path).expect("open fixture repository");
            let prefix = read_prefix(&repo, fixture.oid, fixture.original.len())
                .expect("bounded repeated-copy prefix");
            let index_paths = pack_index_paths_for_test(&fixture.repo_path);
            let [index_path] = index_paths.as_slice() else {
                panic!("expected one synthetic pack index");
            };
            let index_bytes = std::fs::metadata(index_path)
                .expect("synthetic pack index metadata")
                .len();
            let conservative_validation_charge = index_bytes.div_ceil(24);

            assert!(
                prefix.allocations.index_entries_scanned >= conservative_validation_charge * 3,
                "every locate and preflight index validation must be charged"
            );
            prefix.allocations.index_entries_scanned
        });

        assert_eq!(
            counts[0], counts[1],
            "repeated COPY content reads must not reopen or rescan the pack index"
        );
    }

    #[test]
    fn prefix_blob_guarded_content_does_not_reopen_index_after_preflight() {
        let fixture = repeated_high_offset_copy_fixture(4);
        let repo = gix::open(&fixture.repo_path).expect("open fixture repository");
        let budget = DecodeWorkBudget::new(fixture.original.len()).expect("work budget");
        let source = locate_source(&repo, fixture.oid, None, &budget).expect("locate source");
        let mut tracker = AllocationTracker::new(fixture.original.len());
        let guarded = probe_guarded_source(&repo, &source, &mut tracker, &budget)
            .expect("preflight physical pack sources");
        let index_paths = pack_index_paths_for_test(&fixture.repo_path);
        let [index_path] = index_paths.as_slice() else {
            panic!("expected one synthetic pack index");
        };
        std::fs::rename(index_path, index_path.with_extension("idx.hidden"))
            .expect("hide index after preflight");
        let mut output = Vec::with_capacity(fixture.original.len());

        append_source_range(
            &repo,
            &source,
            guarded.object,
            0,
            fixture.original.len(),
            &mut output,
            &mut tracker,
            &mut Vec::new(),
            &guarded,
            &budget,
        )
        .expect("guarded content reads must use only the already-bound pack data");

        assert_eq!(output, fixture.original);
    }

    #[test]
    fn prefix_blob_public_header_does_not_inflate_past_guarded_entry() {
        let temp = TempDirectory::new("cross-entry-public-header");
        let index_path = temp.0.join("malformed.idx");
        let pack_path = index_path.with_extension("pack");
        let base_id = gix_hash::ObjectId::from_bytes_or_panic(&[0x42; 20]);
        let decoded_delta: Vec<u8> = [1_u8, 1]
            .into_iter()
            .chain(std::iter::repeat_n(0, 18))
            .collect();

        // One non-final stored block produces the two delta-header varints and seven
        // payload bytes inside the guarded entry. The remaining eleven bytes, final
        // block header, and checksum fit exactly in the SHA-1-sized following region.
        let mut compressed = vec![0x78, 0x01, 0x00, 0x09, 0x00, 0xf6, 0xff];
        compressed.extend(&decoded_delta[..9]);
        let guarded_compressed_len = compressed.len();
        compressed.extend([0x01, 0x0b, 0x00, 0xf4, 0xff]);
        compressed.extend(&decoded_delta[9..]);
        compressed.extend(adler32(&decoded_delta).to_be_bytes());

        let mut pack = b"PACK".to_vec();
        pack.extend(2_u32.to_be_bytes());
        pack.extend(2_u32.to_be_bytes());
        let pack_offset = pack.len() as u64;
        pack.extend(encode_pack_entry_header(7, decoded_delta.len()));
        pack.extend(base_id.as_slice());
        let data_offset = pack.len() as u64;
        pack.extend(compressed);
        pack.extend([0_u8; 20]);
        std::fs::write(&pack_path, pack).expect("write malformed cross-entry pack");

        let source = ObjectSource::Packed {
            index_path,
            pack_offset,
        };
        let entry_end = data_offset + guarded_compressed_len as u64;
        let pack = gix_pack::data::File::at(&pack_path, gix_hash::Kind::Sha1)
            .expect("open malformed fixture pack");
        let opened = opened_pack_from_parts(&source, pack, None, entry_end)
            .expect("open guarded malformed entry");
        let base = ObjectSource::Loose {
            object_db: temp.0.join("unused-base"),
            id: base_id,
        };
        let guarded = GuardedMetadata {
            object: ObjectMetadata {
                kind: gix_object::Kind::Blob,
                size: 1,
            },
            delta_bases: vec![VerifiedDeltaBase {
                delta: source.clone(),
                base,
                metadata: ObjectMetadata {
                    kind: gix_object::Kind::Blob,
                    size: 1,
                },
                ref_base_id: Some(base_id),
            }],
            pack_entries: vec![VerifiedPackEntry { source, entry_end }],
        };

        let resolve = |_base_id: &gix_hash::oid| {
            Some(gix_pack::data::decode::header::ResolvedBase::OutOfPack {
                kind: gix_object::Kind::Blob,
                num_deltas: None,
            })
        };
        let unbounded = opened
            .pack
            .decode_header(
                opened.entry.clone(),
                &mut gix_features::zlib::Inflate::default(),
                &resolve,
            )
            .expect("the unbounded gix suffix crosses the forged entry boundary");
        assert_eq!(unbounded.object_size, 1);
        let budget = DecodeWorkBudget::new(PREFIX_LIMIT).expect("work budget");

        let error = public_metadata_for_opened_pack(&opened, &guarded, &budget)
            .expect_err("public corroboration must reject cross-entry deflate continuation");

        assert_eq!(error.kind(), ErrorKind::CorruptRepository);
        assert!(
            error
                .to_string()
                .contains("pack entry decompressed to more bytes than declared"),
            "the bounded public view must reach the gix truncated-stream rejection: {error}"
        );
        let work = budget.instrumentation();
        assert_eq!(
            work.compressed_input_bytes, guarded_compressed_len as u64,
            "public gix input must be capped and charged exactly at entry_end"
        );
        assert_eq!(work.inflated_output_bytes, PUBLIC_HEADER_OUTPUT_LIMIT);
    }

    #[test]
    fn prefix_blob_alternate_discovery_rejects_excessive_recursion() {
        let temp = TempDirectory::new("bounded-alternates");
        let repo_path = temp.0.join("primary.git");
        git(
            &[
                "init",
                "--bare",
                "--object-format=sha1",
                path_str(&repo_path),
            ],
            None,
        );

        let alternates: Vec<_> = (0..=MAX_CHAIN_DEPTH)
            .map(|index| temp.0.join(format!("alternate-{index}/objects")))
            .collect();
        for object_db in &alternates {
            std::fs::create_dir_all(object_db.join("info"))
                .expect("create alternate object database");
        }
        std::fs::write(
            repo_path.join("objects/info/alternates"),
            format!("{}\n", alternates[0].display()),
        )
        .expect("write primary alternates fixture");
        for (index, object_db) in alternates.iter().enumerate().take(MAX_CHAIN_DEPTH) {
            std::fs::write(
                object_db.join("info/alternates"),
                format!("{}\n", alternates[index + 1].display()),
            )
            .expect("write recursive alternates fixture");
        }

        let repo = gix::open(&repo_path).expect("open fixture repository");
        let budget = test_work_budget_with_source_limit(u64::MAX);
        let missing = parse_oid("1111111111111111111111111111111111111111");
        let error = locate_source(&repo, missing, None, &budget)
            .expect_err("alternate discovery must reject excessive recursion");

        assert_eq!(error.kind(), ErrorKind::CorruptRepository);
        assert_eq!(
            error.to_string(),
            format!("alternate recursion exceeds the safe depth bound of {MAX_CHAIN_DEPTH}")
        );
    }

    #[test]
    fn prefix_blob_alternate_paths_charge_before_path_allocation() {
        let budget = test_work_budget_with_source_limit(0);

        let error = parse_alternate_paths(b"relative-object-database\n", &budget)
            .expect_err("the path budget must be charged before parsing the first path");

        assert_eq!(error.kind(), ErrorKind::CorruptRepository);
        assert_eq!(
            error.to_string(),
            "decode work budget exhausted: source opens 1 exceed limit 0"
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

    #[test]
    fn prefix_blob_local_cycle_guard_runs_before_public_header_traversal() {
        let source = ObjectSource::Packed {
            index_path: PathBuf::from("fixture.idx"),
            pack_offset: 1,
        };
        let mut stack = vec![source.clone()];
        let public_header_called = Cell::new(false);

        let error = validate_local_metadata_before_public_header(
            || {
                enter_source(&source, &mut stack)?;
                Ok(GuardedMetadata {
                    object: ObjectMetadata {
                        kind: gix_object::Kind::Blob,
                        size: 1,
                    },
                    delta_bases: Vec::new(),
                    pack_entries: Vec::new(),
                })
            },
            |_| {
                public_header_called.set(true);
                Ok(ObjectMetadata {
                    kind: gix_object::Kind::Blob,
                    size: 1,
                })
            },
        )
        .expect_err("the repeated local source must fail before the public header stage");

        assert_eq!(error.to_string(), "delta chain contains a cycle");
        assert!(!public_header_called.get());
    }

    #[test]
    fn prefix_blob_guarded_chain_reuses_the_exact_physical_base_source() {
        let delta = ObjectSource::Packed {
            index_path: PathBuf::from("selected.idx"),
            pack_offset: 100,
        };
        let selected_base = ObjectSource::Packed {
            index_path: PathBuf::from("selected.idx"),
            pack_offset: 20,
        };
        let duplicate_base = ObjectSource::Packed {
            index_path: PathBuf::from("newer-duplicate.idx"),
            pack_offset: 30,
        };
        let guarded = GuardedMetadata {
            object: ObjectMetadata {
                kind: gix_object::Kind::Blob,
                size: 1,
            },
            delta_bases: vec![VerifiedDeltaBase {
                delta: delta.clone(),
                base: selected_base.clone(),
                metadata: ObjectMetadata {
                    kind: gix_object::Kind::Blob,
                    size: 1,
                },
                ref_base_id: None,
            }],
            pack_entries: Vec::new(),
        };

        let resolved = guarded.delta_base(&delta).expect("guarded exact base");
        assert_eq!(resolved.base, selected_base);
        assert_ne!(resolved.base, duplicate_base);
    }

    #[test]
    fn prefix_blob_direct_filesystem_failures_map_to_storage_unavailable() {
        let temp = TempDirectory::new("storage-error");
        let object_db = temp.0.join("objects");
        std::fs::create_dir(&object_db).expect("create object database");
        std::fs::write(object_db.join("pack"), b"not a directory")
            .expect("replace pack directory with a file");

        let budget = DecodeWorkBudget::new(PREFIX_LIMIT).expect("work budget");
        let error = pack_index_paths(&object_db, &budget).expect_err("read_dir must fail");
        assert_eq!(error.kind(), ErrorKind::StorageUnavailable);
        let native_error = crate::bounded_blob_native_error(error);
        assert_eq!(native_error.0, "storage_unavailable");
    }

    #[test]
    fn prefix_blob_structural_pack_failures_map_to_corrupt_repository() {
        let temp = TempDirectory::new("corrupt-pack-error");
        let index_path = temp.0.join("broken.idx");
        std::fs::write(&index_path, b"not a pack index").expect("write malformed pack index");

        let external = match gix_pack::Bundle::at(&index_path, gix_hash::Kind::Sha1) {
            Ok(_) => panic!("malformed pack index must fail"),
            Err(error) => error,
        };
        let error = Error::from_bundle(external);
        assert_eq!(error.kind(), ErrorKind::CorruptRepository);
        let native_error = crate::bounded_blob_native_error(error);
        assert_eq!(native_error.0, "corrupt_repository");
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
        assert!(prefix.allocations.max_metadata_buffer <= METADATA_BUFFER_LIMIT);
        if !matches!(fixture.storage, StorageForm::PackedBase) {
            assert!(
                prefix.allocations.max_metadata_buffer > 0,
                "loose and delta metadata probes must use the dedicated metadata buffer"
            );
        }
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
        assert!(prefix.allocations.source_opens > 0);
        assert!(prefix.allocations.compressed_input_bytes > 0);
        assert!(prefix.allocations.inflated_output_bytes > 0);
        if matches!(
            fixture.storage,
            StorageForm::PackedDelta | StorageForm::PackedRefDelta
        ) {
            assert!(prefix.allocations.delta_instructions > 0);
            assert!(prefix.allocations.index_entries_scanned > 0);
        }
        assert_work_within_limits(&prefix.allocations, PREFIX_LIMIT);
        eprintln!(
            "bounded allocation/work evidence: returned={} pre_header={} metadata={} intermediate_object={} decoded_object={} decoded_base={} delta={} work={} max_actual={} instructions={} source_opens={} index_entries={} compressed={} inflated={} skipped={}",
            prefix.data.len(),
            prefix.allocations.content_bytes_allocated_before_header,
            prefix.allocations.max_metadata_buffer,
            prefix.allocations.max_intermediate_object_buffer,
            prefix.allocations.max_decoded_object_buffer,
            prefix.allocations.max_decoded_base_buffer,
            prefix.allocations.max_delta_buffer,
            prefix.allocations.max_work_buffer,
            max_actual_content_buffer,
            prefix.allocations.delta_instructions,
            prefix.allocations.source_opens,
            prefix.allocations.index_entries_scanned,
            prefix.allocations.compressed_input_bytes,
            prefix.allocations.inflated_output_bytes,
            prefix.allocations.skipped_output_bytes
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
        assert!(complete.allocations.max_metadata_buffer <= METADATA_BUFFER_LIMIT);
        assert!(complete.allocations.max_intermediate_object_buffer < fixture.original.len());
        assert!(complete.allocations.max_decoded_object_buffer <= complete_limit);
        assert!(complete.allocations.max_decoded_base_buffer <= complete_limit);
        assert!(complete.allocations.max_delta_buffer <= complete_limit);
        assert!(complete.allocations.max_work_buffer <= complete_limit);
        assert_work_within_limits(&complete.allocations, complete_limit);
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

    fn assert_work_within_limits(
        instrumentation: &super::AllocationInstrumentation,
        caller_limit: usize,
    ) {
        let limits = DecodeWorkBudget::new(caller_limit)
            .expect("work limits")
            .limits;
        assert!(instrumentation.delta_instructions <= limits.delta_instructions);
        assert!(instrumentation.source_opens <= limits.source_opens);
        assert!(instrumentation.index_entries_scanned <= limits.index_entries_scanned);
        assert!(instrumentation.compressed_input_bytes <= limits.compressed_input_bytes);
        assert!(instrumentation.inflated_output_bytes <= limits.inflated_output_bytes);
        assert!(instrumentation.skipped_output_bytes <= limits.skipped_output_bytes);
        assert!(instrumentation.discovery_bytes <= limits.discovery_bytes);
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

    fn repeated_high_offset_copy_fixture(copy_count: usize) -> Fixture {
        let temp = TempDirectory::new("repeated-high-offset-copy");
        let repo_path = temp.0.join("repeated-high-offset-copy.git");
        git(
            &[
                "init",
                "--bare",
                "--object-format=sha1",
                path_str(&repo_path),
            ],
            None,
        );

        let base: Vec<u8> = (0..4096).map(|index| (index % 251) as u8).collect();
        let original = vec![*base.last().expect("non-empty base"); copy_count];
        let base_oid = git(&["hash-object", "--stdin"], Some(&base));
        let result_oid = git(&["hash-object", "--stdin"], Some(&original));

        let mut delta = encode_delta_varint(base.len() as u64);
        delta.extend(encode_delta_varint(original.len() as u64));
        for _ in 0..copy_count {
            delta.extend([0x93, 0xff, 0x0f, 0x01]);
        }

        let mut pack = b"PACK".to_vec();
        pack.extend(2_u32.to_be_bytes());
        pack.extend(2_u32.to_be_bytes());
        pack.extend(encode_pack_entry_header(3, base.len()));
        pack.extend(zlib(&base));
        pack.extend(encode_pack_entry_header(7, delta.len()));
        pack.extend(parse_oid(&base_oid).as_slice());
        pack.extend(zlib(&delta));

        let mut hasher = gix_hash::hasher(gix_hash::Kind::Sha1);
        hasher.update(&pack);
        let pack_id = hasher.try_finalize().expect("hash synthetic pack");
        pack.extend(pack_id.as_slice());

        let pack_path = repo_path
            .join("objects/pack")
            .join(format!("pack-{pack_id}.pack"));
        std::fs::write(&pack_path, pack).expect("write synthetic pack");
        git(&["index-pack", path_str(&pack_path)], None);

        let verify = verify_pack(&repo_path);
        let evidence = verify_line(&verify, &result_oid);
        assert!(
            evidence.split_whitespace().count() >= 7,
            "expected a verified delta entry: {evidence}"
        );

        Fixture {
            _temp: temp,
            repo_path,
            oid: parse_oid(&result_oid),
            original,
            evidence,
            storage: StorageForm::PackedRefDelta,
        }
    }

    fn encode_delta_varint(mut value: u64) -> Vec<u8> {
        let mut bytes = Vec::new();
        loop {
            let mut byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            bytes.push(byte);
            if value == 0 {
                return bytes;
            }
        }
    }

    fn encode_pack_entry_header(kind: u8, size: usize) -> Vec<u8> {
        let mut remaining = size >> 4;
        let mut first = (kind << 4) | (size as u8 & 0x0f);
        if remaining != 0 {
            first |= 0x80;
        }
        let mut bytes = vec![first];
        while remaining != 0 {
            let mut byte = (remaining & 0x7f) as u8;
            remaining >>= 7;
            if remaining != 0 {
                byte |= 0x80;
            }
            bytes.push(byte);
        }
        bytes
    }

    fn zlib(data: &[u8]) -> Vec<u8> {
        let mut encoder = gix_features::zlib::stream::deflate::Write::new(Vec::new());
        encoder.write_all(data).expect("compress fixture data");
        encoder.flush().expect("finish fixture zlib stream");
        encoder.into_inner()
    }

    fn adler32(data: &[u8]) -> u32 {
        const MODULUS: u32 = 65_521;
        let (a, b) = data.iter().fold((1_u32, 0_u32), |(a, b), byte| {
            let a = (a + u32::from(*byte)) % MODULUS;
            (a, (b + a) % MODULUS)
        });
        (b << 16) | a
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
        let indexes = pack_index_paths_for_test(repo_path);
        assert_eq!(
            indexes.len(),
            1,
            "expected exactly one pack index: {indexes:?}"
        );
        git(&["verify-pack", "-v", path_str(&indexes[0])], None)
    }

    fn pack_index_paths_for_test(repo_path: &Path) -> Vec<PathBuf> {
        let pack_dir = repo_path.join("objects/pack");
        let mut indexes: Vec<_> = std::fs::read_dir(&pack_dir)
            .expect("read pack directory")
            .map(|entry| entry.expect("pack directory entry").path())
            .filter(|path| path.extension().is_some_and(|extension| extension == "idx"))
            .collect();
        indexes.sort();
        indexes
    }

    fn test_work_budget_with_source_limit(source_opens: u64) -> DecodeWorkBudget {
        DecodeWorkBudget {
            limits: DecodeWorkLimits {
                delta_instructions: u64::MAX,
                source_opens,
                index_entries_scanned: u64::MAX,
                compressed_input_bytes: u64::MAX,
                inflated_output_bytes: u64::MAX,
                skipped_output_bytes: u64::MAX,
                discovery_bytes: u64::MAX,
            },
            delta_instructions: Cell::new(0),
            source_opens: Cell::new(0),
            index_entries_scanned: Cell::new(0),
            compressed_input_bytes: Cell::new(0),
            inflated_output_bytes: Cell::new(0),
            skipped_output_bytes: Cell::new(0),
            discovery_bytes: Cell::new(0),
            stop: None,
        }
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
