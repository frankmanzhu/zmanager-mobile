use serde::{Deserialize, Serialize};
use thiserror::Error;

uniffi::include_scaffolding!("zmanager_mobile_core");

#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthcheckResult {
    pub status: String,
    pub engine: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArchiveEntry {
    pub path: String,
    pub is_dir: bool,
    pub size: Option<u64>,
    pub modified_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListArchiveRequest {
    pub archive_path: String,
    pub password: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ListArchiveResult {
    pub entries: Vec<ArchiveEntry>,
}

#[derive(Debug, Error)]
pub enum ZmanagerMobileError {
    #[error("invalid request")]
    InvalidRequest,
    #[error("engine unavailable")]
    EngineUnavailable,
    #[error("archive error")]
    ArchiveError,
}

pub fn healthcheck() -> HealthcheckResult {
    HealthcheckResult {
        status: "ok".to_string(),
        engine: "zmanager-mobile-core placeholder".to_string(),
    }
}

pub fn list_archive(request: ListArchiveRequest) -> Result<ListArchiveResult, ZmanagerMobileError> {
    if request.archive_path.trim().is_empty() {
        return Err(ZmanagerMobileError::InvalidRequest);
    }

    // TODO: Call zmanager-core once the mobile bridge dependency is wired.
    Ok(ListArchiveResult {
        entries: Vec::new(),
    })
}

#[allow(non_snake_case)]
pub fn listArchive(request: ListArchiveRequest) -> ListArchiveResult {
    list_archive(request).unwrap_or_else(|_| ListArchiveResult {
        entries: Vec::new(),
    })
}
