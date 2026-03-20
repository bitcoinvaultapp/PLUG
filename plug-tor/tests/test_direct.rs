use arti_client::{TorClient, TorClientConfig};
use arti_client::config::CfgPath;
use tor_rtcompat::PreferredRuntime;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::main]
async fn main() {
    println!("Bootstrapping...");
    let mut builder = TorClientConfig::builder();
    builder.storage()
        .state_dir(CfgPath::new_literal("/tmp/arti_test_state2".to_string()))
        .cache_dir(CfgPath::new_literal("/tmp/arti_test_cache2".to_string()));
    builder.stream_timeouts()
        .connect_timeout(std::time::Duration::from_secs(60));

    let config = builder.build().unwrap();
    let client = TorClient::create_bootstrapped(config).await.unwrap();
    println!("✅ Bootstrapped!");

    // Test 1: example.com:80
    println!("\n--- Test 1: example.com:80 ---");
    match client.connect(("example.com", 80u16)).await {
        Ok(mut s) => {
            println!("✅ Connected!");
            s.write_all(b"GET / HTTP/1.0\r\nHost: example.com\r\n\r\n").await.unwrap();
            let mut buf = vec![0u8; 512];
            let n = s.read(&mut buf).await.unwrap();
            println!("Response ({} bytes): {}", n, String::from_utf8_lossy(&buf[..n.min(200)]));
        }
        Err(e) => println!("❌ Failed: {}", e),
    }

    // Test 2: mempool.space:443
    println!("\n--- Test 2: mempool.space:443 ---");
    match client.connect(("mempool.space", 443u16)).await {
        Ok(_) => println!("✅ Connected!"),
        Err(e) => println!("❌ Failed: {}", e),
    }

    // Test 3: check.torproject.org:80
    println!("\n--- Test 3: check.torproject.org:80 ---");
    match client.connect(("check.torproject.org", 80u16)).await {
        Ok(mut s) => {
            println!("✅ Connected!");
            s.write_all(b"GET /api/ip HTTP/1.0\r\nHost: check.torproject.org\r\n\r\n").await.unwrap();
            let mut buf = vec![0u8; 512];
            let n = s.read(&mut buf).await.unwrap();
            println!("Response ({} bytes): {}", n, String::from_utf8_lossy(&buf[..n.min(300)]));
        }
        Err(e) => println!("❌ Failed: {}", e),
    }
}
