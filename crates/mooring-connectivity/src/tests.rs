use super::*;
use std::{
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
fn now() -> u64 {
    1_800_000_000
}
fn direct() -> Config {
    Config {
        bind: Some(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))),
        ..Default::default()
    }
}
async fn exchange(
    server: Arc<LinkNode>,
    client: Arc<LinkNode>,
    expected: ConnectionPath,
) -> Result<()> {
    let ticket = server.ticket(now()).await?;
    let allowed = client.id();
    let task = tokio::spawn(async move {
        let cancel = Cancellation::default();
        let conn = server.accept(&[allowed], &cancel).await?;
        let (mut send, mut recv) = conn.accept_stream(&cancel).await?;
        let input = tokio::time::timeout(Duration::from_secs(5), recv.read_to_end(1024 * 1024))
            .await
            .map_err(|_| LinkError::Timeout)?
            .map_err(transport)?;
        assert_eq!(input, vec![42; 256 * 1024]);
        assert_eq!(conn.path(), expected);
        send.write_all(&input).await.map_err(transport)?;
        send.finish().map_err(transport)?;
        let _ = tokio::time::timeout(Duration::from_secs(5), send.stopped()).await;
        // The caller retains the node until the exchange completes.
        Ok::<_, LinkError>(())
    });
    let cancel = Cancellation::default();
    let conn = client.connect(&ticket, &cancel).await?;
    let (mut send, mut recv) = conn.open(&cancel).await?;
    send.write_all(&vec![42; 256 * 1024])
        .await
        .map_err(transport)?;
    send.finish().map_err(transport)?;
    let echoed = tokio::time::timeout(Duration::from_secs(5), recv.read_to_end(1024 * 1024))
        .await
        .map_err(|_| LinkError::Timeout)?
        .map_err(transport)?;
    assert_eq!(echoed, vec![42; 256 * 1024]);
    assert_eq!(conn.path(), expected);
    task.await.map_err(transport)??;
    conn.close();
    Ok(())
}
#[tokio::test]
async fn direct_connection_transfers_bounded_data_without_discovery_or_relay() -> Result<()> {
    let server = Arc::new(LinkNode::bind(SecretKey::generate(), direct()).await?);
    let client = Arc::new(LinkNode::bind(SecretKey::generate(), direct()).await?);
    exchange(server.clone(), client.clone(), ConnectionPath::Direct).await?;
    client.close().await;
    server.close().await;
    Ok(())
}
#[tokio::test]
async fn forced_relay_has_no_ip_transport_and_transfers_real_data() -> Result<()> {
    let (_, url, _relay) = iroh::test_utils::run_relay_server_with(false)
        .await
        .map_err(transport)?;
    let config = Config {
        mode: ConnectivityMode::RelayOnly,
        relay: Some(url),
        ..Default::default()
    };
    let server = Arc::new(LinkNode::bind_test(SecretKey::generate(), config.clone()).await?);
    let client = Arc::new(LinkNode::bind_test(SecretKey::generate(), config).await?);
    assert!(server.address().ip_addrs().next().is_none());
    exchange(server.clone(), client.clone(), ConnectionPath::Relayed).await?;
    client.close().await;
    server.close().await;
    Ok(())
}
#[tokio::test]
async fn endpoint_identity_is_checked_before_a_stream_is_served() -> Result<()> {
    let server = Arc::new(LinkNode::bind(SecretKey::generate(), direct()).await?);
    let client = LinkNode::bind(SecretKey::generate(), direct()).await?;
    let ticket = server.ticket(now()).await?;
    let other = SecretKey::generate().public();
    let task = {
        let server = server.clone();
        tokio::spawn(async move { server.accept(&[other], &Cancellation::default()).await })
    };
    let conn = client.connect(&ticket, &Cancellation::default()).await?;
    assert!(matches!(
        task.await.map_err(transport)?,
        Err(LinkError::Unauthorized)
    ));
    conn.close();
    client.close().await;
    server.close().await;
    Ok(())
}
#[tokio::test]
async fn cancellation_is_sticky_and_accept_deadlines_are_bounded() -> Result<()> {
    let node = LinkNode::bind(
        SecretKey::generate(),
        Config {
            limits: ConnectivityLimits {
                connect_ms: 100,
                ..Default::default()
            },
            ..direct()
        },
    )
    .await?;
    let cancelled = Cancellation::default();
    cancelled.cancel();
    assert!(matches!(
        node.accept(&[node.id()], &cancelled).await,
        Err(LinkError::Cancelled)
    ));
    assert!(matches!(
        node.accept(&[node.id()], &Cancellation::default()).await,
        Err(LinkError::Timeout)
    ));
    node.close().await;
    Ok(())
}
#[test]
fn tickets_expire_and_cannot_create_unbounded_or_unversioned_inputs() {
    let addr = EndpointAddr::new(SecretKey::generate().public())
        .with_ip_addr("127.0.0.1:1234".parse().unwrap());
    let encoded = Ticket::new(addr, now()).unwrap().encode().unwrap();
    assert!(Ticket::parse(&encoded, now()).is_ok());
    assert!(Ticket::parse(&encoded, now() + 601).is_err());
    assert!(Ticket::parse(&encoded.replace("\"version\":1", "\"version\":2"), now()).is_err());
    assert!(Ticket::parse(&"x".repeat(8193), now()).is_err());
    assert!(Ticket::parse(&encoded, now() - 601).is_err());
}
#[tokio::test]
async fn bridge_carries_an_existing_byte_protocol_and_cleans_up() -> Result<()> {
    let backend = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(transport)?;
    let port = backend.local_addr().map_err(transport)?.port();
    let echo = tokio::spawn(async move {
        let (mut stream, _) = backend.accept().await.unwrap();
        let (mut r, mut w) = stream.split();
        tokio::io::copy(&mut r, &mut w).await.unwrap();
        w.shutdown().await.unwrap();
    });
    let server = Arc::new(LinkNode::bind(SecretKey::generate(), direct()).await?);
    let client = Arc::new(LinkNode::bind(SecretKey::generate(), direct()).await?);
    let ticket = server.ticket(now()).await?;
    let allowed = client.id();
    let host = {
        let server = server.clone();
        tokio::spawn(async move {
            let cancel = Cancellation::default();
            let peer = server.accept(&[allowed], &cancel).await?;
            crate::bridge::forward_to(peer, LinkService::NativeSession, port, &cancel).await
        })
    };
    let bridge = Bridge::dial(
        client.clone(),
        &ticket,
        LinkService::NativeSession,
        Cancellation::default(),
    )
    .await?;
    let address = bridge.local_address();
    assert!(address.ip().is_loopback());
    let mut local = tokio::net::TcpStream::connect(address)
        .await
        .map_err(transport)?;
    local
        .write_all(b"existing Mooring framing remains opaque")
        .await
        .map_err(transport)?;
    local.shutdown().await.map_err(transport)?;
    let mut output = vec![];
    tokio::time::timeout(Duration::from_secs(5), local.read_to_end(&mut output))
        .await
        .map_err(|_| LinkError::Timeout)?
        .map_err(transport)?;
    assert_eq!(output, b"existing Mooring framing remains opaque");
    bridge.wait().await?;
    host.await.map_err(transport)??;
    echo.await.map_err(transport)?;
    assert!(tokio::net::TcpStream::connect(address).await.is_err());
    client.close().await;
    server.close().await;
    Ok(())
}

#[test]
fn blocking_bridge_closes_its_unclaimed_loopback_listener() -> Result<()> {
    use crate::blocking::{InternetBridge, InternetServer};
    let backend = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(transport)?;
    let port = backend.local_addr().unwrap().port();
    let server_key = SecretKey::generate();
    let client_key = SecretKey::generate();
    let mut server =
        InternetServer::start_native(server_key, direct(), vec![client_key.public()], port)?;
    let ticket = server.ticket()?.encode()?;
    let bridge = InternetBridge::dial(
        client_key,
        Config::default(),
        &ticket,
        LinkService::NativeSession,
    )?;
    let address = bridge.local_address();
    drop(bridge);
    server.stop();
    // Task abortion is asynchronous, but must release the listener promptly.
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while std::net::TcpStream::connect(address).is_ok() {
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}

#[test]
fn stopping_a_host_role_preserves_a_viewer_using_the_same_identity() -> Result<()> {
    use crate::blocking::{InternetBridge, InternetServer};
    use std::io::{Read, Write};
    let backend = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(transport)?;
    let port = backend.local_addr().unwrap().port();
    let echo = std::thread::spawn(move || {
        let (mut socket, _) = backend.accept().unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        for _ in 0..2 {
            let mut bytes = [0u8; 4];
            socket.read_exact(&mut bytes).unwrap();
            socket.write_all(&bytes).unwrap();
        }
    });
    let a = SecretKey::generate();
    let b = SecretKey::generate();
    let mut host_a = Some(InternetServer::start_native(
        a.clone(),
        direct(),
        vec![b.public()],
        port,
    )?);
    assert!(InternetServer::start_native(a.clone(), direct(), vec![b.public()], port).is_err());
    let mut host_b = InternetServer::start_native(b, direct(), vec![a.public()], port)?;
    let ticket = host_b.ticket()?.encode()?;
    let bridge = InternetBridge::dial(a, direct(), &ticket, LinkService::NativeSession)?;
    let mut socket = std::net::TcpStream::connect(bridge.local_address()).map_err(transport)?;
    socket
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    for step in 0..2 {
        if step == 1 {
            drop(host_a.take());
        }
        socket.write_all(b"ping").map_err(transport)?;
        let mut bytes = [0u8; 4];
        socket.read_exact(&mut bytes).map_err(transport)?;
        assert_eq!(&bytes, b"ping");
    }
    drop(socket);
    drop(bridge);
    host_b.stop();
    echo.join().unwrap();
    Ok(())
}

#[test]
fn locators_reject_insecure_or_credential_bearing_relay_urls() {
    for url in ["http://example.com", "https://name:secret@example.com"] {
        let endpoint =
            EndpointAddr::new(SecretKey::generate().public()).with_relay_url(url.parse().unwrap());
        let encoded = Ticket::new(endpoint, now()).unwrap().encode().unwrap();
        assert!(Ticket::parse(&encoded, now()).is_err());
    }
}

#[tokio::test]
async fn selecting_an_unapproved_service_never_reaches_the_backend() -> Result<()> {
    let backend = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(transport)?;
    let server = Arc::new(LinkNode::bind(SecretKey::generate(), direct()).await?);
    let client = Arc::new(LinkNode::bind(SecretKey::generate(), direct()).await?);
    let allowed = client.id();
    let ticket = server.ticket(now()).await?;
    let port = backend.local_addr().unwrap().port();
    let host = {
        let server = server.clone();
        tokio::spawn(async move {
            let cancel = Cancellation::default();
            let peer = server.accept(&[allowed], &cancel).await?;
            crate::bridge::forward_to(peer, LinkService::NativeSession, port, &cancel).await
        })
    };
    let bridge = Bridge::dial(
        client.clone(),
        &ticket,
        LinkService::Ssh,
        Cancellation::default(),
    )
    .await?;
    let _socket = tokio::net::TcpStream::connect(bridge.local_address())
        .await
        .map_err(transport)?;
    assert!(matches!(
        host.await.map_err(transport)?,
        Err(LinkError::Unauthorized)
    ));
    assert!(
        tokio::time::timeout(Duration::from_millis(100), backend.accept())
            .await
            .is_err()
    );
    drop(bridge);
    client.close().await;
    server.close().await;
    Ok(())
}
