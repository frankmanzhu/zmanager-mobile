use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;
use zmanager_core::archive_browser::{
    self, ArchiveBrowserError, BrowserEntryKind, BrowserExtractOptions, BrowserListOptions,
};
use zmanager_core::libarchive_backend::{self, LibarchiveError, LibarchiveTestReport};
use zmanager_core::raw_stream_backend::{self, RawStreamError};
use zmanager_core::safety::{
    ExtractionDecision, ExtractionEntry, ExtractionEntryKind, ExtractionPolicy,
    ExtractionSafetyError, ExtractionSafetyPlanner, OverwritePolicy,
};
use zmanager_core::sevenz_backend::SevenZError;
use zmanager_core::tar_zst_backend::TarZstdError;
use zmanager_core::tzap_backend::{self, TzapError, TzapTestReport};
use zmanager_core::zip_backend::{self, ZipBackendError, ZipTestReport};

uniffi::include_scaffolding!("zmanager_mobile_core");

const ERROR_INVALID_REQUEST: &str = "invalid_request";
const ERROR_NOT_FOUND: &str = "not_found";
const ERROR_PASSWORD_REQUIRED: &str = "password_required";
const ERROR_INVALID_PASSWORD: &str = "invalid_password";
const ERROR_UNSAFE_ARCHIVE: &str = "unsafe_archive";
const ERROR_IO_ERROR: &str = "io_error";
const ERROR_UNSUPPORTED_FORMAT: &str = "unsupported_format";
const ERROR_DAMAGED_ARCHIVE: &str = "damaged_archive";
const ERROR_CANCELLED: &str = "cancelled";
const ERROR_OPERATION_FAILED: &str = "operation_failed";

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum BridgeSeverity {
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BridgeError {
    pub code: String,
    pub message: String,
    pub recovery_hint: Option<String>,
    pub severity: BridgeSeverity,
    pub retryable: bool,
}

#[derive(Debug, Error)]
pub enum ZmanagerMobileError {
    #[error("{user_message}")]
    Bridge {
        code: String,
        user_message: String,
        recovery_hint: Option<String>,
        severity: BridgeSeverity,
        retryable: bool,
    },
}

impl From<BridgeError> for ZmanagerMobileError {
    fn from(error: BridgeError) -> Self {
        Self::Bridge {
            code: error.code,
            user_message: error.message,
            recovery_hint: error.recovery_hint,
            severity: error.severity,
            retryable: error.retryable,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthcheckResult {
    pub status: String,
    pub engine: String,
    pub version: String,
    pub ready: bool,
    pub summary: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ArchiveFormat {
    Zip,
    SplitZip,
    Rar,
    MultipartRar,
    SevenZ,
    Tar,
    TarGz,
    TarBz2,
    TarXz,
    TarZst,
    Gzip,
    Bzip2,
    Xz,
    Zstd,
    Tzap,
    AppleArchive,
    Xip,
    RawStream,
    Other,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DetectArchiveRequest {
    pub archive_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DetectArchiveResult {
    pub archive_path: String,
    pub format: ArchiveFormat,
    pub format_label: String,
    pub exists: bool,
    pub is_file: bool,
    pub can_list: bool,
    pub can_extract: bool,
    pub can_create: bool,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum ArchiveEntryKind {
    File,
    Directory,
    Symlink,
    Hardlink,
    Special,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArchiveEntry {
    pub path: String,
    pub kind: ArchiveEntryKind,
    pub is_dir: bool,
    pub size: Option<u64>,
    pub compressed_size: Option<u64>,
    pub modified_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListArchiveRequest {
    pub archive_path: String,
    pub password: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListArchiveResult {
    pub archive_path: String,
    pub format: ArchiveFormat,
    pub format_label: String,
    pub entries: Vec<ArchiveEntry>,
    pub entry_count: u64,
    pub total_size: Option<u64>,
    pub warnings: Vec<BridgeError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestArchiveRequest {
    pub archive_path: String,
    pub password: Option<String>,
    pub selected_paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TestArchiveResult {
    pub archive_path: String,
    pub format: ArchiveFormat,
    pub format_label: String,
    pub verified: bool,
    pub tested_entries: u64,
    pub skipped_entries: u64,
    pub total_entries: u64,
    pub tested_bytes: u64,
    pub warnings: Vec<BridgeError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MaterializePreviewRequest {
    pub archive_path: String,
    pub entry_path: String,
    pub password: Option<String>,
    pub strip_components: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MaterializePreviewResult {
    pub archive_path: String,
    pub entry_path: String,
    pub cleanup_root: String,
    pub preview_path: String,
    pub written_bytes: u64,
    pub warnings: Vec<BridgeError>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum ExtractionCollisionPolicy {
    Refuse,
    Replace,
    Rename,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum ExtractionPlanEntryStatus {
    Write,
    Skip,
    Block,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanExtractRequest {
    pub archive_path: String,
    pub destination_root: String,
    pub password: Option<String>,
    pub selected_paths: Vec<String>,
    pub strip_components: u64,
    pub collision_policy: ExtractionCollisionPolicy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExtractionPlanEntry {
    pub archive_path: String,
    pub normalized_path: Option<String>,
    pub destination_path: Option<String>,
    pub kind: ArchiveEntryKind,
    pub status: ExtractionPlanEntryStatus,
    pub reason: Option<String>,
    pub size: Option<u64>,
    pub compressed_size: Option<u64>,
    pub replace_existing: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlanExtractResult {
    pub plan_id: String,
    pub archive_path: String,
    pub destination_root: String,
    pub format: ArchiveFormat,
    pub format_label: String,
    pub entries: Vec<ExtractionPlanEntry>,
    pub total_entries: u64,
    pub writable_entries: u64,
    pub skipped_entries: u64,
    pub blocked_entries: u64,
    pub estimated_bytes: Option<u64>,
    pub can_start: bool,
    pub warnings: Vec<BridgeError>,
}

pub fn healthcheck() -> HealthcheckResult {
    let report = zmanager_core::healthcheck();
    HealthcheckResult {
        status: if report.ready { "ready" } else { "not-ready" }.to_string(),
        engine: report.engine.to_string(),
        version: report.version.to_string(),
        ready: report.ready,
        summary: report.summary(),
    }
}

pub fn detect_archive(
    request: DetectArchiveRequest,
) -> Result<DetectArchiveResult, ZmanagerMobileError> {
    let archive_path = ensure_existing_file_path(request.archive_path, "archivePath")?;
    let path = Path::new(&archive_path);
    let (format, mut warnings) = classify_archive_path(path);
    let (can_list, can_extract, can_create) = format_capabilities(format);

    if matches!(format, ArchiveFormat::AppleArchive | ArchiveFormat::Xip) {
        warnings.push(
            "This launch-scope format must be handled by zmanager-core before mobile exposes it."
                .to_string(),
        );
    }

    Ok(DetectArchiveResult {
        archive_path,
        format,
        format_label: format_label(format).to_string(),
        exists: true,
        is_file: true,
        can_list,
        can_extract,
        can_create,
        warnings,
    })
}

#[allow(non_snake_case)]
pub fn detectArchive(
    request: DetectArchiveRequest,
) -> Result<DetectArchiveResult, ZmanagerMobileError> {
    detect_archive(request)
}

pub fn list_archive(request: ListArchiveRequest) -> Result<ListArchiveResult, ZmanagerMobileError> {
    let archive_path = ensure_existing_file_path(request.archive_path, "archivePath")?;
    let password = request
        .password
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let path = Path::new(&archive_path);
    let (format, _warnings) = classify_archive_path(path);

    let listing = archive_browser::list_entries_with_options(path, BrowserListOptions { password })
        .map_err(map_archive_browser_error)?;

    let mut total_size = 0u64;
    let mut has_size = false;
    let mut entries = Vec::with_capacity(listing.entries.len());

    for entry in listing.entries {
        if let Some(size) = entry.size {
            total_size = total_size.saturating_add(size);
            has_size = true;
        }

        let kind = map_browser_entry_kind(entry.kind);
        entries.push(ArchiveEntry {
            path: entry.path,
            kind,
            is_dir: matches!(kind, ArchiveEntryKind::Directory),
            size: entry.size,
            compressed_size: entry.compressed_size,
            modified_at: entry.modified,
        });
    }

    Ok(ListArchiveResult {
        archive_path,
        format,
        format_label: format_label(format).to_string(),
        entry_count: entries.len() as u64,
        total_size: has_size.then_some(total_size),
        entries,
        warnings: Vec::new(),
    })
}

#[allow(non_snake_case)]
pub fn listArchive(request: ListArchiveRequest) -> Result<ListArchiveResult, ZmanagerMobileError> {
    list_archive(request)
}

pub fn test_archive(request: TestArchiveRequest) -> Result<TestArchiveResult, ZmanagerMobileError> {
    let archive_path = ensure_existing_file_path(request.archive_path, "archivePath")?;
    let password = request
        .password
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let selected_paths = sanitize_selected_paths(request.selected_paths);
    let path = Path::new(&archive_path);
    let (format, _warnings) = classify_archive_path(path);

    let report = if matches!(format, ArchiveFormat::Zip) {
        let selected_paths = selected_paths.as_slice();
        TestArchiveReport::from_zip(
            zip_backend::test_zip_with_password_filter(path, password, |entry_path| {
                selected_path_matches(selected_paths, entry_path)
            })
            .map_err(map_zip_error)?,
        )
    } else if matches!(format, ArchiveFormat::Tzap) {
        let selected_paths = selected_paths.as_slice();
        TestArchiveReport::from_tzap(
            tzap_backend::test_tzap_with_optional_password_filter_and_x509_trust(
                path,
                password,
                |entry_path| selected_path_matches(selected_paths, entry_path),
                None,
            )
            .map_err(map_tzap_error)?,
        )
    } else if let Some(raw_format) = raw_stream_backend::detect_raw_stream_format(path) {
        test_raw_stream(path, raw_format, &selected_paths)?
    } else {
        let selected_paths = selected_paths.as_slice();
        TestArchiveReport::from_libarchive(
            libarchive_backend::test_archive_with_password_filter(path, password, |entry_path| {
                selected_path_matches(selected_paths, entry_path)
            })
            .map_err(map_libarchive_error)?,
        )
    };

    Ok(TestArchiveResult {
        archive_path,
        format,
        format_label: format_label(format).to_string(),
        verified: true,
        tested_entries: report.tested_entries,
        skipped_entries: report.skipped_entries,
        total_entries: report.total_entries(),
        tested_bytes: report.tested_bytes,
        warnings: report.warnings,
    })
}

#[allow(non_snake_case)]
pub fn testArchive(request: TestArchiveRequest) -> Result<TestArchiveResult, ZmanagerMobileError> {
    test_archive(request)
}

pub fn materialize_preview(
    request: MaterializePreviewRequest,
) -> Result<MaterializePreviewResult, ZmanagerMobileError> {
    let archive_path = ensure_existing_file_path(request.archive_path, "archivePath")?;
    let entry_path = ensure_non_empty_entry_path(request.entry_path)?;
    let strip_components = usize_from_u64(request.strip_components, "stripComponents")?;
    let password = request
        .password
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());

    let report = archive_browser::preview_entry_with_options(
        Path::new(&archive_path),
        &entry_path,
        BrowserExtractOptions {
            password,
            strip_components,
            ..BrowserExtractOptions::default()
        },
    )
    .map_err(map_archive_browser_error)?;

    Ok(MaterializePreviewResult {
        archive_path,
        entry_path,
        cleanup_root: report.cleanup_root.to_string_lossy().to_string(),
        preview_path: report.preview_path.to_string_lossy().to_string(),
        written_bytes: report.written_bytes,
        warnings: Vec::new(),
    })
}

#[allow(non_snake_case)]
pub fn materializePreview(
    request: MaterializePreviewRequest,
) -> Result<MaterializePreviewResult, ZmanagerMobileError> {
    materialize_preview(request)
}

pub fn plan_extract(request: PlanExtractRequest) -> Result<PlanExtractResult, ZmanagerMobileError> {
    let archive_path = ensure_existing_file_path(request.archive_path, "archivePath")?;
    let destination_root = ensure_destination_root_path(request.destination_root)?;
    let strip_components = usize_from_u64(request.strip_components, "stripComponents")?;
    let password = request
        .password
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let selected_paths = sanitize_selected_paths(request.selected_paths);
    let path = Path::new(&archive_path);
    let (format, _warnings) = classify_archive_path(path);
    let listing = archive_browser::list_entries_with_options(path, BrowserListOptions { password })
        .map_err(map_archive_browser_error)?;

    let policy = ExtractionPolicy {
        overwrite: map_collision_policy(request.collision_policy),
        strip_components,
        ..ExtractionPolicy::default()
    };
    let mut planner = ExtractionSafetyPlanner::new(PathBuf::from(&destination_root), policy);
    let mut entries = Vec::new();
    let mut estimated_bytes = 0u64;
    let mut has_estimated_bytes = false;
    let mut warnings = Vec::new();

    for entry in listing.entries {
        if !selected_path_matches(&selected_paths, &entry.path) {
            continue;
        }

        match plan_browser_entry(&mut planner, entry) {
            PlanEntryOutcome::Entry(plan_entry) => {
                if matches!(plan_entry.status, ExtractionPlanEntryStatus::Write)
                    && matches!(plan_entry.kind, ArchiveEntryKind::File)
                    && let Some(size) = plan_entry.size
                {
                    estimated_bytes = estimated_bytes.saturating_add(size);
                    has_estimated_bytes = true;
                }
                entries.push(plan_entry);
            }
            PlanEntryOutcome::EntryWithWarning {
                plan_entry,
                warning,
            } => {
                warnings.push(warning);
                entries.push(plan_entry);
            }
        }
    }

    let total_entries = usize_to_u64(entries.len());
    let writable_entries = usize_to_u64(
        entries
            .iter()
            .filter(|entry| matches!(entry.status, ExtractionPlanEntryStatus::Write))
            .count(),
    );
    let skipped_entries = usize_to_u64(
        entries
            .iter()
            .filter(|entry| matches!(entry.status, ExtractionPlanEntryStatus::Skip))
            .count(),
    );
    let blocked_entries = usize_to_u64(
        entries
            .iter()
            .filter(|entry| matches!(entry.status, ExtractionPlanEntryStatus::Block))
            .count(),
    );

    Ok(PlanExtractResult {
        plan_id: new_plan_id("extract"),
        archive_path,
        destination_root,
        format,
        format_label: format_label(format).to_string(),
        entries,
        total_entries,
        writable_entries,
        skipped_entries,
        blocked_entries,
        estimated_bytes: has_estimated_bytes.then_some(estimated_bytes),
        can_start: writable_entries > 0,
        warnings,
    })
}

#[allow(non_snake_case)]
pub fn planExtract(request: PlanExtractRequest) -> Result<PlanExtractResult, ZmanagerMobileError> {
    plan_extract(request)
}

struct TestArchiveReport {
    tested_entries: u64,
    skipped_entries: u64,
    tested_bytes: u64,
    warnings: Vec<BridgeError>,
}

impl TestArchiveReport {
    fn from_zip(report: ZipTestReport) -> Self {
        Self {
            tested_entries: usize_to_u64(report.tested_entries),
            skipped_entries: usize_to_u64(report.skipped_entries),
            tested_bytes: report.tested_bytes,
            warnings: Vec::new(),
        }
    }

    fn from_libarchive(report: LibarchiveTestReport) -> Self {
        Self {
            tested_entries: usize_to_u64(report.tested_entries),
            skipped_entries: usize_to_u64(report.skipped_entries),
            tested_bytes: report.tested_bytes,
            warnings: Vec::new(),
        }
    }

    fn from_tzap(report: TzapTestReport) -> Self {
        let warnings = report
            .x509_root_auth
            .map(|verification| {
                let mut warnings = Vec::with_capacity(1 + verification.diagnostics.len());
                warnings.push(bridge_warning(format!(
                    "TZAP root-auth verified for {}",
                    verification.subject
                )));
                warnings.extend(verification.diagnostics.into_iter().map(bridge_warning));
                warnings
            })
            .unwrap_or_default();

        Self {
            tested_entries: usize_to_u64(report.tested_entries),
            skipped_entries: usize_to_u64(report.skipped_entries),
            tested_bytes: report.tested_bytes,
            warnings,
        }
    }

    fn total_entries(&self) -> u64 {
        self.tested_entries.saturating_add(self.skipped_entries)
    }
}

enum PlanEntryOutcome {
    Entry(ExtractionPlanEntry),
    EntryWithWarning {
        plan_entry: ExtractionPlanEntry,
        warning: BridgeError,
    },
}

fn plan_browser_entry(
    planner: &mut ExtractionSafetyPlanner<'_>,
    entry: zmanager_core::archive_browser::BrowserEntry,
) -> PlanEntryOutcome {
    let kind = map_browser_entry_kind(entry.kind);

    let extraction_kind = match entry.kind {
        BrowserEntryKind::File => ExtractionEntryKind::File,
        BrowserEntryKind::Directory => ExtractionEntryKind::Directory,
        BrowserEntryKind::Symlink | BrowserEntryKind::Hardlink => {
            let reason =
                "Link target metadata is required before mobile can safely plan this entry.";
            let archive_path = entry.path.clone();
            return PlanEntryOutcome::EntryWithWarning {
                plan_entry: blocked_plan_entry(entry, kind, reason),
                warning: bridge_warning(format!(
                    "Blocked {} until zmanager-core exposes link target metadata for mobile planning.",
                    archive_path
                )),
            };
        }
        BrowserEntryKind::Special => {
            return PlanEntryOutcome::Entry(blocked_plan_entry(
                entry,
                kind,
                "Special files are blocked by the mobile extraction policy.",
            ));
        }
    };

    let safety_entry = ExtractionEntry {
        archive_path: entry.path.clone(),
        kind: extraction_kind,
        uncompressed_size: entry.size,
        compressed_size: entry.compressed_size,
    };

    match planner.validate_entry(&safety_entry) {
        Ok(ExtractionDecision::Write {
            normalized_archive_path,
            destination_path,
            replace_existing,
            ..
        }) => PlanEntryOutcome::Entry(ExtractionPlanEntry {
            archive_path: entry.path,
            normalized_path: Some(normalized_archive_path),
            destination_path: Some(destination_path.to_string_lossy().to_string()),
            kind,
            status: ExtractionPlanEntryStatus::Write,
            reason: None,
            size: entry.size,
            compressed_size: entry.compressed_size,
            replace_existing,
        }),
        Ok(ExtractionDecision::Skip {
            normalized_archive_path,
            reason,
        }) => PlanEntryOutcome::Entry(ExtractionPlanEntry {
            archive_path: entry.path,
            normalized_path: Some(normalized_archive_path),
            destination_path: None,
            kind,
            status: ExtractionPlanEntryStatus::Skip,
            reason: Some(reason),
            size: entry.size,
            compressed_size: entry.compressed_size,
            replace_existing: false,
        }),
        Err(error) => {
            PlanEntryOutcome::Entry(blocked_plan_entry_from_safety_error(entry, kind, error))
        }
    }
}

fn blocked_plan_entry(
    entry: zmanager_core::archive_browser::BrowserEntry,
    kind: ArchiveEntryKind,
    reason: impl Into<String>,
) -> ExtractionPlanEntry {
    ExtractionPlanEntry {
        archive_path: entry.path,
        normalized_path: None,
        destination_path: None,
        kind,
        status: ExtractionPlanEntryStatus::Block,
        reason: Some(reason.into()),
        size: entry.size,
        compressed_size: entry.compressed_size,
        replace_existing: false,
    }
}

fn blocked_plan_entry_from_safety_error(
    entry: zmanager_core::archive_browser::BrowserEntry,
    kind: ArchiveEntryKind,
    error: ExtractionSafetyError,
) -> ExtractionPlanEntry {
    let destination_path = safety_error_destination_path(&error);
    ExtractionPlanEntry {
        archive_path: entry.path,
        normalized_path: None,
        destination_path: destination_path.map(|path| path.to_string_lossy().to_string()),
        kind,
        status: ExtractionPlanEntryStatus::Block,
        reason: Some(error.to_string()),
        size: entry.size,
        compressed_size: entry.compressed_size,
        replace_existing: false,
    }
}

fn safety_error_destination_path(error: &ExtractionSafetyError) -> Option<PathBuf> {
    match error {
        ExtractionSafetyError::DestinationEscape {
            destination_path, ..
        }
        | ExtractionSafetyError::DestinationExists {
            destination_path, ..
        }
        | ExtractionSafetyError::OverwritePromptUnavailable {
            destination_path, ..
        }
        | ExtractionSafetyError::OverwriteAborted {
            destination_path, ..
        }
        | ExtractionSafetyError::DestinationProbe {
            destination_path, ..
        } => Some(destination_path.clone()),
        ExtractionSafetyError::EmptyPath
        | ExtractionSafetyError::NulByte { .. }
        | ExtractionSafetyError::AbsolutePath { .. }
        | ExtractionSafetyError::WindowsPrefix { .. }
        | ExtractionSafetyError::ParentTraversal { .. }
        | ExtractionSafetyError::NameCollision { .. }
        | ExtractionSafetyError::UnsafeFileType { .. }
        | ExtractionSafetyError::LinkTargetEscapes { .. }
        | ExtractionSafetyError::ExpandedSizeLimitExceeded { .. }
        | ExtractionSafetyError::ExpansionRatioLimitExceeded { .. } => None,
    }
}

fn map_collision_policy(policy: ExtractionCollisionPolicy) -> OverwritePolicy {
    match policy {
        ExtractionCollisionPolicy::Refuse => OverwritePolicy::Refuse,
        ExtractionCollisionPolicy::Replace => OverwritePolicy::Replace,
        ExtractionCollisionPolicy::Rename => OverwritePolicy::Rename,
    }
}

fn test_raw_stream(
    path: &Path,
    format: raw_stream_backend::RawStreamFormat,
    selected_paths: &[String],
) -> Result<TestArchiveReport, ZmanagerMobileError> {
    let synthetic_entry = raw_stream_backend::output_name_for_raw_stream(path, format)
        .unwrap_or_else(|| format_label(classify_archive_path(path).0).to_string());

    if !selected_path_matches(selected_paths, &synthetic_entry) {
        return Ok(TestArchiveReport {
            tested_entries: 0,
            skipped_entries: 1,
            tested_bytes: 0,
            warnings: Vec::new(),
        });
    }

    let tested_bytes =
        raw_stream_backend::test_raw_stream(path, format).map_err(map_raw_stream_error)?;

    Ok(TestArchiveReport {
        tested_entries: 1,
        skipped_entries: 0,
        tested_bytes,
        warnings: Vec::new(),
    })
}

fn sanitize_selected_paths(selected_paths: Vec<String>) -> Vec<String> {
    selected_paths
        .into_iter()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .collect()
}

fn selected_path_matches(selected_paths: &[String], entry_path: &str) -> bool {
    selected_paths.is_empty() || selected_paths.iter().any(|value| value == entry_path)
}

fn ensure_non_empty_entry_path(value: String) -> Result<String, ZmanagerMobileError> {
    if value.is_empty() {
        return Err(bridge_error(
            ERROR_INVALID_REQUEST,
            "entryPath cannot be empty",
            None,
            BridgeSeverity::Warning,
            false,
        ));
    }

    Ok(value)
}

fn ensure_destination_root_path(value: String) -> Result<String, ZmanagerMobileError> {
    let value = value.trim().to_string();
    if value.is_empty() {
        return Err(bridge_error(
            ERROR_INVALID_REQUEST,
            "destinationRoot cannot be empty",
            None,
            BridgeSeverity::Warning,
            false,
        ));
    }

    if value.contains("://") {
        return Err(bridge_error(
            ERROR_INVALID_REQUEST,
            "destinationRoot must be an app-controlled filesystem path",
            hint(
                "Resolve provider destinations to app-controlled staging before calling the Rust bridge.",
            ),
            BridgeSeverity::Warning,
            false,
        ));
    }

    let path = Path::new(&value);
    match fs::metadata(path) {
        Ok(metadata) if !metadata.is_dir() => Err(bridge_error(
            ERROR_INVALID_REQUEST,
            "destinationRoot must point to a directory when it already exists",
            None,
            BridgeSeverity::Warning,
            false,
        )),
        Ok(_) => Ok(value),
        Err(source) if source.kind() == io::ErrorKind::NotFound => Ok(value),
        Err(source) => Err(map_io_error(path.to_path_buf(), source)),
    }
}

fn usize_from_u64(value: u64, field: &str) -> Result<usize, ZmanagerMobileError> {
    usize::try_from(value).map_err(|_| {
        bridge_error(
            ERROR_INVALID_REQUEST,
            format!("{field} is too large for this device"),
            None,
            BridgeSeverity::Warning,
            false,
        )
    })
}

fn ensure_existing_file_path(value: String, field: &str) -> Result<String, ZmanagerMobileError> {
    let value = value.trim().to_string();
    if value.is_empty() {
        return Err(bridge_error(
            ERROR_INVALID_REQUEST,
            format!("{field} cannot be empty"),
            None,
            BridgeSeverity::Warning,
            false,
        ));
    }

    if value.contains("://") {
        return Err(bridge_error(
            ERROR_INVALID_REQUEST,
            format!("{field} must be an app-controlled filesystem path"),
            hint("Copy provider-backed files into app cache before calling the Rust bridge."),
            BridgeSeverity::Warning,
            false,
        ));
    }

    let path = Path::new(&value);
    let metadata = fs::metadata(path).map_err(|source| {
        if source.kind() == io::ErrorKind::NotFound {
            bridge_error(
                ERROR_NOT_FOUND,
                format!("{field} does not exist"),
                hint("Choose an archive that has already been copied into app-controlled storage."),
                BridgeSeverity::Warning,
                false,
            )
        } else {
            map_io_error(path.to_path_buf(), source)
        }
    })?;

    if !metadata.is_file() {
        return Err(bridge_error(
            ERROR_INVALID_REQUEST,
            format!("{field} must point to a file"),
            None,
            BridgeSeverity::Warning,
            false,
        ));
    }

    Ok(value)
}

fn classify_archive_path(path: &Path) -> (ArchiveFormat, Vec<String>) {
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();

    let format = if matches!(
        extension.as_str(),
        "zip" | "zipx" | "jar" | "war" | "ipa" | "apk" | "appx" | "xpi"
    ) {
        ArchiveFormat::Zip
    } else if is_split_zip_extension(&extension) {
        ArchiveFormat::SplitZip
    } else if extension == "rar" {
        if file_name.contains(".part") {
            ArchiveFormat::MultipartRar
        } else {
            ArchiveFormat::Rar
        }
    } else if is_rar_sidecar_extension(&extension) {
        ArchiveFormat::MultipartRar
    } else if extension == "7z" {
        ArchiveFormat::SevenZ
    } else if extension == "tar" {
        ArchiveFormat::Tar
    } else if matches!(extension.as_str(), "tgz") || file_name.ends_with(".tar.gz") {
        ArchiveFormat::TarGz
    } else if matches!(extension.as_str(), "tbz" | "tbz2") || file_name.ends_with(".tar.bz2") {
        ArchiveFormat::TarBz2
    } else if matches!(extension.as_str(), "txz") || file_name.ends_with(".tar.xz") {
        ArchiveFormat::TarXz
    } else if extension == "tzst" || file_name.ends_with(".tar.zst") {
        ArchiveFormat::TarZst
    } else if extension == "gz" {
        ArchiveFormat::Gzip
    } else if extension == "bz2" {
        ArchiveFormat::Bzip2
    } else if extension == "xz" {
        ArchiveFormat::Xz
    } else if extension == "zst" {
        ArchiveFormat::Zstd
    } else if extension == "tzap" {
        ArchiveFormat::Tzap
    } else if extension == "aar" {
        ArchiveFormat::AppleArchive
    } else if extension == "xip" {
        ArchiveFormat::Xip
    } else if matches!(
        extension.as_str(),
        "lzma" | "lz" | "br" | "lz4" | "lzo" | "z" | "lrz"
    ) {
        ArchiveFormat::RawStream
    } else {
        ArchiveFormat::Other
    };

    (format, Vec::new())
}

fn format_capabilities(format: ArchiveFormat) -> (bool, bool, bool) {
    match format {
        ArchiveFormat::AppleArchive | ArchiveFormat::Xip => (false, false, false),
        ArchiveFormat::Rar | ArchiveFormat::MultipartRar | ArchiveFormat::SplitZip => {
            (true, true, false)
        }
        ArchiveFormat::Zip
        | ArchiveFormat::SevenZ
        | ArchiveFormat::TarZst
        | ArchiveFormat::Tzap => (true, true, true),
        ArchiveFormat::Tar
        | ArchiveFormat::TarGz
        | ArchiveFormat::TarBz2
        | ArchiveFormat::TarXz
        | ArchiveFormat::Gzip
        | ArchiveFormat::Bzip2
        | ArchiveFormat::Xz
        | ArchiveFormat::Zstd
        | ArchiveFormat::RawStream
        | ArchiveFormat::Other => (true, true, false),
    }
}

fn format_label(format: ArchiveFormat) -> &'static str {
    match format {
        ArchiveFormat::Zip => "ZIP",
        ArchiveFormat::SplitZip => "Split ZIP",
        ArchiveFormat::Rar => "RAR",
        ArchiveFormat::MultipartRar => "Multipart RAR",
        ArchiveFormat::SevenZ => "7z",
        ArchiveFormat::Tar => "TAR",
        ArchiveFormat::TarGz => "TAR.GZ",
        ArchiveFormat::TarBz2 => "TAR.BZ2",
        ArchiveFormat::TarXz => "TAR.XZ",
        ArchiveFormat::TarZst => "TAR.ZST",
        ArchiveFormat::Gzip => "GZIP",
        ArchiveFormat::Bzip2 => "BZIP2",
        ArchiveFormat::Xz => "XZ",
        ArchiveFormat::Zstd => "Zstd",
        ArchiveFormat::Tzap => "TZAP",
        ArchiveFormat::AppleArchive => "AppleArchive / AAR",
        ArchiveFormat::Xip => "XIP",
        ArchiveFormat::RawStream => "Raw stream",
        ArchiveFormat::Other => "Archive",
    }
}

fn is_split_zip_extension(extension: &str) -> bool {
    let Some(number) = extension.strip_prefix('z') else {
        return false;
    };
    number.len() == 2 && number.chars().all(|value| value.is_ascii_digit())
}

fn is_rar_sidecar_extension(extension: &str) -> bool {
    let Some(number) = extension.strip_prefix('r') else {
        return false;
    };
    number.len() == 2 && number.chars().all(|value| value.is_ascii_digit())
}

fn map_browser_entry_kind(entry: BrowserEntryKind) -> ArchiveEntryKind {
    match entry {
        BrowserEntryKind::File => ArchiveEntryKind::File,
        BrowserEntryKind::Directory => ArchiveEntryKind::Directory,
        BrowserEntryKind::Symlink => ArchiveEntryKind::Symlink,
        BrowserEntryKind::Hardlink => ArchiveEntryKind::Hardlink,
        BrowserEntryKind::Special => ArchiveEntryKind::Special,
    }
}

fn map_archive_browser_error(error: ArchiveBrowserError) -> ZmanagerMobileError {
    match error {
        ArchiveBrowserError::Zip(source) => map_zip_error(source),
        ArchiveBrowserError::TarZst(source) => map_tar_zst_error(source),
        ArchiveBrowserError::SevenZ(source) => map_7z_error(source),
        ArchiveBrowserError::Tzap(source) => map_tzap_error(source),
        ArchiveBrowserError::Libarchive(source) => map_libarchive_error(source),
        ArchiveBrowserError::RawStream(source) => map_raw_stream_error(source),
        ArchiveBrowserError::Io { path, source } => map_io_error(path, source),
        ArchiveBrowserError::Safety(source) => bridge_error(
            ERROR_UNSAFE_ARCHIVE,
            format!("Entry blocked by safety policy: {source}"),
            None,
            BridgeSeverity::Warning,
            false,
        ),
        ArchiveBrowserError::EntryNotFound { path } => bridge_error(
            ERROR_NOT_FOUND,
            format!("Archive entry not found: {path}"),
            hint("Open a different archive or choose a different entry."),
            BridgeSeverity::Warning,
            false,
        ),
        ArchiveBrowserError::UnsupportedEntry { path, .. } => bridge_error(
            ERROR_UNSUPPORTED_FORMAT,
            format!("Entry cannot be extracted or previewed here: {path}"),
            None,
            BridgeSeverity::Warning,
            false,
        ),
    }
}

fn map_zip_error(error: ZipBackendError) -> ZmanagerMobileError {
    match error {
        ZipBackendError::PasswordRequired => bridge_error(
            ERROR_PASSWORD_REQUIRED,
            "This ZIP archive is encrypted and requires a password.",
            hint("Enter the archive password."),
            BridgeSeverity::Warning,
            true,
        ),
        ZipBackendError::InvalidPassword => bridge_error(
            ERROR_INVALID_PASSWORD,
            "The ZIP password was incorrect.",
            None,
            BridgeSeverity::Warning,
            true,
        ),
        ZipBackendError::Io { path, source } => map_io_error(path, source),
        ZipBackendError::Safety(source) => bridge_error(
            ERROR_UNSAFE_ARCHIVE,
            format!("Entry blocked by safety policy: {source}"),
            None,
            BridgeSeverity::Warning,
            false,
        ),
        ZipBackendError::UnsupportedSplitZip { .. } => bridge_error(
            ERROR_UNSUPPORTED_FORMAT,
            "ZIP split archives are unsupported for this operation in this path.",
            None,
            BridgeSeverity::Warning,
            false,
        ),
        ZipBackendError::Zip(source) => {
            damaged_archive(format!("ZIP archive could not be read: {source}"))
        }
        ZipBackendError::Cancelled => bridge_error(
            ERROR_CANCELLED,
            "ZIP job was cancelled.",
            None,
            BridgeSeverity::Info,
            true,
        ),
        source => operation_failed(format!("ZIP operation failed: {source}")),
    }
}

fn map_tar_zst_error(error: TarZstdError) -> ZmanagerMobileError {
    match error {
        TarZstdError::Io { path, source } => map_io_error(path, source),
        TarZstdError::Safety(source) => bridge_error(
            ERROR_UNSAFE_ARCHIVE,
            format!("Entry blocked by safety policy: {source}"),
            None,
            BridgeSeverity::Warning,
            false,
        ),
        TarZstdError::Cancelled => bridge_error(
            ERROR_CANCELLED,
            "TAR/ZST job was cancelled.",
            None,
            BridgeSeverity::Info,
            true,
        ),
        source => operation_failed(format!("TAR/ZST operation failed: {source}")),
    }
}

fn map_7z_error(error: SevenZError) -> ZmanagerMobileError {
    match error {
        SevenZError::PasswordRequired => bridge_error(
            ERROR_PASSWORD_REQUIRED,
            "This 7z archive is encrypted and requires a password.",
            hint("Enter the archive password."),
            BridgeSeverity::Warning,
            true,
        ),
        SevenZError::InvalidPassword => bridge_error(
            ERROR_INVALID_PASSWORD,
            "The 7z password was incorrect.",
            None,
            BridgeSeverity::Warning,
            true,
        ),
        SevenZError::Io { path, source } => map_io_error(path, source),
        SevenZError::Safety(source) => bridge_error(
            ERROR_UNSAFE_ARCHIVE,
            format!("Entry blocked by safety policy: {source}"),
            None,
            BridgeSeverity::Warning,
            false,
        ),
        SevenZError::Cancelled => bridge_error(
            ERROR_CANCELLED,
            "7z job was cancelled.",
            None,
            BridgeSeverity::Info,
            true,
        ),
        source => operation_failed(format!("7z operation failed: {source}")),
    }
}

fn map_tzap_error(error: TzapError) -> ZmanagerMobileError {
    match error {
        TzapError::PasswordRequired => bridge_error(
            ERROR_PASSWORD_REQUIRED,
            "This TZAP archive requires a password.",
            hint("Enter the archive password."),
            BridgeSeverity::Warning,
            true,
        ),
        TzapError::RecipientKeyRequired => bridge_error(
            ERROR_UNSUPPORTED_FORMAT,
            "This TZAP archive requires a recipient key that mobile has not been given.",
            None,
            BridgeSeverity::Warning,
            false,
        ),
        TzapError::Format(source) => {
            damaged_archive(format!("TZAP archive could not be verified: {source}"))
        }
        TzapError::X509RootAuth(_) => damaged_archive("TZAP root-auth verification failed."),
        TzapError::KeyWrap(_) => damaged_archive("TZAP recipient key wrapping failed."),
        TzapError::Io { path, source } => map_io_error(path, source),
        TzapError::Safety(source) => bridge_error(
            ERROR_UNSAFE_ARCHIVE,
            format!("Entry blocked by safety policy: {source}"),
            None,
            BridgeSeverity::Warning,
            false,
        ),
        TzapError::Cancelled => bridge_error(
            ERROR_CANCELLED,
            "TZAP job was cancelled.",
            None,
            BridgeSeverity::Info,
            true,
        ),
        source => operation_failed(format!("TZAP operation failed: {source}")),
    }
}

fn map_libarchive_error(error: LibarchiveError) -> ZmanagerMobileError {
    match error {
        LibarchiveError::Archive(source) => {
            damaged_archive(format!("Archive could not be read: {source}"))
        }
        LibarchiveError::RawStream(source) => map_raw_stream_error(source),
        LibarchiveError::Io { path, source } => map_io_error(path, source),
        LibarchiveError::Safety(source) => bridge_error(
            ERROR_UNSAFE_ARCHIVE,
            format!("Entry blocked by safety policy: {source}"),
            None,
            BridgeSeverity::Warning,
            false,
        ),
        LibarchiveError::EntryNotFound { path } => bridge_error(
            ERROR_NOT_FOUND,
            format!("Archive entry not found: {path}"),
            hint("Open a different archive or choose a different entry."),
            BridgeSeverity::Warning,
            false,
        ),
        LibarchiveError::Cancelled => bridge_error(
            ERROR_CANCELLED,
            "Archive job was cancelled.",
            None,
            BridgeSeverity::Info,
            true,
        ),
        source => operation_failed(format!("Archive operation failed: {source}")),
    }
}

fn map_raw_stream_error(error: RawStreamError) -> ZmanagerMobileError {
    match error {
        RawStreamError::Io { path, source } => map_io_error(path, source),
        RawStreamError::Safety(source) => bridge_error(
            ERROR_UNSAFE_ARCHIVE,
            format!("Entry blocked by safety policy: {source}"),
            None,
            BridgeSeverity::Warning,
            false,
        ),
        RawStreamError::ExternalToolUnavailable { tool, .. } => bridge_error(
            ERROR_UNSUPPORTED_FORMAT,
            format!("Required decoder tool is unavailable: {tool}"),
            None,
            BridgeSeverity::Warning,
            false,
        ),
        RawStreamError::ExternalToolFailed { tool, .. } => {
            damaged_archive(format!("{tool} could not decode this stream."))
        }
        source => operation_failed(format!("Raw stream operation failed: {source}")),
    }
}

fn map_io_error(path: PathBuf, source: io::Error) -> ZmanagerMobileError {
    if source.kind() == io::ErrorKind::NotFound {
        bridge_error(
            ERROR_NOT_FOUND,
            format!("Path not found: {}", path.display()),
            hint("Choose an archive that has already been copied into app-controlled storage."),
            BridgeSeverity::Warning,
            false,
        )
    } else {
        bridge_error(
            ERROR_IO_ERROR,
            format!("I/O failed for {}: {source}", path.display()),
            None,
            BridgeSeverity::Error,
            is_retryable_io_error(source.kind()),
        )
    }
}

fn operation_failed(message: impl Into<String>) -> ZmanagerMobileError {
    bridge_error(
        ERROR_OPERATION_FAILED,
        message,
        None,
        BridgeSeverity::Error,
        false,
    )
}

fn damaged_archive(message: impl Into<String>) -> ZmanagerMobileError {
    bridge_error(
        ERROR_DAMAGED_ARCHIVE,
        message,
        hint("Choose a different archive or verify the source file."),
        BridgeSeverity::Warning,
        false,
    )
}

fn bridge_warning(message: impl Into<String>) -> BridgeError {
    BridgeError {
        code: "warning".to_string(),
        message: message.into(),
        recovery_hint: None,
        severity: BridgeSeverity::Warning,
        retryable: false,
    }
}

fn bridge_error(
    code: impl Into<String>,
    message: impl Into<String>,
    recovery_hint: Option<String>,
    severity: BridgeSeverity,
    retryable: bool,
) -> ZmanagerMobileError {
    BridgeError {
        code: code.into(),
        message: message.into(),
        recovery_hint: recovery_hint.map(Into::into),
        severity,
        retryable,
    }
    .into()
}

fn hint(value: impl Into<String>) -> Option<String> {
    Some(value.into())
}

fn usize_to_u64(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

fn new_plan_id(prefix: &str) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("{prefix}-{}-{now}", std::process::id())
}

fn is_retryable_io_error(kind: io::ErrorKind) -> bool {
    matches!(
        kind,
        io::ErrorKind::Interrupted
            | io::ErrorKind::WouldBlock
            | io::ErrorKind::TimedOut
            | io::ErrorKind::UnexpectedEof
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};
    use zmanager_core::zip_backend::{ZipCreateOptions, create_zip_from_path};

    #[test]
    fn healthcheck_reports_real_core() {
        let result = healthcheck();

        assert_eq!(result.engine, "zmanager-core");
        assert!(result.ready);
        assert_eq!(result.status, "ready");
        assert!(result.summary.contains("zmanager-core"));
    }

    #[test]
    fn classify_archive_path_supports_launch_extensions() {
        let cases = [
            ("ARCHIVE.ZIP", ArchiveFormat::Zip),
            ("archive.z01", ArchiveFormat::SplitZip),
            ("archive.part01.rar", ArchiveFormat::MultipartRar),
            ("archive.r02", ArchiveFormat::MultipartRar),
            ("archive.7z", ArchiveFormat::SevenZ),
            ("archive.tar", ArchiveFormat::Tar),
            ("archive.tar.gz", ArchiveFormat::TarGz),
            ("archive.tbz2", ArchiveFormat::TarBz2),
            ("archive.txz", ArchiveFormat::TarXz),
            ("archive.tar.zst", ArchiveFormat::TarZst),
            ("archive.gz", ArchiveFormat::Gzip),
            ("archive.bz2", ArchiveFormat::Bzip2),
            ("archive.xz", ArchiveFormat::Xz),
            ("archive.zst", ArchiveFormat::Zstd),
            ("archive.tzap", ArchiveFormat::Tzap),
            ("archive.aar", ArchiveFormat::AppleArchive),
            ("archive.xip", ArchiveFormat::Xip),
        ];

        for (path, expected) in cases {
            assert_eq!(classify_archive_path(Path::new(path)).0, expected, "{path}");
        }
    }

    #[test]
    fn detect_archive_rejects_platform_uri_objects() {
        let error = detect_archive(DetectArchiveRequest {
            archive_path: "content://downloads/archive.zip".to_string(),
        })
        .unwrap_err();

        assert_bridge_error_code(error, ERROR_INVALID_REQUEST);
    }

    #[test]
    fn detect_archive_classifies_existing_app_controlled_file() {
        let temp = TestDir::new("detect-existing-file");
        temp.write_file("ARCHIVE.ZIP", b"not parsed during detection");

        let result = detect_archive(DetectArchiveRequest {
            archive_path: temp.path("ARCHIVE.ZIP").to_string_lossy().to_string(),
        })
        .expect("detection should classify an existing app-controlled path");

        assert_eq!(result.format, ArchiveFormat::Zip);
        assert_eq!(result.format_label, "ZIP");
        assert!(result.exists);
        assert!(result.is_file);
        assert!(result.can_list);
        assert!(result.can_extract);
        assert!(result.can_create);
    }

    #[test]
    fn list_archive_rejects_missing_path() {
        let error = list_archive(ListArchiveRequest {
            archive_path: "/definitely/missing/archive.zip".to_string(),
            password: None,
        })
        .unwrap_err();

        assert_bridge_error_code(error, ERROR_NOT_FOUND);
    }

    #[test]
    fn list_archive_reads_real_zip_through_core() {
        let temp = TestDir::new("list-archive-real-zip");
        temp.create_dir("project");
        temp.write_file("project/readme.txt", b"hello mobile bridge\n");
        let archive = temp.path("archive.zip");
        create_zip_from_path(temp.path("project"), &archive, &ZipCreateOptions::default())
            .expect("fixture zip should be created through zmanager-core");

        let result = list_archive(ListArchiveRequest {
            archive_path: archive.to_string_lossy().to_string(),
            password: None,
        })
        .expect("core-backed listing should succeed");

        assert_eq!(result.format, ArchiveFormat::Zip);
        assert!(result.entry_count >= 1);
        assert!(
            result
                .entries
                .iter()
                .any(|entry| entry.path.ends_with("readme.txt"))
        );
        assert!(result.total_size.is_some());
    }

    #[test]
    fn test_archive_reads_real_zip_through_core() {
        let fixture = create_test_zip("test-archive-real-zip");

        let result = test_archive(TestArchiveRequest {
            archive_path: fixture.archive.to_string_lossy().to_string(),
            password: None,
            selected_paths: Vec::new(),
        })
        .expect("core-backed archive test should succeed");

        assert_eq!(result.format, ArchiveFormat::Zip);
        assert!(result.verified);
        assert!(result.tested_entries >= 1);
        assert_eq!(
            result.total_entries,
            result.tested_entries + result.skipped_entries
        );
        assert!(result.tested_bytes > 0);
    }

    #[test]
    fn test_archive_honors_selected_entry_filter() {
        let fixture = create_test_zip("test-archive-selected-filter");

        let result = test_archive(TestArchiveRequest {
            archive_path: fixture.archive.to_string_lossy().to_string(),
            password: None,
            selected_paths: vec!["missing.txt".to_string()],
        })
        .expect("skipping all entries is still a successful filtered test");

        assert_eq!(result.tested_entries, 0);
        assert!(result.skipped_entries >= 1);
        assert_eq!(result.total_entries, result.skipped_entries);
        assert_eq!(result.tested_bytes, 0);
    }

    #[test]
    fn test_archive_reports_corrupt_zip_as_damaged_archive() {
        let temp = TestDir::new("test-archive-corrupt-zip");
        temp.write_file("broken.zip", b"this is not a zip archive");

        let error = test_archive(TestArchiveRequest {
            archive_path: temp.path("broken.zip").to_string_lossy().to_string(),
            password: None,
            selected_paths: Vec::new(),
        })
        .unwrap_err();

        assert_bridge_error_code(error, ERROR_DAMAGED_ARCHIVE);
    }

    #[test]
    fn materialize_preview_extracts_one_entry_to_cleanup_root() {
        let fixture = create_test_zip("materialize-preview-real-zip");
        let entry_path = readme_entry_path(&fixture.archive);

        let result = materialize_preview(MaterializePreviewRequest {
            archive_path: fixture.archive.to_string_lossy().to_string(),
            entry_path: entry_path.clone(),
            password: None,
            strip_components: 0,
        })
        .expect("preview should materialize through zmanager-core");

        let cleanup_root = PathBuf::from(&result.cleanup_root);
        let preview_path = PathBuf::from(&result.preview_path);
        let canonical_cleanup_root =
            fs::canonicalize(&cleanup_root).expect("cleanup root should exist");
        let canonical_preview_path =
            fs::canonicalize(&preview_path).expect("preview path should exist");
        assert_eq!(result.entry_path, entry_path);
        assert!(canonical_preview_path.starts_with(&canonical_cleanup_root));
        assert_eq!(
            fs::read_to_string(&preview_path).expect("preview file should be readable"),
            "hello mobile bridge\n"
        );
        assert!(result.written_bytes > 0);

        fs::remove_dir_all(cleanup_root).expect("preview cleanup root should be removable");
    }

    #[test]
    fn materialize_preview_rejects_empty_entry_path() {
        let fixture = create_test_zip("materialize-preview-empty-entry");

        let error = materialize_preview(MaterializePreviewRequest {
            archive_path: fixture.archive.to_string_lossy().to_string(),
            entry_path: String::new(),
            password: None,
            strip_components: 0,
        })
        .unwrap_err();

        assert_bridge_error_code(error, ERROR_INVALID_REQUEST);
    }

    #[test]
    fn plan_extract_returns_write_plan_without_creating_destination() {
        let fixture = create_test_zip("plan-extract-real-zip");
        let destination = fixture.temp.path("out");

        let result = plan_extract(PlanExtractRequest {
            archive_path: fixture.archive.to_string_lossy().to_string(),
            destination_root: destination.to_string_lossy().to_string(),
            password: None,
            selected_paths: Vec::new(),
            strip_components: 0,
            collision_policy: ExtractionCollisionPolicy::Refuse,
        })
        .expect("planning should succeed without extracting");

        assert!(!destination.exists());
        assert!(result.can_start);
        assert!(result.writable_entries >= 1);
        assert_eq!(result.blocked_entries, 0);
        assert!(result.estimated_bytes.is_some());
        assert!(result.entries.iter().any(|entry| {
            matches!(entry.status, ExtractionPlanEntryStatus::Write)
                && entry
                    .destination_path
                    .as_deref()
                    .is_some_and(|path| Path::new(path).starts_with(&destination))
        }));
    }

    #[test]
    fn plan_extract_surfaces_destination_collision_as_blocked_entry() {
        let fixture = create_test_zip("plan-extract-collision");
        let entry_path = readme_entry_path(&fixture.archive);
        let destination = fixture.temp.path("out");
        let colliding_path = destination.join(&entry_path);
        fs::create_dir_all(
            colliding_path
                .parent()
                .expect("colliding path should have a parent"),
        )
        .expect("collision parent should be created");
        fs::write(&colliding_path, b"existing").expect("collision file should be written");

        let result = plan_extract(PlanExtractRequest {
            archive_path: fixture.archive.to_string_lossy().to_string(),
            destination_root: destination.to_string_lossy().to_string(),
            password: None,
            selected_paths: vec![entry_path.clone()],
            strip_components: 0,
            collision_policy: ExtractionCollisionPolicy::Refuse,
        })
        .expect("planning should return a blocked collision row");

        assert_eq!(result.total_entries, 1);
        assert_eq!(result.writable_entries, 0);
        assert_eq!(result.blocked_entries, 1);
        assert!(!result.can_start);
        let blocked = result.entries.first().expect("blocked entry should exist");
        assert_eq!(blocked.archive_path, entry_path);
        assert!(matches!(blocked.status, ExtractionPlanEntryStatus::Block));
        assert!(
            blocked
                .reason
                .as_deref()
                .is_some_and(|reason| reason.contains("would overwrite"))
        );
    }

    fn assert_bridge_error_code(error: ZmanagerMobileError, expected: &str) {
        match error {
            ZmanagerMobileError::Bridge { code, .. } => assert_eq!(code, expected),
        }
    }

    fn readme_entry_path(archive: &Path) -> String {
        list_archive(ListArchiveRequest {
            archive_path: archive.to_string_lossy().to_string(),
            password: None,
        })
        .expect("fixture archive should list")
        .entries
        .into_iter()
        .find(|entry| entry.path.ends_with("readme.txt"))
        .expect("fixture archive should contain readme.txt")
        .path
    }

    fn create_test_zip(name: &str) -> TestArchiveFixture {
        let temp = TestDir::new(name);
        temp.create_dir("project");
        temp.write_file("project/readme.txt", b"hello mobile bridge\n");
        let archive = temp.path("archive.zip");
        create_zip_from_path(temp.path("project"), &archive, &ZipCreateOptions::default())
            .expect("fixture zip should be created through zmanager-core");
        TestArchiveFixture { temp, archive }
    }

    struct TestArchiveFixture {
        temp: TestDir,
        archive: PathBuf,
    }

    struct TestDir {
        root: PathBuf,
    }

    impl TestDir {
        fn new(name: &str) -> Self {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "zmanager-mobile-{name}-{}-{now}",
                std::process::id()
            ));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).expect("test temp root should be created");
            Self { root }
        }

        fn path(&self, relative: &str) -> PathBuf {
            self.root.join(relative)
        }

        fn create_dir(&self, relative: &str) {
            fs::create_dir_all(self.path(relative)).expect("test directory should be created");
        }

        fn write_file(&self, relative: &str, contents: &[u8]) {
            let path = self.path(relative);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).expect("test parent should be created");
            }
            fs::write(path, contents).expect("test file should be written");
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}
