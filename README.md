# PLUG.

**Programmable Locking UTXO Gateway**

Bitcoin Script. Ledger signs.

---

PLUG is a Bitcoin programmability tool — not a wallet. It lets you create complex smart contract transactions on the Bitcoin network. Your Ledger hardware wallet is always the signer — you keep custody of your funds.

## Contracts

| Contract | Type | Description |
|----------|------|-------------|
| **Tirelire** | `CLTV` | Time-locked vault — funds locked until a specific block height |
| **Heritage** | `CSV` | Inheritance — owner spends anytime, heir spends after relative delay |
| **Cagnotte** | `M-of-N` | Multisig pool — M signatures required out of N participants |
| **HTLC** | `SHA256` | Hash Time-Lock — atomic swaps and conditional payments |
| **Channel** | `2-of-2 + CLTV` | Payment channel with unilateral refund timeout |

All contracts use **P2WSH** (Pay-to-Witness-Script-Hash) with miniscript descriptors that match the Ledger's compiler output byte-for-byte.

## Architecture

- **Swift / SwiftUI** — iOS & macOS (MVVM + Swift Concurrency)
- **Ledger V2 Protocol** — Merkleized PSBT signing (CLA=0xE1), wallet policy registration
- **libsecp256k1** — All EC operations via Bitcoin Core's audited C library
- **mempool.space** — Blockchain data with TLS certificate pinning

## How it works

```
You define the contract → PLUG builds the PSBT → Ledger signs → Broadcast to Bitcoin
```

Private keys **never** leave the hardware device. PLUG only holds extended public keys (xpubs).

## Build

```bash
xcodebuild -scheme PLUG -configuration Debug build
```

## Safety

- Testnet-first — forces testnet on first launch
- Dust output warnings (< 546 sats)
- Absurd fee alerts (> 100 sat/vB)
- Fee sniping defense (nLockTime)
- HTLC preimage backup to keychain
- Transaction pinning detection

## Links

- [bitcoin-plug.com](https://bitcoin-plug.com)
- [@seeduser99](https://x.com/seeduser99)

---

*Not your keys, not your coins. Not your script, not your rules.*
