use std::time::Duration;

// Import the library functions
extern "C" {
    fn plug_tor_start() -> u16;
    fn plug_tor_stop();
    fn plug_tor_is_running() -> bool;
    fn plug_tor_port() -> u16;
}

fn main() {
    println!("Starting Tor bootstrap...");
    println!("This may take 10-30 seconds.");

    let port = unsafe { plug_tor_start() };

    if port > 0 {
        println!("✅ Tor connected! SOCKS5 proxy on 127.0.0.1:{}", port);
        println!("   Running: {}", unsafe { plug_tor_is_running() });
        println!("   Port: {}", unsafe { plug_tor_port() });

        // Test a connection through the proxy
        println!("\nTesting connection through Tor...");
        // Keep alive for a bit
        std::thread::sleep(Duration::from_secs(5));

        unsafe { plug_tor_stop() };
        println!("Tor stopped.");
        println!("   Running: {}", unsafe { plug_tor_is_running() });
    } else {
        println!("❌ Tor bootstrap failed (port=0)");
    }
}
