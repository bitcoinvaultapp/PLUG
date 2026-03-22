#ifndef PLUG_TOR_H
#define PLUG_TOR_H

#include <stdint.h>
#include <stdbool.h>

/// Start the Tor client.
/// Returns nonzero on success, 0 on failure.
/// Bootstrap may take 10-30 seconds.
uint16_t plug_tor_start(void);

/// Warm up the HS circuit by connecting to the .onion once.
/// Call after plug_tor_start() to pre-establish the circuit.
/// Returns true if warmup succeeded, false on failure/timeout (60s).
bool plug_tor_warmup(const char* host, uint16_t port);

/// Stop the Tor client.
void plug_tor_stop(void);

/// Check if the Tor client is currently running.
bool plug_tor_is_running(void);

/// Get the SOCKS5 proxy port (legacy, returns 1 if running).
uint16_t plug_tor_port(void);

/// Fetch a URL through Tor directly (no SOCKS5 proxy, reuses HS circuits).
/// SERIALIZED: only one request at a time (prevents circuit exhaustion).
/// 60s global timeout — prevents Mutex deadlock on unresponsive hosts.
/// Returns a C string with the HTTP response body, or NULL on error.
/// Caller must free the returned string with plug_tor_free_string().
char* plug_tor_fetch(const char* host, uint16_t port, const char* path);

/// POST data through Tor (e.g. broadcast a transaction).
/// SERIALIZED: shares the same Mutex as plug_tor_fetch.
/// 60s global timeout.
/// Returns the response body as a C string, or NULL on error.
/// Caller must free the returned string with plug_tor_free_string().
char* plug_tor_post(const char* host, uint16_t port, const char* path, const char* body);

/// Free a string returned by plug_tor_fetch / plug_tor_post.
void plug_tor_free_string(char* s);

#endif /* PLUG_TOR_H */
