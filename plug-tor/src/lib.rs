use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::{Arc, Mutex};

use once_cell::sync::OnceCell;
use tokio::runtime::Runtime;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use arti_client::{TorClient, TorClientConfig};
use arti_client::config::CfgPath;
use tor_rtcompat::PreferredRuntime;

/// Global Tor client instance
static TOR_CLIENT: OnceCell<Arc<TorClient<PreferredRuntime>>> = OnceCell::new();
static RUNNING: AtomicBool = AtomicBool::new(false);
static SOCKS_PORT: AtomicU16 = AtomicU16::new(0);
static RUNTIME: OnceCell<Runtime> = OnceCell::new();

/// Mutex to serialize all Tor fetch requests.
/// Prevents concurrent HS circuit builds which overwhelm Arti on iOS.
/// First request builds the circuit (~15-30s), subsequent reuse it (~2-3s).
static FETCH_LOCK: OnceCell<Mutex<()>> = OnceCell::new();

fn get_fetch_lock() -> &'static Mutex<()> {
    FETCH_LOCK.get_or_init(|| Mutex::new(()))
}

fn get_runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(4) // 4 workers (was 2) for better iOS scheduling
            .build()
            .expect("Failed to create Tokio runtime")
    })
}

/// Get iOS-compatible cache directory for Arti state data.
fn get_state_dir() -> String {
    #[cfg(target_os = "ios")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            let path = format!("{}/Library/Caches/arti", home.to_string_lossy());
            let _ = std::fs::create_dir_all(&path);
            return path;
        }
    }
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

/// Start the Tor client. Returns the SOCKS5 port on success, 0 on failure.
#[no_mangle]
pub extern "C" fn plug_tor_start() -> u16 {
    if RUNNING.load(Ordering::SeqCst) {
        return SOCKS_PORT.load(Ordering::SeqCst);
    }

    let rt = get_runtime();

    let client = match rt.block_on(async {
        let state_dir = get_state_dir();
        let cache_dir = get_cache_dir();

        let mut builder = TorClientConfig::builder();
        builder.storage()
            .state_dir(CfgPath::new_literal(state_dir))
            .cache_dir(CfgPath::new_literal(cache_dir));
        // 60s timeout for HS circuit builds (can be slow on mobile)
        builder.stream_timeouts()
            .connect_timeout(std::time::Duration::from_secs(60));

        let config = builder.build()
            .map_err(|e| format!("config: {}", e))?;

        eprintln!("[plug-tor] Bootstrapping Tor...");
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
    eprintln!("[plug-tor] Bootstrap complete!");

    // Use port 1 as a marker that Tor is running (SOCKS5 proxy no longer needed)
    SOCKS_PORT.store(1, Ordering::SeqCst);
    RUNNING.store(true, Ordering::SeqCst);
    1
}

/// Warm up the HS circuit by connecting to the .onion once.
/// Call after plug_tor_start() to pre-establish the circuit.
/// Returns true if warmup succeeded, false if it failed.
#[no_mangle]
pub extern "C" fn plug_tor_warmup(
    host: *const std::ffi::c_char,
    port: u16,
) -> bool {
    let host_str = match unsafe { std::ffi::CStr::from_ptr(host) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return false,
    };

    let client = match TOR_CLIENT.get() {
        Some(c) => c.clone(),
        None => return false,
    };

    let rt = get_runtime();
    let max_duration = std::time::Duration::from_secs(180); // 3 minute window
    let per_attempt = std::time::Duration::from_secs(15);   // 15s per try
    let start = std::time::Instant::now();
    let mut attempt = 0;

    eprintln!("[plug-tor] Warming up HS circuit to {}:{} (max 180s)...", host_str, port);

    // Continuous retry loop — short attempts within a long window.
    // Each failed attempt progresses HS circuit building in the background.
    while start.elapsed() < max_duration {
        attempt += 1;
        let elapsed = start.elapsed().as_secs();
        eprintln!("[plug-tor] Warmup attempt {} ({}s elapsed)...", attempt, elapsed);

        match rt.block_on(async {
            tokio::time::timeout(per_attempt,
                tor_http_get(client.clone(), &host_str, port, "/api/v1/fees/recommended")
            ).await
        }) {
            Ok(Ok(body)) => {
                let total = start.elapsed().as_secs();
                eprintln!("[plug-tor] ✅ Warmup OK! ({} bytes, attempt {}, {}s total)", body.len(), attempt, total);
                return true;
            }
            Ok(Err(e)) => {
                eprintln!("[plug-tor] ⚠️ attempt {}: {}", attempt, e);
            }
            Err(_) => {
                eprintln!("[plug-tor] ⚠️ attempt {}: timeout ({}s)", attempt, per_attempt.as_secs());
            }
        }
        // Brief pause before next attempt
        std::thread::sleep(std::time::Duration::from_secs(3));
    }

    eprintln!("[plug-tor] ❌ Warmup failed after {}s ({} attempts)", start.elapsed().as_secs(), attempt);
    false
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

/// Fetch a URL through Tor directly (no SOCKS5 proxy).
/// SERIALIZED: only one request at a time via Mutex.
/// First request builds HS circuit (~15-30s), subsequent reuse it (~2-3s).
/// Returns a C string (caller must free with plug_tor_free_string).
/// On error, returns null.
#[no_mangle]
pub extern "C" fn plug_tor_fetch(
    host: *const std::ffi::c_char,
    port: u16,
    path: *const std::ffi::c_char,
) -> *mut std::ffi::c_char {
    let host_str = match unsafe { std::ffi::CStr::from_ptr(host) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return std::ptr::null_mut(),
    };
    let path_str = match unsafe { std::ffi::CStr::from_ptr(path) }.to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return std::ptr::null_mut(),
    };

    let client = match TOR_CLIENT.get() {
        Some(c) => c.clone(),
        None => {
            eprintln!("[plug-tor] fetch: no Tor client");
            return std::ptr::null_mut();
        }
    };

    // Serialize all Tor requests — prevents concurrent HS circuit builds
    let _guard = get_fetch_lock().lock().unwrap();

    let rt = get_runtime();
    let t0 = std::time::Instant::now();
    match rt.block_on(tor_http_get(client, &host_str, port, &path_str)) {
        Ok(body) => {
            let dt = t0.elapsed().as_millis();
            eprintln!("[plug-tor] ✅ {} ({} bytes, {}ms)", path_str, body.len(), dt);
            match std::ffi::CString::new(body) {
                Ok(cs) => cs.into_raw(),
                Err(_) => std::ptr::null_mut(),
            }
        }
        Err(e) => {
            let dt = t0.elapsed().as_millis();
            eprintln!("[plug-tor] ❌ {} ({}ms): {}", path_str, dt, e);
            std::ptr::null_mut()
        }
    }
}

/// Free a string returned by plug_tor_fetch.
#[no_mangle]
pub extern "C" fn plug_tor_free_string(s: *mut std::ffi::c_char) {
    if !s.is_null() {
        unsafe { drop(std::ffi::CString::from_raw(s)); }
    }
}

/// HTTP GET through Tor — direct connect, no SOCKS5, reuses HS circuits.
async fn tor_http_get(
    client: Arc<TorClient<PreferredRuntime>>,
    host: &str,
    port: u16,
    path: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let mut stream = client.connect((host, port)).await?;

    let req = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nAccept: application/json\r\n\r\n",
        path, host
    );
    stream.write_all(req.as_bytes()).await?;
    stream.flush().await?;

    let mut response = Vec::new();
    loop {
        let mut buf = [0u8; 8192];
        match tokio::time::timeout(
            std::time::Duration::from_secs(30),
            stream.read(&mut buf)
        ).await {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => response.extend_from_slice(&buf[..n]),
            Ok(Err(_)) => break,
            Err(_) => break,
        }
    }

    let response_str = String::from_utf8_lossy(&response).to_string();

    if let Some(pos) = response_str.find("\r\n\r\n") {
        let body = &response_str[pos + 4..];
        if response_str.contains("Transfer-Encoding: chunked") {
            return Ok(decode_chunked(body));
        }
        Ok(body.to_string())
    } else {
        Err("No HTTP response body".into())
    }
}

/// Decode chunked transfer encoding
fn decode_chunked(body: &str) -> String {
    let mut result = String::new();
    let mut remaining = body;
    loop {
        let line_end = match remaining.find("\r\n") {
            Some(pos) => pos,
            None => break,
        };
        let size_str = &remaining[..line_end];
        let chunk_size = match usize::from_str_radix(size_str.trim(), 16) {
            Ok(s) => s,
            Err(_) => break,
        };
        if chunk_size == 0 { break; }
        remaining = &remaining[line_end + 2..];
        if remaining.len() >= chunk_size {
            result.push_str(&remaining[..chunk_size]);
            remaining = &remaining[chunk_size..];
            if remaining.starts_with("\r\n") {
                remaining = &remaining[2..];
            }
        } else {
            result.push_str(remaining);
            break;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tor_bootstrap() {
        println!("Starting Tor bootstrap...");
        let port = plug_tor_start();

        if port > 0 {
            println!("✅ Tor connected!");
            assert!(plug_tor_is_running());

            std::thread::sleep(std::time::Duration::from_secs(3));

            plug_tor_stop();
            println!("Tor stopped.");
        } else {
            println!("⚠️ Tor bootstrap returned 0 — may need network access");
        }
    }
}
