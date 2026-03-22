# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PLUG (**Programmable Locking UTXO Gateway**) is a Bitcoin programmability tool — not a wallet. It lets users create complex smart contract transactions on the Bitcoin network ("code money"). The **Ledger hardware wallet is always the signer** — users keep custody of their funds.

It supports standard P2WPKH transactions, advanced Bitcoin smart contracts (P2WSH): time-locked vaults (Vault), inheritance (Inheritance), multisig pools (Pool), HTLCs, payment channels, **CoinJoin** (serverless PSBT-based collaborative transactions), and **Taproot (P2TR)** for multi-key contracts.

The repo also contains `app-bitcoin-new/`, the Ledger device-side Bitcoin application (C, for Nano X/S+/Stax/Flex/Apex P), and `bitcoinbook/`, a reference copy of "Mastering Bitcoin" (AsciiDoc).

## Build Commands

### PLUG iOS/macOS App
```bash
xcodebuild -scheme PLUG -configuration Debug build
xcodebuild -scheme PLUG -configuration Release build
```

### PlugTor (Rust → iOS static library)
```bash
cd plug-tor && ./build-ios.sh
# Outputs: PlugTor.xcframework (copy to project root)
cp -R plug-tor/PlugTor.xcframework PlugTor.xcframework
```

### Ledger Bitcoin App (app-bitcoin-new/, requires Docker)
```bash
# Inside ledger-app-dev-tools Docker container:
make DEBUG=1                        # Testnet (default), Nano S+
make DEBUG=0 COIN=bitcoin           # Mainnet
BOLOS_SDK=$NANOX_SDK make DEBUG=1   # Target Nano X
```

### Ledger Unit Tests (app-bitcoin-new/unit-tests/)
```bash
cmake -Bbuild -H. && make -C build
CTEST_OUTPUT_ON_FAILURE=1 make -C build test
./gen_coverage.sh   # Coverage report
```

### Ledger Functional Tests (app-bitcoin-new/tests/)
```bash
pip install -r requirements.txt
pytest --device nanox              # Run on Speculos emulator
pytest --device nanox --backend ledgercomm  # Run on physical device
```

## Architecture

### PLUG App (PLUG/)

**MVVM + Swift Concurrency** with `@MainActor` ViewModels and `@Published` state.

- **Entry point**: `PLUGApp.swift` — routes to onboarding or 5-tab main view (Home, Wallet, Contracts, Learn, Script). `TorBootstrapWrapper` gates the app behind Tor connection with elapsed timer + "Skip — use clearnet". Once entered, never returns to bootstrap (user can disconnect Tor in Settings freely). Keychain migration v4 (wallet-only wipe, preserves contracts). Global disconnect banner in `MainTabView`.
- **Branding**: All tabs use `PlugHeader(pageName:)` — displays "PLUG." with orange dot + page name. Home shows TESTNET badge + Settings gear. **All tabs** show a reactive connection pill (green "Ledger" / orange "Scanning" / gray "Offline" / red "Error") via `@ObservedObject` on `LedgerManager.shared`. Tapping the pill opens LedgerView from any tab.
- **Language**: English only. All user-facing strings are in English.
- **No demo mode**: Removed. App requires a real Ledger connection. Testnet is the dev environment.
- **Models/Models.swift** — UTXO, Transaction, Contract (with V2 wallet policy fields, Taproot fields, Atomic Swap fields), WalletAddress, DashboardAlert, BlockchainInfo, FeeEstimate, etc.
- **Core/Bitcoin/** — Bitcoin protocol logic (all BIP-compliant, audited 2026-03-22):
  - `PSBTBuilder` — BIP174/BIP371 PSBT construction with witness UTXOs, NON_WITNESS_UTXO, BIP32 derivation maps, and Taproot input keys
  - `SpendManager` — Unified P2WSH spend via `buildP2WSHSpend(SpendParams)` — one function for all contract types. Taproot key-path and script-path as separate functions. Named sequence constants (`seqRBF`, `seqLocktime`). Transaction validation + broadcast with mainnet guard.
  - `CoinSelection` — Largest-first, smallest-first, exact-match strategies; 68 vbyte P2WPKH inputs, 546-sat dust threshold
  - `CoinJoin` — Serverless PSBT-based collaborative transactions with output shuffling
  - `ScriptBuilder` — **All scripts use Ledger-compatible miniscript format**. Template scripts match byte-for-byte.
  - `KeyDerivation` — BIP32 non-hardened derivation, BIP44 gap limit scan (20), P2WPKH and P2TR (BIP86) address generation
  - `Secp256k1` — Thin wrapper around **libsecp256k1** via `GigaBitcoin/secp256k1.swift`. x-only key support (BIP340).
  - `TaprootBuilder` — BIP340/341/342: tagged hashes, MAST construction, key tweaking, control block, P2TR address
  - `MuSig2` — BIP327 key aggregation, coefficient calculation
- **Core/Ledger/** — Hardware wallet integration:
  - `LedgerManager` — Singleton, `ObservableObject`. CoreBluetooth BLE transport, APDU framing (tag=0x05, MTU=64), xpub retrieval, master fingerprint. Published state: `.disconnected`, `.scanning`, `.connecting`, `.connected`, `.error(String)`.
  - `LedgerProtocol` (V1, CLA=0xE0) and `LedgerProtocolV2` (CLA=0xE1) — V2 uses merkleized PSBT signing
  - `LedgerSigningV2` — 3 files: orchestration + CommandInterpreter (500 rounds max), `MerkleTree.swift`, `PSBTv2Builder.swift` (P2WSH + P2TR maps with NON_WITNESS_UTXO support).
  - `ContractSigner` — High-level orchestrator: builds wallet policy, auto-builds `inputAddressInfos` with previous tx fetch for BIP174, registers if needed, signs via V2. Errors propagated explicitly (no silent failures).
  - `WalletPolicyBuilder` — Ledger V2 wallet policy descriptors: `wsh(...)` for P2WSH, `tr(...)` for Taproot.
- **Core/Network/** — Dual-mode networking (Tor or clearnet):
  - `MempoolAPI` — Unified transport: `privateGET` (Tor-required for addresses/transactions), `publicGET` (clearnet for price/difficulty), `torGET`/`torPOST` (direct Arti stream with retry + backoff). TLS certificate pinning for clearnet. Broadcast via Tor with 3x exponential backoff + txid validation. Personal node support via `TorConfig.resolve()`.
  - `NetworkConfig` — Testnet/mainnet runtime switching
  - `WebSocketManager` — Real-time blocks/price (mainnet clearnet only — blocked when Tor active to prevent IP leak)
  - `TorConfig` — Persisted in UserDefaults. `usePersonalNode` + `personalNodeOnion` for self-hosted Electrs. `resolve(endpoint:)` centralizes host/path routing.
  - `TorManager` — `@MainActor ObservableObject` with `.disconnected/.connecting/.warmingUp/.connected/.error` state. Warmup targets personal node .onion when configured.
  - `UTXOFetchService` — Shared UTXO/TX batch fetching: shuffled addresses for anti-correlation, batch size 1 (Tor) or 5 (clearnet)
- **Core/Storage/** — `KeychainStore` (hardened, no iCloud sync), `ContractStore`, `FrozenUTXOStore`, `TxLabelStore`, `AddressBook`, `BIP329Labels`, `BiometricStore`
- **Core/ColorTheme.swift** — Centralized color definitions (`.btcOrange`, `.bgDark`, `.cardDark`, etc.)
- **Core/BalanceUnit.swift** — Unified balance formatting: `format()`, `formatSplit()`, `formatSats()`. Used across all views.
- **Views/** — Shared components: `PlugHeader`, `BlockDurationPicker`, `ContractCreatedSheet`, `KeyIndexPicker`, `HexGridView`, `QRScannerView`. Feature views: `CoinJoinView`, `AtomicSwapView`. Personal node config in `SettingsView` > `PersonalNodeSettingsRow` with .onion input + "Test connection" button.
- **ViewModels/** — `ContractVM` protocol shared by VaultVM, InheritanceVM, HTLCVM, ChannelVM, PoolVM (unified `refreshContracts()`, `fundedAmount()`, `progress()`, `isDuplicateAddress()`). Other VMs: `WalletVM`, `HomeVM`, `LedgerVM`, `CoinJoinVM`, `AtomicSwapVM`, `BackupVM`, `ScriptVM`.

### Ledger App (app-bitcoin-new/)

C application using Ledger SDK. Key source in `src/`:
- `handler/sign_psbt.c` — Main PSBT signing handler (merkleized V2 protocol)
- `common/wallet.c` — Wallet policy parsing and validation
- `handler/lib/policy.c` — `is_policy_sane()` — **rejects duplicate compressed pubkeys in keysInfo** (line 2012). [GitHub issue #442](https://github.com/LedgerHQ/app-bitcoin-new/issues/442).
- `common/merkle.c` — Merkle tree protocol
- `handler/lib/get_merkle_preimage.c` — Preimage fetch with SHA256 hash verification

## Key Design Decisions

- **Testnet-first safety**: Forces testnet on first launch; mainnet broadcast is disabled during development
- **Ledger-only signing**: Private keys never leave the hardware device; the app only holds xpubs. No demo mode.
- **All signing via V2 protocol**: Every signing path uses CLA=0xE1 merkleized PSBT protocol. Client command loop: 500 rounds max.
- **Taproot single-key limitation**: Ledger's `is_policy_sane()` rejects duplicate pubkeys. Vault creation is P2WSH only. Taproot is only for multi-key contracts.
- **SpendManager unified architecture**: All P2WSH spends go through `buildP2WSHSpend(SpendParams)`. What varies per contract type: `sequence`, `locktime`, `witnessSize`, `destinations`. Everything else (input building, output building, fee estimation, dust check, BIP69 sorting) is shared.
- **Dual-mode networking**: All privacy-sensitive queries (addresses, UTXOs, transactions, broadcast) require Tor. Public data (price, difficulty) uses clearnet. Personal node mode routes everything to user's own Electrs .onion.
- **Tor bootstrap UX**: Timer displayed during connection (~60s for first .onion circuit). User can skip to clearnet at any time. Once entered, disconnecting Tor in Settings doesn't kick back to bootstrap.
- **Balance display**: Tappable — cycles sats → BTC (8 decimals) → USD. Formatting centralized in `BalanceUnit.format()` / `formatSplit()`.
- **Contract VM protocol**: `ContractVM` protocol eliminates duplication across 5 contract ViewModels: shared `refreshContracts()`, `fundedAmount()`, `progress()`, `isDuplicateAddress()`.
- **Duplicate address prevention**: All contract VMs use `isDuplicateAddress()` from `ContractVM` protocol.
- **NON_WITNESS_UTXO**: PSBTv2Builder includes full previous transaction (key 0x00) for BIP174 compliance. ContractSigner fetches raw tx via `getRawTransaction()`.
- **Broadcast resilience**: 3x retry with exponential backoff (0s, 2s, 4s) via Tor. Validates returned txid (64 hex chars). Never silently fails.
- **No silent failures**: ContractSigner propagates UTXO fetch errors explicitly instead of falling back to empty arrays.

## Contract Script Formats (Miniscript-aligned)

**CRITICAL**: All scripts must match the Ledger's miniscript compiler output exactly. Different byte order = different P2WSH address = 0x6A80 signing failure.

### Vault (CLTV time-lock vault) — P2WSH ONLY
- **Descriptor**: `wsh(and_v(v:pk(@0/**),after(N)))`
- **Script**: `<KEY> OP_CHECKSIGVERIFY <N> OP_CHECKLOCKTIMEVERIFY`
- **Keys**: 1 (internal only)
- **Note**: Taproot vaults disabled — Ledger rejects duplicate pubkeys in `is_policy_sane()`

### Inheritance (CSV inheritance)
- **P2WSH**: `wsh(or_d(pk(@0/**),and_v(v:pk(@1/**),older(N))))`
- **P2TR**: `tr(@0/**,{pk(@1/**),and_v(v:pk(@2/**),older(N))})` — @1=owner in script (with origin), @2=heir
- **Keys**: 2 (@0=owner internal, @1=heir external xpub)

### HTLC (Hash Time-Lock)
- **P2WSH**: `wsh(andor(pk(@0/**),sha256(H),and_v(v:pk(@1/**),after(N))))`
- **P2TR**: `tr(@0/**,andor(pk(@1/**),sha256(H),and_v(v:pk(@2/**),after(N))))` — @1=receiver in script (with origin), @2=sender
- **Keys**: 2 (@0=receiver for claim, @1=sender; swapped for refund)

### Pool (M-of-N multisig)
- **Descriptor**: `wsh(sortedmulti(M,@0/**,@1/**,...,@(N-1)/**))`
- **Keys**: N (one internal with origin, rest external xpubs)

### Channel (2-of-2 + CLTV refund)
- **Descriptor**: `wsh(or_d(multi(2,@0/**,@1/**),and_v(v:pk(@0/**),after(N))))`
- **Keys**: 2 (@0=sender internal, @1=receiver external xpub)

## Ledger V2 Signing Protocol

Reference: `app-bitcoin-new/doc/bitcoin.md`, `app-bitcoin-new/doc/wallet.md`

### Signing Flow (ContractSigner)
1. Build `WalletPolicyBuilder.Policy` from contract parameters
2. Auto-build `inputAddressInfos` if not provided (derives pubkey, fetches UTXOs + raw previous tx, gets scriptPubKey)
3. Check if `contract.walletPolicyHmac` exists for this descriptor
4. If not: **REGISTER_WALLET** (INS=0x02) — user approves on Ledger screen — store HMAC
5. Detect Taproot (`descriptor.hasPrefix("tr(")`) and use P2TR input maps
6. **SIGN_PSBT** (INS=0x04) with wallet_id + HMAC + PSBTv2 merkleized maps (includes NON_WITNESS_UTXO)
7. Collect signatures from YIELD commands (500 round limit)
8. Build witness stacks and finalize transaction

### Common Error Codes
| SW | Meaning | Common Cause |
|----|---------|--------------|
| 0x6A80 | INCORRECT_DATA | Script mismatch, coin_type mismatch, wrong fingerprint, UTXO scriptPubKey mismatch |
| 0x6A82 | NOT_SUPPORTED | Duplicate pubkeys in keysInfo, bare xpub matching internal key |
| 0x6985 | DENY | User rejected on Ledger screen |
| 0x9000 | OK | Success |
| 0xE000 | INTERRUPTED | Client command request (normal flow) |

### BLE Transport
- Frame format: `tag(0x05) + seq(2) + [length(2) first frame only] + data`
- Inter-frame delay: 50ms (configurable in `LedgerManager.sendAPDU`)
- Write type: `.withResponse` (Nano X requirement)
- MTU: 64 bytes (conservative — some firmware versions crash above this)

## Security

- **Zero keys on device**: Only xpubs. Private keys exist exclusively on the Ledger hardware.
- **Testnet-first**: Forces testnet on first launch.
- **All address/tx queries via Tor**: `privateGET()` blocks without Tor (unless user explicitly skipped). Broadcast also via Tor with retry.
- **WebSocket blocked when Tor active**: Prevents clearnet IP leak from persistent WS connection.
- **Broadcast via Tor**: `torPOST()` with 3x exponential backoff. txid validated (64 hex chars) before returning.
- **Personal node mode**: Routes all queries to user's own Bitcoin Core + Electrs via Tor .onion. Zero third-party exposure.
- **Address rotation**: Never reuse spent-from addresses. Fresh change address per transaction.
- **Privacy score**: Tracks address reuse, exposed pubkeys, UTXO consolidation. Shown on Home.
- **Coin control**: Manual UTXO selection to prevent mixing KYC/non-KYC funds.
- **CoinJoin**: Serverless collaborative transactions for privacy. Fixed denomination + output shuffling.
- **Fee sniping defense**: nLockTime = currentBlockHeight on standard sends.
- **Dust protection**: Blocks outputs < 546 sats. Pinning warnings at 5+ unconfirmed UTXOs.
- **Encrypted backups**: AES-256-GCM + PBKDF2 (600K rounds).
- **Embedded Tor (Arti)**: Direct Arti stream (no SOCKS5 proxy). Serialized via Mutex (1 request at a time). 60s global timeout prevents deadlocks. Warmup pre-establishes HS circuit.
- **Clipboard security**: `secureCopy()` auto-clears sensitive data after 30 seconds.
- **Debug logging**: All `print()` statements wrapped in `#if DEBUG` — zero logging in Release builds.
- **Keychain hardening**: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + explicit `kSecAttrSynchronizable: false`.
- **TLS certificate pinning**: SPKI SHA-256 pins for mempool.space. Current cert expires Sep 28 2026.
- **Address query anti-correlation**: Shuffled address order before batched UTXO queries.
- **No analytics**: Zero telemetry, crash reporters, or tracking SDKs. Single dependency: `secp256k1.swift`.
- **NON_WITNESS_UTXO**: Full previous transaction included in PSBT for BIP174 compliance.

## Known Limitations

- **Single-key Taproot vaults**: Ledger's `is_policy_sane()` rejects duplicate pubkeys. Vault creation is P2WSH only. [GitHub issue #442](https://github.com/LedgerHQ/app-bitcoin-new/issues/442).
- **Taproot vault funds recovery**: Existing Taproot vault funds cannot be spent via key-path because the address was tweaked with the script tree Merkle root.
- **BLE only**: No USB transport for Ledger.
- **Tor foreground only**: Arti Tor client works only while app is in foreground. Circuits re-established on resume.
- **Tor bootstrap time**: ~60s for first .onion circuit. Subsequent connections faster with cached state.
- **PlugTor binary size**: ~49MB static library (stripped to ~10-15MB in App Store distribution).

## Tor Integration (plug-tor/)

- **Engine**: Arti (Rust Tor client by Tor Project) compiled as iOS static library
- **Crate**: `plug-tor/` — wraps `arti-client` + `tokio` runtime (4 worker threads)
- **Build**: `cd plug-tor && ./build-ios.sh` → `PlugTor.xcframework`
- **C-FFI**: `plug_tor_start()`, `plug_tor_stop()`, `plug_tor_is_running()`, `plug_tor_warmup()`, `plug_tor_fetch()` (GET), `plug_tor_post()` (POST), `plug_tor_free_string()`
- **Timeouts**: 60s global timeout on fetch/post (prevents Mutex deadlock). 30s per-chunk read timeout. 180s warmup window.
- **Bridging**: `PLUG-Bridging-Header.h` imports `plug_tor.h`
- **Swift wrapper**: `TorManager.swift` — `.disconnected/.connecting/.warmingUp/.connected/.error` state
- **Linker flags**: `-lsqlite3 -lz -framework Security -framework SystemConfiguration`

## Personal Node Infrastructure (plug-node/)

- **Stack**: Bitcoin Core (testnet) + Electrs (REST mode) + Tor hidden service, all Docker
- **VPS**: `/home/zak/plug-node/docker-compose.yml`
- **Data**: `/data/bitcoin/` (blockchain), `/data/electrs/` (index), `/data/tor/` (HS keys)
- **Electrs REST**: Same API as mempool.space (`/api/address/{addr}/utxo`, `/api/tx/{txid}`, etc.)
- **Tor .onion**: Exposes Electrs port 3002 as hidden service
- **Watchdog**: `plug-watchdog.timer` (systemd, every 2 min) — auto-restarts containers, logs to `/var/log/plug-node-watchdog.log`
- **iOS integration**: Settings > Personal Node > toggle + paste .onion + "Test connection". `TorConfig.resolve()` routes all queries.

## Website & Deployment

- **Domain**: bitcoin-plug.com
- **Hosted**: VPS (LAN 192.168.1.144), nginx, rsync deploy
- **Static files**: `docs/index.html` + `docs/style.css` + `docs/og.png`
- **Like counter API**: Python on port 3847, systemd service `plug-likes`
- **Deploy**: `rsync -avz -e "ssh -p <PORT> -i ~/.ssh/id_ed25519" docs/ zak@146.70.194.119:/home/zak/sites/plug/`

## Code Quality Principles

- **Bitcoin Script philosophy**: Deterministic, non-Turing complete where possible. One input → one path → one output. No hidden branches.
- **No duplication**: Shared logic extracted into protocols (`ContractVM`), unified functions (`buildP2WSHSpend`), centralized utilities (`BalanceUnit`, `ColorTheme`, `TorConfig.resolve()`).
- **No dead code**: Every function is called. Unused code is deleted, not commented out.
- **No silent failures**: Errors propagate explicitly. `try?` only used where failure is genuinely acceptable.
- **Minimal dependencies**: Single external dependency (`secp256k1.swift`). Crypto via CryptoKit. Tor via embedded Arti.
