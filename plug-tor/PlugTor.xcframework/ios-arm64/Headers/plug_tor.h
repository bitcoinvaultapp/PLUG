#ifndef PLUG_TOR_H
#define PLUG_TOR_H

#include <stdint.h>
#include <stdbool.h>

/// Start the Tor client and SOCKS5 proxy.
/// Returns the local SOCKS5 port on success, 0 on failure.
/// Bootstrap may take 10-30 seconds.
uint16_t plug_tor_start(void);

/// Stop the Tor client and proxy.
void plug_tor_stop(void);

/// Check if the Tor proxy is currently running.
bool plug_tor_is_running(void);

/// Get the SOCKS5 proxy port (0 if not running).
uint16_t plug_tor_port(void);

/// Fetch a URL through Tor directly (no SOCKS5 proxy, reuses HS circuits).
/// Returns a C string with the HTTP response body, or NULL on error.
/// Caller must free the returned string with plug_tor_free_string().
char* plug_tor_fetch(const char* host, uint16_t port, const char* path);

/// Free a string returned by plug_tor_fetch.
void plug_tor_free_string(char* s);

#endif /* PLUG_TOR_H */
