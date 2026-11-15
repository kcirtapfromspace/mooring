//! A bounded compatibility adapter for the existing byte-oriented protocol.
//! The only network listener it creates is loopback, and the remote peer can
//! select only a service approved by the host. Noise or SSH still authenticates.
use crate::{
    Cancellation, ConnectionPath, LinkConnection, LinkError, LinkNode, LinkService, Result, Ticket,
    node::bounded, transport,
};
use std::{
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    task::JoinHandle,
};

const MAGIC: &[u8; 4] = b"MLI1";
const BUFFER: usize = 64 * 1024;
fn service_id(service: LinkService) -> u8 {
    match service {
        LinkService::NativeSession => 1,
        LinkService::Ssh => 2,
    }
}

/// Owns the endpoint-to-local-stream lifetime. Dropping it closes the peer
/// connection and cancels the task, including a pending local accept.
pub struct Bridge {
    address: SocketAddr,
    connection: iroh::endpoint::Connection,
    cancel: Cancellation,
    task: Option<JoinHandle<Result<(u64, u64)>>>,
}
impl Bridge {
    pub async fn dial(
        node: Arc<LinkNode>,
        ticket: &Ticket,
        service: LinkService,
        cancel: Cancellation,
    ) -> Result<Self> {
        let limits = node.config.limits;
        Self::dial_with_limits(node, ticket, service, cancel, limits).await
    }
    pub(crate) async fn dial_with_limits(
        node: Arc<LinkNode>,
        ticket: &Ticket,
        service: LinkService,
        cancel: Cancellation,
        limits: crate::ConnectivityLimits,
    ) -> Result<Self> {
        let peer = node.connect_with_limits(ticket, &cancel, limits).await?;
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
            .await
            .map_err(transport)?;
        let address = listener.local_addr().map_err(transport)?;
        let connection = peer.connection.clone();
        let task_cancel = cancel.clone();
        let task = tokio::spawn(async move {
            let cancel = &task_cancel;
            let operation = async {
                let (mut local, _) = bounded(listener.accept(), peer.limits.connect_ms, cancel)
                    .await?
                    .map_err(transport)?;
                local.set_nodelay(true).map_err(transport)?;
                let (mut send, mut recv) = peer.open(cancel).await?;
                let mut hello = [0u8; 5];
                hello[..4].copy_from_slice(MAGIC);
                hello[4] = service_id(service);
                bounded(send.write_all(&hello), peer.limits.connect_ms, cancel)
                    .await?
                    .map_err(transport)?;
                let mut ack = [1u8; 1];
                bounded(recv.read_exact(&mut ack), peer.limits.connect_ms, cancel)
                    .await?
                    .map_err(transport)?;
                if ack != [0] {
                    return Err(LinkError::Unauthorized);
                }
                transfer(&mut local, send, recv, &peer, cancel).await
            };
            let result = bounded(operation, peer.limits.session_ms, cancel).await?;
            peer.close();
            result
        });
        Ok(Self {
            address,
            connection,
            cancel,
            task: Some(task),
        })
    }
    pub fn local_address(&self) -> SocketAddr {
        self.address
    }
    pub fn path(&self) -> ConnectionPath {
        match self.connection.paths().iter().find(|p| p.is_selected()) {
            Some(p) if p.is_ip() => ConnectionPath::Direct,
            Some(p) if p.is_relay() => ConnectionPath::Relayed,
            _ => ConnectionPath::Unknown,
        }
    }
    pub async fn wait(mut self) -> Result<(u64, u64)> {
        self.task
            .take()
            .ok_or(LinkError::Closed)?
            .await
            .map_err(transport)?
    }
}
impl Drop for Bridge {
    fn drop(&mut self) {
        self.cancel.cancel();
        self.connection.close(0u32.into(), b"Mooring bridge closed");
        if let Some(task) = self.task.take() {
            task.abort();
        }
    }
}

/// Accept one approved service. There is deliberately no incoming target
/// address or port: forwarding can reach only this host's loopback service.
pub async fn forward_once(
    peer: LinkConnection,
    service: LinkService,
    cancel: &Cancellation,
) -> Result<(u64, u64)> {
    forward_to(peer, service, service.port(), cancel).await
}
pub(crate) async fn forward_to(
    peer: LinkConnection,
    service: LinkService,
    port: u16,
    cancel: &Cancellation,
) -> Result<(u64, u64)> {
    let operation = async {
        let (mut send, mut recv) = peer.accept_stream(cancel).await?;
        let mut hello = [0u8; 5];
        bounded(recv.read_exact(&mut hello), peer.limits.connect_ms, cancel)
            .await?
            .map_err(transport)?;
        if &hello[..4] != MAGIC || hello[4] != service_id(service) {
            return Err(LinkError::Unauthorized);
        }
        let mut local = bounded(
            TcpStream::connect((Ipv4Addr::LOCALHOST, port)),
            peer.limits.connect_ms,
            cancel,
        )
        .await?
        .map_err(transport)?;
        local.set_nodelay(true).map_err(transport)?;
        bounded(send.write_all(&[0]), peer.limits.connect_ms, cancel)
            .await?
            .map_err(transport)?;
        transfer(&mut local, send, recv, &peer, cancel).await
    };
    let result = bounded(operation, peer.limits.session_ms, cancel).await?;
    peer.close();
    result
}
async fn transfer(
    local: &mut TcpStream,
    mut send: iroh::endpoint::SendStream,
    mut recv: iroh::endpoint::RecvStream,
    peer: &LinkConnection,
    cancel: &Cancellation,
) -> Result<(u64, u64)> {
    let (mut read, mut write) = local.split();
    let counts = tokio::try_join!(
        pump(&mut read, &mut send, peer.limits.stream_idle_ms, cancel),
        pump(&mut recv, &mut write, peer.limits.stream_idle_ms, cancel)
    )?;
    // FIN only queues the final bytes. Keep the connection alive until the peer
    // acknowledges them, otherwise closing QUIC can truncate the last response.
    bounded(send.stopped(), peer.limits.stream_idle_ms, cancel)
        .await?
        .map_err(transport)?;
    Ok(counts)
}
async fn pump(
    reader: &mut (impl AsyncRead + Unpin),
    writer: &mut (impl AsyncWrite + Unpin),
    idle: u64,
    cancel: &Cancellation,
) -> Result<u64> {
    let mut buffer = vec![0u8; BUFFER];
    let mut total = 0u64;
    loop {
        let count = bounded(reader.read(&mut buffer), idle, cancel)
            .await?
            .map_err(transport)?;
        if count == 0 {
            bounded(writer.shutdown(), idle, cancel)
                .await?
                .map_err(transport)?;
            return Ok(total);
        }
        bounded(writer.write_all(&buffer[..count]), idle, cancel)
            .await?
            .map_err(transport)?;
        total = total.saturating_add(count as u64);
    }
}
