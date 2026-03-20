use arti_client::{TorClient, TorClientConfig};
use arti_client::config::CfgPath;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[tokio::main]
async fn main() {
    println!("Bootstrapping with onion-service-client...");
    let mut builder = TorClientConfig::builder();
    builder.storage()
        .state_dir(CfgPath::new_literal("/tmp/arti_test_state5".to_string()))
        .cache_dir(CfgPath::new_literal("/tmp/arti_test_cache5".to_string()));
    builder.stream_timeouts()
        .connect_timeout(std::time::Duration::from_secs(60));

    let config = builder.build().unwrap();
    let client = TorClient::create_bootstrapped(config).await.unwrap();
    println!("✅ Bootstrapped!\n");

    // Test: mempool .onion:80 — full HTTP request/response
    println!("--- Fetching fees from mempool .onion ---");
    match client.connect(("mempoolhqx4isw62xs7abwphsq7ldayuidyx2v2oethdhhj6mlo2r6ad.onion", 80u16)).await {
        Ok(mut s) => {
            println!("✅ Connected to .onion!");
            let req = b"GET /api/v1/fees/recommended HTTP/1.1\r\nHost: mempoolhqx4isw62xs7abwphsq7ldayuidyx2v2oethdhhj6mlo2r6ad.onion\r\nConnection: close\r\n\r\n";
            s.write_all(req).await.unwrap();
            s.flush().await.unwrap();

            // Read full response
            let mut response = Vec::new();
            loop {
                let mut buf = [0u8; 4096];
                match tokio::time::timeout(
                    std::time::Duration::from_secs(15),
                    s.read(&mut buf)
                ).await {
                    Ok(Ok(0)) => break,
                    Ok(Ok(n)) => response.extend_from_slice(&buf[..n]),
                    Ok(Err(_)) => break,
                    Err(_) => { println!("Read timeout"); break; }
                }
            }
            println!("Response ({} bytes):\n{}", response.len(), String::from_utf8_lossy(&response));
        }
        Err(e) => println!("❌ Failed: {}", e),
    }

    // Test: testnet fees
    println!("\n--- Fetching testnet fees from .onion ---");
    match client.connect(("mempoolhqx4isw62xs7abwphsq7ldayuidyx2v2oethdhhj6mlo2r6ad.onion", 80u16)).await {
        Ok(mut s) => {
            println!("✅ Connected!");
            let req = b"GET /testnet/api/v1/fees/recommended HTTP/1.1\r\nHost: mempoolhqx4isw62xs7abwphsq7ldayuidyx2v2oethdhhj6mlo2r6ad.onion\r\nConnection: close\r\n\r\n";
            s.write_all(req).await.unwrap();
            s.flush().await.unwrap();

            let mut response = Vec::new();
            loop {
                let mut buf = [0u8; 4096];
                match tokio::time::timeout(
                    std::time::Duration::from_secs(15),
                    s.read(&mut buf)
                ).await {
                    Ok(Ok(0)) => break,
                    Ok(Ok(n)) => response.extend_from_slice(&buf[..n]),
                    Ok(Err(_)) => break,
                    Err(_) => { println!("Read timeout"); break; }
                }
            }
            println!("Response ({} bytes):\n{}", response.len(), String::from_utf8_lossy(&response));
        }
        Err(e) => println!("❌ Failed: {}", e),
    }
}
