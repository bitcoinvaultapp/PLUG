# PLUG.

**Programmable Locking UTXO Gateway**

Bitcoin smart contracts signed by your Ledger. Open source. Sovereign. You bring your own node.

## Requirements

1. **Ledger hardware wallet** (Nano X, Stax, Flex) with Bitcoin app
2. **Your own Bitcoin node** (Bitcoin Core + Electrs) accessible via Tor .onion
3. **iPhone** running PLUG

No third-party servers. No custodians. No clearnet. All traffic goes through Tor to your own infrastructure.

## Quick Start

### 1. Deploy your node

```bash
git clone https://github.com/bitcoinvaultapp/PLUG.git
cd PLUG/plug-node
docker compose up -d
```

This starts Bitcoin Core + Electrs + Tor hidden service. Wait for Bitcoin Core to sync (~1-3 days for mainnet). Get your `.onion` address:

```bash
docker exec plug-tor cat /var/lib/tor/hidden_service/electrs/hostname
```

### 2. Build the app

```bash
cd PLUG
# Build Tor library (first time only)
cd plug-tor && ./build-ios.sh && cd ..
# Build and run on device
xcodebuild -scheme PLUG -configuration Debug build
```

### 3. Connect

1. Open the app, connect your Ledger via Bluetooth
2. Go to Settings > Personal Node
3. Paste your `.onion` address
4. Test connection (should show block height)

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

P2WPKH (SegWit v0) + P2TR (Taproot). All scripts match the Ledger's miniscript compiler byte-for-byte.

## Architecture

```
iPhone
  |
  | Arti (embedded Tor)
  |
  v
.onion ─── Electrs REST ─── Bitcoin Core
            (your node)       (your blockchain)
```

All wallet queries (addresses, UTXOs, transactions, fees, broadcast) go to your personal node via Tor. Price and difficulty data are fetched from mempool.space .onion.

Zero clearnet. Zero third-party wallet exposure.

## Security

| | |
|---|---|
| **Keys** | Zero on device. Only xpubs. Ledger signs everything. |
| **Network** | All traffic via embedded Tor (Arti). No clearnet. |
| **Node** | Your own Bitcoin Core + Electrs. No third-party balance exposure. |
| **Storage** | Keychain hardened. AES-256-GCM encrypted backups. |
| **Privacy** | CoinJoin, Stonewall, coin control, address rotation, UTXO shuffling. |
| **Telemetry** | Zero. No analytics, no crash reporters, no tracking SDKs. |
| **Dependencies** | One: `secp256k1.swift`. |

## Node Deployment Guide

### Requirements

- VPS or Raspberry Pi with 1TB+ storage
- Docker and Docker Compose
- ~1-3 days for initial blockchain sync

### Docker Compose

The `plug-node/docker-compose.yml` runs:

| Service | Purpose |
|---------|---------|
| `bitcoind` | Bitcoin Core full node |
| `electrs` | Address indexer (Electrs REST API) |
| `tor` | Tor hidden service exposing Electrs |

### Configuration

Edit `plug-node/bitcoin.conf` for your setup. Default is mainnet with 4GB dbcache.

### Monitoring

A systemd watchdog (`plug-watchdog.timer`) checks containers every 2 minutes and auto-restarts if needed. Logs at `/var/log/plug-node-watchdog.log`.

### Endpoints

Electrs REST API (no `/api` prefix):

```
/blocks/tip/height          Block height
/address/{addr}/utxo        UTXOs
/address/{addr}/txs         Transactions
/tx/{txid}                  Transaction details
/tx/{txid}/hex              Raw transaction
/fee-estimates              Fee rate estimates
/tx (POST)                  Broadcast
```

## BIP Compliance

BIP32, BIP44, BIP65, BIP68, BIP84, BIP86, BIP112, BIP125, BIP141, BIP173, BIP174, BIP327, BIP340, BIP341, BIP342, BIP350, BIP371.

All implementations audited. Zero violations.

## Stack

| Layer | Technology |
|-------|-----------|
| App | Swift, SwiftUI, MVVM + Swift Concurrency |
| Crypto | libsecp256k1 via GigaBitcoin/secp256k1.swift |
| Signing | Ledger V2 merkleized PSBT (BLE, CLA=0xE1) |
| Tor | Arti (Rust) compiled as iOS static library |
| Node | Bitcoin Core + Electrs (Docker) |
| Learn | Mastering Bitcoin 3rd Ed. (offline ebook) |

## Links

- [bitcoin-plug.com](https://bitcoin-plug.com)
- [@seeduser99](https://x.com/seeduser99)

---

*Not your keys, not your coins. Not your script, not your rules. Not your node, not your privacy.*
