use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::Arc;

use once_cell::sync::OnceCell;
use tokio::runtime::Runtime;
use tokio::net::TcpListener;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use arti_client::{TorClient, TorClientConfig};
use arti_client::config::CfgPath;
use tor_rtcompat::PreferredRuntime;

/// Global Tor client instance
static TOR_CLIENT: OnceCell<Arc<TorClient<PreferredRuntime>>> = OnceCell::new();
static RUNNING: AtomicBool = AtomicBool::new(false);
static SOCKS_PORT: AtomicU16 = AtomicU16::new(0);
static RUNTIME: OnceCell<Runtime> = OnceCell::new();

fn get_runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .build()
            .expect("Failed to create Tokio runtime")
    })
}

/// Get iOS-compatible cache directory for Arti state data.
/// Falls back to /tmp/arti if no proper directory found.
fn get_state_dir() -> String {
    // Try iOS Library/Caches directory
    #[cfg(target_os = "ios")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            let path = format!("{}/Library/Caches/arti", home.to_string_lossy());
            let _ = std::fs::create_dir_all(&path);
            return path;
        }
    }
    // Fallback
    let path = "/tmp/arti_state".to_string();
    let _ = std::fs::create_dir_all(&path);
    path
}

fn get_cache_dir() -> String {
    #[cfg(target_os = "ios")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            let path = format!("{}/Library/Caches/arti_cache", home.to_string_lossy());
            let _ = std::fs::create_dir_all(&path);
            return path;
        }
    }
    let path = "/tmp/arti_cache".to_string();
    let _ = std::fs::create_dir_all(&path);
    path
}

/// Start the Tor client and SOCKS5 proxy.
/// Returns the SOCKS5 port on success, 0 on failure.
#[no_mangle]
pub extern "C" fn plug_tor_start() -> u16 {
    if RUNNING.load(Ordering::SeqCst) {
        return SOCKS_PORT.load(Ordering::SeqCst);
    }

    let rt = get_runtime();

    // Bootstrap Tor client with iOS-compatible directories
    let client = match rt.block_on(async {
        let state_dir = get_state_dir();
        let cache_dir = get_cache_dir();

        let mut builder = TorClientConfig::builder();
        builder.storage()
            .state_dir(CfgPath::new_literal(state_dir))
            .cache_dir(CfgPath::new_literal(cache_dir));
        // Increase connect timeout — Tor circuits can be slow
        builder.stream_timeouts()
            .connect_timeout(std::time::Duration::from_secs(30));

        let config = builder.build()
            .map_err(|e| format!("config: {}", e))?;

        TorClient::create_bootstrapped(config)
            .await
            .map_err(|e| format!("bootstrap: {}", e))
    }) {
        Ok(c) => Arc::new(c),
        Err(e) => {
            eprintln!("[plug-tor] Bootstrap failed: {}", e);
            return 0;
        }
    };

    let _ = TOR_CLIENT.set(client.clone());

    // Start local SOCKS5 proxy
    let port = match rt.block_on(async {
        start_socks_proxy(client).await
    }) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[plug-tor] SOCKS proxy failed: {}", e);
            return 0;
        }
    };

    SOCKS_PORT.store(port, Ordering::SeqCst);
    RUNNING.store(true, Ordering::SeqCst);
    port
}

/// Stop the Tor client.
#[no_mangle]
pub extern "C" fn plug_tor_stop() {
    RUNNING.store(false, Ordering::SeqCst);
    SOCKS_PORT.store(0, Ordering::SeqCst);
}

/// Check if Tor is running.
#[no_mangle]
pub extern "C" fn plug_tor_is_running() -> bool {
    RUNNING.load(Ordering::SeqCst)
}

/// Get the SOCKS5 proxy port.
#[no_mangle]
pub extern "C" fn plug_tor_port() -> u16 {
    SOCKS_PORT.load(Ordering::SeqCst)
}

/// Simple SOCKS5 proxy that forwards connections through Tor.
async fn start_socks_proxy(client: Arc<TorClient<PreferredRuntime>>) -> Result<u16, Box<dyn std::error::Error>> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();

    tokio::spawn(async move {
        loop {
            if !RUNNING.load(Ordering::SeqCst) {
                break;
            }

            let (mut stream, _) = match listener.accept().await {
                Ok(s) => s,
                Err(_) => continue,
            };

            let client = client.clone();
            tokio::spawn(async move {
                if let Err(e) = handle_socks5_connection(&mut stream, &client).await {
                    eprintln!("[plug-tor] SOCKS5 error: {}", e);
                }
            });
        }
    });

    Ok(port)
}

/// Handle a single SOCKS5 connection.
async fn handle_socks5_connection(
    stream: &mut tokio::net::TcpStream,
    client: &TorClient<PreferredRuntime>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut buf = [0u8; 258];
    let n = stream.read(&mut buf).await?;
    if n < 2 || buf[0] != 0x05 {
        return Err("Not SOCKS5".into());
    }

    // No auth required
    stream.write_all(&[0x05, 0x00]).await?;

    // Read SOCKS5 request
    let n = stream.read(&mut buf).await?;
    if n < 4 || buf[0] != 0x05 || buf[1] != 0x01 {
        stream.write_all(&[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
        return Err("Not CONNECT".into());
    }

    // Parse address
    let (host, port) = match buf[3] {
        0x01 => {
            // IPv4
            if n < 10 { return Err("Short IPv4".into()); }
            let ip = format!("{}.{}.{}.{}", buf[4], buf[5], buf[6], buf[7]);
            let port = u16::from_be_bytes([buf[8], buf[9]]);
            (ip, port)
        }
        0x03 => {
            // Domain name
            let len = buf[4] as usize;
            if n < 5 + len + 2 { return Err("Short domain".into()); }
            let domain = String::from_utf8_lossy(&buf[5..5+len]).to_string();
            let port = u16::from_be_bytes([buf[5+len], buf[6+len]]);
            (domain, port)
        }
        _ => return Err("Unsupported address type".into()),
    };

    // Connect through Tor with retry (circuits can be slow/stale)
    let mut last_err = String::new();
    for attempt in 0..3 {
        match client.connect((host.as_str(), port)).await {
            Ok(tor_stream) => {
                // Success
                stream.write_all(&[0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0]).await?;

                // Bidirectional copy
                let (mut client_read, mut client_write) = stream.split();
                let (mut tor_read, mut tor_write) = tor_stream.split();

                tokio::select! {
                    _ = tokio::io::copy(&mut client_read, &mut tor_write) => {},
                    _ = tokio::io::copy(&mut tor_read, &mut client_write) => {},
                }
                return Ok(());
            }
            Err(e) => {
                last_err = format!("{}", e);
                eprintln!("[plug-tor] Connect attempt {} failed: {} -> {}:{}", attempt + 1, e, host, port);
                if attempt < 2 {
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            }
        }
    }

    eprintln!("[plug-tor] All retries failed for {}:{}: {}", host, port, last_err);
    stream.write_all(&[0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tor_bootstrap() {
        println!("Starting Tor bootstrap...");
        let port = plug_tor_start();

        if port > 0 {
            println!("✅ Tor connected! SOCKS5 on 127.0.0.1:{}", port);
            assert!(plug_tor_is_running());
            assert_eq!(plug_tor_port(), port);

            std::thread::sleep(std::time::Duration::from_secs(3));

            plug_tor_stop();
            println!("Tor stopped.");
        } else {
            println!("⚠️ Tor bootstrap returned 0 — may need network access");
        }
    }
}

#[cfg(test)]
mod integration_tests {
    use super::*;

    #[test]
    fn test_socks5_connect() {
        let port = plug_tor_start();
        assert!(port > 0, "Tor bootstrap failed");

        // Connect to mempool.space through our SOCKS5 proxy
        let rt = get_runtime();
        let result = rt.block_on(async {
            use tokio::net::TcpStream;
            use tokio::io::{AsyncReadExt, AsyncWriteExt};

            let mut stream = TcpStream::connect(format!("127.0.0.1:{}", port)).await?;

            // SOCKS5 greeting: version 5, 1 auth method (no auth)
            stream.write_all(&[0x05, 0x01, 0x00]).await?;
            let mut resp = [0u8; 2];
            stream.read_exact(&mut resp).await?;
            assert_eq!(resp, [0x05, 0x00], "SOCKS5 greeting failed");

            // SOCKS5 CONNECT to mempool.space:443
            let domain = b"mempool.space";
            let mut req = vec![0x05, 0x01, 0x00, 0x03, domain.len() as u8];
            req.extend_from_slice(domain);
            req.extend_from_slice(&443u16.to_be_bytes());
            stream.write_all(&req).await?;

            let mut resp = [0u8; 10];
            stream.read_exact(&mut resp).await?;
            println!("SOCKS5 response: {:?}", resp);
            println!("Status: {}", resp[1]);

            if resp[1] == 0x00 {
                println!("✅ SOCKS5 CONNECT succeeded!");
            } else {
                println!("❌ SOCKS5 CONNECT failed with status {}", resp[1]);
            }

            Ok::<u8, Box<dyn std::error::Error>>(resp[1])
        });

        plug_tor_stop();

        match result {
            Ok(status) => assert_eq!(status, 0, "SOCKS5 connect returned error status"),
            Err(e) => panic!("Test failed: {}", e),
        }
    }
}
