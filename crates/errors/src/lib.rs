//! Typed application errors; infrastructure errors retain their source.
use thiserror::Error;

#[derive(Debug, Error)]
#[error("A cat with the name \"{cat_name}\" already exists.")]
pub struct CatAlreadyExistsError {
    pub cat_name: String,
}
impl CatAlreadyExistsError {
    pub const CODE: &'static str = "CAT_ALREADY_EXISTS";
}

#[derive(Debug, Error)]
#[error("Invalid cat name: {reason}")]
pub struct InvalidCatNameError {
    pub reason: String,
}
impl InvalidCatNameError {
    pub const CODE: &'static str = "INVALID_CAT_NAME";
}

#[derive(Debug, Error)]
pub enum Error {
    #[error(transparent)]
    CatAlreadyExists(#[from] CatAlreadyExistsError),
    #[error(transparent)]
    InvalidCatName(#[from] InvalidCatNameError),
    #[error(transparent)]
    Infrastructure(#[from] Box<dyn std::error::Error + Send + Sync>),
}
impl Error {
    pub fn code(&self) -> Option<&'static str> {
        match self {
            Self::CatAlreadyExists(_) => Some(CatAlreadyExistsError::CODE),
            Self::InvalidCatName(_) => Some(InvalidCatNameError::CODE),
            Self::Infrastructure(_) => None,
        }
    }
}
