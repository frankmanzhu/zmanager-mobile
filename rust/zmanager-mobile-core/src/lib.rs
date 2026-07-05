use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;
use zmanager_core::archive_browser::{
    self, ArchiveBrowserError, BrowserEntryKind, BrowserListOptions,
};
use zmanager_core::libarchive_backend::LibarchiveError;
use zmanager_core::raw_stream_backend::RawStreamError;
use zmanager_core::sevenz_backend::SevenZError;
use zmanager_core::tar_zst_backend::TarZstdError;
use zmanager_core::tzap_backend::TzapError;
use zmanager_core::zip_backend::ZipBackendError;

uniffi::include_scaffolding!("zmanager_mobile_core");

const ERROR_INVALID_REQUEST: &str = "invalid_request";
const ERROR_NOT_FOUND: &str = "not_found";
const ERROR_PASSWORD_REQUIRED: &str = "password_required";
const ERROR_INVALID_PASSWORD: &str = "invalid_password";
const ERROR_UNSAFE_ARCHIVE: &str = "unsafe_archive";
const ERROR_IO_ERROR: &str = "io_error";
const ERROR_UNSUPPORTED_FORMAT: &str = "unsupported_format";
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

    fn assert_bridge_error_code(error: ZmanagerMobileError, expected: &str) {
        match error {
            ZmanagerMobileError::Bridge { code, .. } => assert_eq!(code, expected),
        }
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
