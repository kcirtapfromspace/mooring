use crate::{
    ConnectionPath, ConnectivityLimits, ConnectivityMode, EndpointAddr, EndpointId, LinkError,
    RelayUrl, Result, SecretKey, Ticket, transport,
};
use iroh::{
    Endpoint, RelayConfig, RelayMap, RelayMode,
    endpoint::{Connection, QuicTransportConfig, RecvStream, SendStream, VarInt, presets},
};
use std::{
    future::Future,
    net::{IpAddr, SocketAddr},
    time::Duration,
};
use tokio::sync::watch;

pub const ALPN: &[u8] = b"mooring/link/1";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    pub mode: ConnectivityMode,
    pub relay: Option<RelayUrl>,
    pub bind: Option<SocketAddr>,
    pub limits: ConnectivityLimits,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            mode: ConnectivityMode::DirectOnly,
            relay: None,
            bind: None,
            limits: Default::default(),
        }
    }
}
impl Config {
    fn builder(&self, key: SecretKey) -> Result<iroh::endpoint::Builder> {
        self.limits.validate().map_err(LinkError::Invalid)?;
        if self.mode != ConnectivityMode::DirectOnly && self.relay.is_none() {
            return Err(LinkError::Invalid(
                "Select an explicit relay for internet connectivity",
            ));
        }
        if let Some(url) = &self.relay {
            validate_relay(url)?;
        }
        let quic = QuicTransportConfig::builder()
            .max_concurrent_bidi_streams(VarInt::from_u32(1))
            .max_concurrent_uni_streams(VarInt::from_u32(0))
            .stream_receive_window(VarInt::from_u32(1024 * 1024))
            .receive_window(VarInt::from_u32(2 * 1024 * 1024))
            .send_window(2 * 1024 * 1024)
            .max_idle_timeout(Some(
                Duration::from_millis(self.limits.stream_idle_ms)
                    .try_into()
                    .map_err(transport)?,
            ))
            .keep_alive_interval(Duration::from_secs(5))
            .build();
        let mut builder = Endpoint::builder(presets::Minimal)
            .secret_key(key)
            .alpns(vec![ALPN.to_vec()])
            .clear_address_lookup()
            .transport_config(quic);
        if let Some(addr) = self.bind {
            builder = builder
                .clear_ip_transports()
                .bind_addr(addr)
                .map_err(transport)?;
        }
        builder = if self.mode == ConnectivityMode::DirectOnly {
            builder.relay_mode(RelayMode::Disabled)
        } else {
            builder.relay_mode(RelayMode::Custom(RelayMap::from_iter([RelayConfig::new(
                self.relay.clone().expect("checked relay"),
                None,
            )])))
        };
        if self.mode == ConnectivityMode::RelayOnly {
            builder = builder.clear_ip_transports();
        }
        Ok(builder)
    }
}

pub(crate) fn validate_relay(url: &RelayUrl) -> Result<()> {
    let local = url
        .host_str()
        .and_then(|h| h.trim_matches(['[', ']']).parse::<IpAddr>().ok())
        .is_some_and(|ip| ip.is_loopback());
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        return Err(LinkError::Invalid(
            "Relays require HTTPS; HTTP is only accepted on loopback",
        ));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(LinkError::Invalid("Relay URLs cannot contain credentials"));
    }
    Ok(())
}

/// Cancellation is sticky even if it precedes an observer subscribing.
#[derive(Clone, Debug)]
pub struct Cancellation(watch::Sender<bool>);
impl Default for Cancellation {
    fn default() -> Self {
        Self(watch::channel(false).0)
    }
}
impl Cancellation {
    pub fn cancel(&self) {
        self.0.send_replace(true);
    }
    pub async fn cancelled(&self) {
        let mut receiver = self.0.subscribe();
        if *receiver.borrow() {
            return;
        }
        let _ = receiver.wait_for(|value| *value).await;
    }
}

pub struct LinkNode {
    pub(crate) endpoint: Endpoint,
    pub(crate) config: Config,
}
impl LinkNode {
    pub async fn bind(key: SecretKey, config: Config) -> Result<Self> {
        let endpoint = config.builder(key)?.bind().await.map_err(transport)?;
        Ok(Self { endpoint, config })
    }
    #[cfg(test)]
    pub(crate) async fn bind_test(key: SecretKey, config: Config) -> Result<Self> {
        let endpoint = config
            .builder(key)?
            .ca_tls_config(iroh_relay::tls::CaTlsConfig::insecure_skip_verify())
            .bind()
            .await
            .map_err(transport)?;
        Ok(Self { endpoint, config })
    }
    pub fn id(&self) -> EndpointId {
        self.endpoint.id()
    }
    pub fn address(&self) -> EndpointAddr {
        self.endpoint.addr()
    }
    pub async fn ticket(&self, now: u64) -> Result<Ticket> {
        if self.config.mode != ConnectivityMode::DirectOnly {
            tokio::time::timeout(
                Duration::from_millis(self.config.limits.connect_ms),
                self.endpoint.online(),
            )
            .await
            .map_err(|_| LinkError::Timeout)?;
        }
        Ticket::new(self.address(), now)
    }
    pub async fn connect(&self, ticket: &Ticket, cancel: &Cancellation) -> Result<LinkConnection> {
        self.connect_with_limits(ticket, cancel, self.config.limits)
            .await
    }
    pub(crate) async fn connect_with_limits(
        &self,
        ticket: &Ticket,
        cancel: &Cancellation,
        limits: ConnectivityLimits,
    ) -> Result<LinkConnection> {
        limits.validate().map_err(LinkError::Invalid)?;
        let connection = bounded(
            self.endpoint.connect(ticket.endpoint.clone(), ALPN),
            limits.connect_ms,
            cancel,
        )
        .await?
        .map_err(transport)?;
        Ok(LinkConnection { connection, limits })
    }
    pub async fn accept(
        &self,
        allowed: &[EndpointId],
        cancel: &Cancellation,
    ) -> Result<LinkConnection> {
        if allowed.is_empty() || allowed.len() > mooring_core::connectivity::MAX_PEERS {
            return Err(LinkError::Invalid(
                "Provide a bounded list of approved endpoint IDs",
            ));
        }
        let incoming = bounded(
            self.endpoint.accept(),
            self.config.limits.connect_ms,
            cancel,
        )
        .await?
        .ok_or(LinkError::Closed)?;
        let connection = bounded(
            async { incoming.await },
            self.config.limits.connect_ms,
            cancel,
        )
        .await?
        .map_err(transport)?;
        if !allowed.contains(&connection.remote_id()) {
            connection.close(1u32.into(), b"not approved");
            return Err(LinkError::Unauthorized);
        }
        Ok(LinkConnection {
            connection,
            limits: self.config.limits,
        })
    }
    pub async fn close(&self) {
        let _ = tokio::time::timeout(Duration::from_secs(3), self.endpoint.close()).await;
    }
}

pub struct LinkConnection {
    pub(crate) connection: Connection,
    pub(crate) limits: ConnectivityLimits,
}
impl LinkConnection {
    pub fn peer(&self) -> EndpointId {
        self.connection.remote_id()
    }
    pub fn path(&self) -> ConnectionPath {
        match self.connection.paths().iter().find(|p| p.is_selected()) {
            Some(p) if p.is_ip() => ConnectionPath::Direct,
            Some(p) if p.is_relay() => ConnectionPath::Relayed,
            _ => ConnectionPath::Unknown,
        }
    }
    pub async fn open(&self, cancel: &Cancellation) -> Result<(SendStream, RecvStream)> {
        bounded(self.connection.open_bi(), self.limits.connect_ms, cancel)
            .await?
            .map_err(transport)
    }
    pub async fn accept_stream(&self, cancel: &Cancellation) -> Result<(SendStream, RecvStream)> {
        bounded(self.connection.accept_bi(), self.limits.connect_ms, cancel)
            .await?
            .map_err(transport)
    }
    pub fn close(&self) {
        self.connection.close(0u32.into(), b"Mooring link ended");
    }
}

pub(crate) async fn bounded<T>(
    future: impl Future<Output = T>,
    ms: u64,
    cancel: &Cancellation,
) -> Result<T> {
    tokio::select! {
        biased;
        _ = cancel.cancelled() => Err(LinkError::Cancelled),
        value = tokio::time::timeout(Duration::from_millis(ms),future) => value.map_err(|_|LinkError::Timeout),
    }
}

impl Drop for LinkConnection {
    fn drop(&mut self) {
        self.close();
    }
}
