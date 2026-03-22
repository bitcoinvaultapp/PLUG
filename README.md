# PLUG.

**Programmable Locking UTXO Gateway**

Bitcoin smart contracts signed by your Ledger. Not a wallet, a programmability tool. You keep custody. The Ledger signs. The blockchain enforces.

## Contracts

| Contract | Opcode | Description |
|----------|--------|-------------|
| **Vault** | `OP_CHECKLOCKTIMEVERIFY` | Lock sats until a future block height |
| **Inheritance** | `OP_CHECKSEQUENCEVERIFY` | Heir access after relative timelock |
| **HTLC** | `OP_SHA256 + CLTV` | Hash time-locked conditional payments |
| **Channel** | `OP_CHECKMULTISIG + CLTV` | 2-of-2 with timeout refund |
| **Pool** | `OP_CHECKMULTISIG` | M-of-N shared custody |
| **Atomic Swap** | `HTLC x 2` | Trustless P2P exchange via paired HTLCs |
| **CoinJoin** | `P2WPKH` | Serverless collaborative transactions |
| **OP_RETURN** | `OP_RETURN` | Embed data on the blockchain |

P2WSH (SegWit v0) + P2TR (Taproot). All scripts match the Ledger's miniscript compiler byte-for-byte.

## Architecture

```
iPhone
  |
  | Arti (embedded Tor)
  |
  v
.onion ─── Electrs REST ─── Bitcoin Core
            (your VPS)        (full node)
```

Two modes:
- **mempool.space** via Tor .onion (default)
- **Personal node** your own Bitcoin Core + Electrs, zero third-party exposure

## Security

| | |
|---|---|
| **Keys** | Zero on device. Only xpubs. Ledger signs everything. |
| **Network** | All address queries via Tor. Broadcast via Tor with retry. |
| **Storage** | Keychain hardened. AES-256-GCM encrypted backups. |
| **Privacy** | CoinJoin, coin control, address rotation, UTXO shuffling. |
| **Telemetry** | Zero. No analytics, no crash reporters, no tracking SDKs. |
| **Dependencies** | One: `secp256k1.swift`. |

## Stack

| Layer | Technology |
|-------|-----------|
| App | Swift, SwiftUI, MVVM + Swift Concurrency |
| Crypto | libsecp256k1 via GigaBitcoin/secp256k1.swift |
| Signing | Ledger V2 merkleized PSBT (BLE, CLA=0xE1) |
| Tor | Arti (Rust) → PlugTor.xcframework |
| Node | Bitcoin Core + Electrs (Docker) |
| Learn | Mastering Bitcoin 3rd Ed. (offline, bundled) |

## BIP Compliance

BIP32, BIP44, BIP65, BIP68, BIP84, BIP86, BIP112, BIP125, BIP141, BIP173, BIP174, BIP327, BIP340, BIP341, BIP342, BIP350, BIP371.

All implementations audited. Zero violations.

## Build

```bash
# iOS app
xcodebuild -scheme PLUG -configuration Debug build

# Tor library
cd plug-tor && ./build-ios.sh

# Personal node
cd plug-node && docker compose up -d
```

## Links

- [bitcoin-plug.com](https://bitcoin-plug.com)
- [@seeduser99](https://x.com/seeduser99)

---

*Not your keys, not your coins. Not your script, not your rules.*
