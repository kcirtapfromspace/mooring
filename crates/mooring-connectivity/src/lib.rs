//! Explicit, account-free reachability beneath Mooring's existing authentication.
//! No public DNS publisher, routing table, password handling, or implicit grants.
pub mod blocking;
mod bridge;
mod node;
#[cfg(unix)]
pub mod ssh_session;
mod ticket;
pub use bridge::{Bridge, forward_once};
pub use iroh::{EndpointAddr, EndpointId, RelayUrl, SecretKey};
pub use mooring_core::connectivity::{
    ConnectionPath, ConnectivityLimits, ConnectivityMode, LinkService,
};
pub use node::{Cancellation, Config, LinkConnection, LinkNode};
use std::fmt;
pub use ticket::Ticket;

#[derive(Debug)]
pub enum LinkError {
    Invalid(&'static str),
    Unauthorized,
    Timeout,
    Cancelled,
    Closed,
    Transport(String),
}
impl fmt::Display for LinkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(text) => f.write_str(text),
            Self::Unauthorized => {
                f.write_str("This endpoint is not approved for the internet link")
            }
            Self::Timeout => f.write_str("The internet link deadline expired"),
            Self::Cancelled => f.write_str("The internet link was cancelled"),
            Self::Closed => f.write_str("The internet link closed"),
            Self::Transport(text) => write!(f, "Internet transport: {text}"),
        }
    }
}
impl std::error::Error for LinkError {}
pub type Result<T> = std::result::Result<T, LinkError>;
pub(crate) fn transport(error: impl fmt::Display) -> LinkError {
    LinkError::Transport(error.to_string())
}
#[cfg(test)]
mod tests;
