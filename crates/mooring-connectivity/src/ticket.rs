use crate::{EndpointAddr, LinkError, Result};
use mooring_core::connectivity::{MAX_TICKET_BYTES, TICKET_LIFETIME_SECONDS};
use serde::{Deserialize, Serialize};

/// Public locator only. Knowing this does not bypass endpoint approval, Noise
/// pairing or SSH. A locator is short-lived because network addresses change.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ticket {
    version: u8,
    pub endpoint: EndpointAddr,
    expires: u64,
}
impl Ticket {
    pub fn new(endpoint: EndpointAddr, now: u64) -> Result<Self> {
        let expires = now
            .checked_add(TICKET_LIFETIME_SECONDS)
            .ok_or(LinkError::Invalid("Invalid ticket clock"))?;
        Ok(Self {
            version: 1,
            endpoint,
            expires,
        })
    }
    pub fn encode(&self) -> Result<String> {
        let value = serde_json::to_string(self).map_err(crate::transport)?;
        if value.len() > MAX_TICKET_BYTES {
            return Err(LinkError::Invalid("Internet locator exceeds its limit"));
        }
        Ok(value)
    }
    pub fn parse(value: &str, now: u64) -> Result<Self> {
        if value.len() > MAX_TICKET_BYTES {
            return Err(LinkError::Invalid("Internet locator exceeds its limit"));
        }
        let ticket: Self = serde_json::from_str(value)
            .map_err(|_| LinkError::Invalid("Invalid internet locator"))?;
        if ticket.version != 1
            || ticket.expires <= now
            || ticket.expires > now.saturating_add(TICKET_LIFETIME_SECONDS)
            || ticket.endpoint.addrs.is_empty()
            || ticket.endpoint.addrs.len() > 16
        {
            return Err(LinkError::Invalid(
                "Internet locator is expired or unsupported",
            ));
        }
        if ticket.endpoint.relay_urls().count() > 1 {
            return Err(LinkError::Invalid("A locator can select only one relay"));
        }
        for url in ticket.endpoint.relay_urls() {
            crate::node::validate_relay(url)?;
        }
        if ticket
            .endpoint
            .ip_addrs()
            .any(|addr| addr.port() == 0 || addr.ip().is_unspecified() || addr.ip().is_multicast())
        {
            return Err(LinkError::Invalid("Invalid internet endpoint address"));
        }
        Ok(ticket)
    }
}
