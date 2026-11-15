//! Synchronous ownership boundary for Mooring's existing network threads/C ABI.
//! There is one bounded Tokio runtime per process; Swift never owns async tasks.
use crate::{
    Bridge, Cancellation, Config, ConnectionPath, EndpointId, LinkError, LinkNode, LinkService,
    Result, SecretKey, Ticket,
};
use std::{
    net::SocketAddr,
    sync::{
        Arc, Mutex, OnceLock, Weak,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    runtime::Runtime,
    task::{JoinHandle, JoinSet},
};

pub(crate) fn runtime() -> Result<Arc<Runtime>> {
    static RUNTIME: OnceLock<std::result::Result<Arc<Runtime>, String>> = OnceLock::new();
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .thread_name("mooring-link")
                .enable_all()
                .build()
                .map(Arc::new)
                .map_err(|e| e.to_string())
        })
        .clone()
        .map_err(LinkError::Transport)
}
pub fn unix_seconds() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|v| v.as_secs())
        .map_err(|_| LinkError::Invalid("System clock precedes Unix time"))
}

#[derive(Default)]
struct Closing {
    done: Mutex<bool>,
    wake: std::sync::Condvar,
}
struct PoolEntry {
    node: Weak<ManagedNode>,
    closing: Arc<Closing>,
}
fn pool() -> &'static Mutex<std::collections::HashMap<EndpointId, PoolEntry>> {
    static NODES: OnceLock<Mutex<std::collections::HashMap<EndpointId, PoolEntry>>> =
        OnceLock::new();
    NODES.get_or_init(Default::default)
}
struct ManagedNode {
    hosting: AtomicBool,
    node: Arc<LinkNode>,
    runtime: Arc<Runtime>,
    closing: Arc<Closing>,
}
impl Drop for ManagedNode {
    fn drop(&mut self) {
        let node = self.node.clone();
        let closing = self.closing.clone();
        self.runtime.spawn(async move {
            node.close().await;
            if let Ok(mut done) = closing.done.lock() {
                *done = true;
                closing.wake.notify_all();
            }
        });
    }
}
fn acquire(key: SecretKey, config: Config) -> Result<Arc<ManagedNode>> {
    let mut nodes = pool().lock().map_err(|_| LinkError::Closed)?;
    nodes.retain(|_, value| {
        value.node.strong_count() != 0 || !value.closing.done.lock().is_ok_and(|d| *d)
    });
    if let Some(entry) = nodes.get(&key.public()) {
        if let Some(existing) = entry.node.upgrade() {
            let mut transport_config = existing.node.config.clone();
            transport_config.limits.connect_ms = config.limits.connect_ms;
            if transport_config != config {
                return Err(LinkError::Invalid(
                    "This transport identity already uses a different configuration",
                ));
            }
            return Ok(existing);
        }
        // Do not register the same public key at a relay until the previous
        // endpoint has closed. Otherwise an old close can evict a new session.
        let done = entry.closing.done.lock().map_err(|_| LinkError::Closed)?;
        let (done, _) = entry
            .closing
            .wake
            .wait_timeout_while(done, Duration::from_secs(4), |done| !*done)
            .map_err(|_| LinkError::Closed)?;
        if !*done {
            return Err(LinkError::Timeout);
        }
    }
    if nodes.len() >= mooring_core::connectivity::MAX_PEERS {
        return Err(LinkError::Invalid("Too many active internet endpoints"));
    }
    let runtime = runtime()?;
    let node = Arc::new(runtime.block_on(LinkNode::bind(key, config))?);
    let closing = Arc::new(Closing::default());
    let shared = Arc::new(ManagedNode {
        hosting: AtomicBool::new(false),
        node,
        runtime,
        closing: closing.clone(),
    });
    nodes.insert(
        shared.node.id(),
        PoolEntry {
            node: Arc::downgrade(&shared),
            closing,
        },
    );
    Ok(shared)
}

pub struct InternetServer {
    hosting: bool,
    _lease: Arc<ManagedNode>,
    runtime: Arc<Runtime>,
    node: Arc<LinkNode>,
    cancel: Cancellation,
    task: Option<JoinHandle<Result<()>>>,
}
impl InternetServer {
    pub fn start(
        key: SecretKey,
        config: Config,
        allowed: Vec<EndpointId>,
        service: LinkService,
    ) -> Result<Self> {
        Self::start_at(key, config, allowed, service, service.port())
    }
    /// The local port is chosen by the hosting app, never by an incoming peer.
    /// Mooring passes the port of its already-authenticating native listener.
    pub fn start_native(
        key: SecretKey,
        config: Config,
        allowed: Vec<EndpointId>,
        port: u16,
    ) -> Result<Self> {
        Self::start_at(key, config, allowed, LinkService::NativeSession, port)
    }
    fn start_at(
        key: SecretKey,
        config: Config,
        allowed: Vec<EndpointId>,
        service: LinkService,
        port: u16,
    ) -> Result<Self> {
        if allowed.is_empty() || allowed.len() > mooring_core::connectivity::MAX_PEERS || port == 0
        {
            return Err(LinkError::Invalid(
                "Provide an approved endpoint and a valid host service",
            ));
        }
        let lease = acquire(key, config)?;
        if lease
            .hosting
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(LinkError::Invalid(
                "This transport identity already hosts a service",
            ));
        }
        let runtime = lease.runtime.clone();
        let node = lease.node.clone();
        let cancel = Cancellation::default();
        let task = {
            let node = node.clone();
            let cancel = cancel.clone();
            runtime.spawn(async move {
                let mut tasks = JoinSet::new();
                let mut total = 0;
                while total < 64 {
                    if tasks.len() >= mooring_core::connectivity::MAX_CONNECTIONS {
                        tokio::select! {
                            biased;
                            _ = cancel.cancelled() => break,
                            _ = tasks.join_next() => {},
                        }
                        continue;
                    }
                    // Finishing another stream must not cancel a peer's TLS
                    // handshake. Retain this accept future while reaping tasks.
                    let incoming = node.accept(&allowed, &cancel);
                    tokio::pin!(incoming);
                    let accepted = loop {
                        tokio::select! {
                            biased;
                            _ = cancel.cancelled() => break Err(LinkError::Cancelled),
                            _ = tasks.join_next(), if !tasks.is_empty() => {},
                            accepted = &mut incoming => break accepted,
                        }
                    };
                    match accepted {
                        Ok(peer) => {
                            total += 1;
                            let cancel = cancel.clone();
                            tasks.spawn(async move {
                                crate::bridge::forward_to(peer, service, port, &cancel).await
                            });
                        }
                        Err(LinkError::Timeout) => {}
                        Err(LinkError::Cancelled) => break,
                        Err(LinkError::Unauthorized | LinkError::Transport(_)) => {
                            total += 1;
                        }
                        Err(error) => return Err(error),
                    }
                }
                while !tasks.is_empty() {
                    tokio::select! {
                        biased;
                        _ = cancel.cancelled() => break,
                        _ = tasks.join_next() => {},
                    }
                }
                tasks.abort_all();
                while tasks.join_next().await.is_some() {}
                Ok(())
            })
        };
        Ok(Self {
            hosting: true,
            _lease: lease,
            runtime,
            node,
            cancel,
            task: Some(task),
        })
    }
    pub fn id(&self) -> EndpointId {
        self.node.id()
    }
    pub fn ticket(&self) -> Result<Ticket> {
        self.runtime.block_on(self.node.ticket(unix_seconds()?))
    }
    /// CLI lifetime on the same runtime as the network tasks.
    pub fn wait_for_shutdown(&mut self) {
        let finished = self.runtime.block_on(async {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => false,
                _ = tokio::time::sleep(Duration::from_millis(self.node.config.limits.session_ms)) => false,
                _ = async { if let Some(task) = self.task.as_mut() { let _ = task.await; } } => true,
            }
        });
        if finished {
            self.task.take();
        }
        self.stop();
    }
    pub fn stop(&mut self) {
        self.cancel.cancel();
        if let Some(mut task) = self.task.take()
            && self
                .runtime
                .block_on(async { tokio::time::timeout(Duration::from_secs(4), &mut task).await })
                .is_err()
        {
            task.abort();
        }
        if self.hosting {
            self.hosting = false;
            self._lease.hosting.store(false, Ordering::Release);
        }
    }
}
impl Drop for InternetServer {
    fn drop(&mut self) {
        self.stop();
    }
}

pub struct InternetBridge {
    _lease: Arc<ManagedNode>,
    runtime: Arc<Runtime>,
    bridge: Option<Bridge>,
}
impl InternetBridge {
    pub fn dial(
        key: SecretKey,
        config: Config,
        ticket: &str,
        service: LinkService,
    ) -> Result<Self> {
        let ticket = Ticket::parse(ticket, unix_seconds()?)?;
        let limits = config.limits;
        let lease = acquire(key, config)?;
        let runtime = lease.runtime.clone();
        let node = lease.node.clone();
        let bridge = runtime.block_on(Bridge::dial_with_limits(
            node.clone(),
            &ticket,
            service,
            Cancellation::default(),
            limits,
        ))?;
        Ok(Self {
            _lease: lease,
            runtime,
            bridge: Some(bridge),
        })
    }
    pub fn local_address(&self) -> SocketAddr {
        self.bridge.as_ref().expect("live bridge").local_address()
    }
    pub fn path(&self) -> ConnectionPath {
        self.bridge
            .as_ref()
            .map_or(ConnectionPath::Unknown, Bridge::path)
    }
    pub fn wait(mut self) -> Result<(u64, u64)> {
        self.runtime
            .block_on(self.bridge.take().ok_or(LinkError::Closed)?.wait())
    }
}
impl Drop for InternetBridge {
    fn drop(&mut self) {
        self.bridge.take();
        // The shared endpoint closes only when its final host/viewer lease ends.
    }
}
