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

- **Entry point**: `PLUGApp.swift` — routes to onboarding or 5-tab main view (Home, Wallet, Contracts, Learn, Script). Runs keychain migration on version bump (iOS keychain persists across app deletion). Current migration: v3 (full keychain wipe for demo mode removal).
- **Branding**: All tabs use `PlugHeader(pageName:)` — displays "PLUG." with orange dot + page name. Home shows TESTNET badge + Connect + Settings. Other tabs show only "PLUG. PageName".
- **Language**: English only. All user-facing strings are in English.
- **No demo mode**: Removed. App requires a real Ledger connection. Testnet is the dev environment.
- **Models/Models.swift** — UTXO, Transaction, Contract (with V2 wallet policy fields, Taproot fields: `isTaproot`, `taprootInternalKey`, `taprootMerkleRoot`, `taprootScripts`, `scriptPubKey`, `keyIndex`), WalletAddress (with `.Status` enum: fresh/funded/used, `Hashable`), BlockchainInfo, FeeEstimate, etc.
- **Core/Bitcoin/** — Bitcoin protocol logic:
  - `PSBTBuilder` — BIP174/BIP371 PSBT construction with witness UTXOs, BIP32 derivation maps, and Taproot input keys (tapInternalKey, tapMerkleRoot, tapLeafScript, tapBip32Derivation)
  - `SpendManager` — All contract spend paths (P2WPKH, CLTV, CSV, multisig, HTLC, channels, P2TR key-path, P2TR script-path) with correct sequence/locktime/witness stacks
  - `CoinSelection` — Largest-first, smallest-first, exact-match strategies; 68 vbyte P2WPKH inputs, 546-sat dust threshold
  - `CoinJoin` — Serverless PSBT-based collaborative transactions. `createCoinJoinPSBT`, `joinCoinJoin`, `analyzePSBT`. Fixed denomination outputs with random shuffling for privacy. Parses inputs/outputs from raw unsigned transactions.
  - `ScriptBuilder` — **All scripts use Ledger-compatible miniscript format**. Template scripts for each contract type match the Ledger's miniscript compiler output byte-for-byte.
  - `KeyDerivation` — BIP32 non-hardened derivation from xpub, BIP44 gap limit scan (20 consecutive empty addresses), P2WPKH and P2TR (BIP86) address generation
  - `Secp256k1` — Thin wrapper around **libsecp256k1** via `GigaBitcoin/secp256k1.swift` SPM package. Includes x-only key support (BIP340).
  - `TaprootBuilder` — BIP340/341/342: tagged hashes, MAST construction, key tweaking, control block, P2TR address generation
  - `MuSig2` — Key aggregation, coefficient calculation, session management (signing deferred to Ledger)
- **Core/Ledger/** — Hardware wallet integration:
  - `LedgerManager` — CoreBluetooth BLE transport, APDU framing (tag=0x05, MTU=156), xpub retrieval with coin_type detection, master fingerprint via INS=0x05
  - `LedgerProtocol` (V1, CLA=0xE0) and `LedgerProtocolV2` (CLA=0xE1) — V2 uses merkleized PSBT signing with client command flow
  - `LedgerSigningV2` — V2 SIGN_PSBT + REGISTER_WALLET. PSBTv2 map construction (separate builders for P2WSH and P2TR), Merkle trees, CommandInterpreter, wallet policy serialization. Client command loop: 500 rounds max.
  - `ContractSigner` — High-level orchestrator: builds wallet policy from contract, auto-builds `inputAddressInfos` when not provided (fetches UTXOs, derives scriptPubKey from address), registers if needed, signs via V2 merkleized PSBT. Selects P2WSH or P2TR spend path based on `contract.isTaproot`.
  - `WalletPolicyBuilder` — Generates Ledger V2 wallet policy descriptors: `wsh(...)` for P2WSH, `tr(...)` for Taproot. **Taproot policies use distinct key indices** (`@0` for internal key, `@1` for script key) — Ledger rejects duplicate pubkeys in keysInfo (`is_policy_sane` in `policy.c:2012`).
- **Core/Network/** — `MempoolAPI` (mempool.space REST + TLS pinning + Tor SOCKS5 proxy), `NetworkConfig` (testnet/mainnet runtime switching), `WebSocketManager` (real-time blocks/price), `TorConfig`
- **Core/Storage/** — `KeychainStore`, `ContractStore`, `FrozenUTXOStore`, `TxLabelStore`, `AddressBook`, `BIP329Labels`, `BackupManager`, `BiometricStore`
- **Views/** — Shared components: `PlugHeader`, `BlockDurationPicker`, `ContractCreatedSheet`, `LearnView` (fetches Mastering Bitcoin chapters from GitHub API as rendered HTML in WKWebView), `KeyIndexPicker` (reusable BIP32 key index selector with derivation path display), `CoinJoinView`
- **ViewModels/** — One per feature: `WalletVM` (gap limit scan, address rotation, coin control, balance display cycling sats/BTC/USD, privacy score, BTC price), `HomeVM`, `VaultVM` (P2WSH only — Taproot disabled for single-key), `InheritanceVM`, `PoolVM`, `HTLCVM`, `ChannelVM`, `CoinJoinVM`, `BackupVM`, `ScriptVM` (step-by-step execution)

### Ledger App (app-bitcoin-new/)

C application using Ledger SDK. Key source in `src/`:
- `handler/sign_psbt.c` — Main PSBT signing handler (merkleized V2 protocol)
- `common/wallet.c` — Wallet policy parsing and validation (`parse_policy_map_key_info`, `is_wallet_policy_standard`)
- `handler/lib/policy.c` — `is_policy_sane()` — **rejects duplicate compressed pubkeys in keysInfo** (line 2012). This prevents single-key Taproot policies with script trees. Filed as [GitHub issue #442](https://github.com/LedgerHQ/app-bitcoin-new/issues/442).
- `common/merkle.c` — Merkle tree protocol
- `handler/lib/get_merkle_preimage.c` — Preimage fetch with SHA256 hash verification

Client libraries: `bitcoin_client/` (Python), `bitcoin_client_js/` (TypeScript), `bitcoin_client_rs/` (Rust).

Protocol specification: `doc/bitcoin.md` (commands), `doc/wallet.md` (wallet policies).

## Key Design Decisions

- **Testnet-first safety**: Forces testnet on first launch; mainnet broadcast is disabled during development
- **Ledger-only signing**: Private keys never leave the hardware device; the app only holds xpubs. No demo mode.
- **All signing via V2 protocol**: Every signing path uses CLA=0xE1 merkleized PSBT protocol. Client command loop: 500 rounds max (2 inputs need ~273 rounds).
- **Taproot single-key limitation**: Ledger's `is_policy_sane()` rejects duplicate pubkeys. Single-key Taproot vaults CANNOT be signed. Vault creation is P2WSH only. Taproot is only for multi-key contracts (Inheritance, HTLC) where `@0` and `@1` are genuinely different xpubs.
- **Taproot P2TR input maps**: Use `TAP_BIP32_DERIVATION` (key 0x16) with x-only pubkey instead of `BIP32_DERIVATION` (key 0x06). No `WITNESS_SCRIPT` (key 0x05) for Taproot — Ledger derives script from wallet policy.
- **Contract key index**: Each contract stores `keyIndex` — the BIP32 derivation index used at creation. `KeyIndexPicker` shows derivation path (m/84'/coin_type'/0'/0/N) and derived address.
- **Home page never calls loadWallet()**: Only the Wallet tab triggers full gap limit scan. Home refresh calls `refreshUTXOs()` to avoid clearing wallet data.
- **CoinJoin**: Serverless PSBT-based. Participants exchange PSBTs manually. Fixed denomination outputs with random shuffling. Each user signs only their own inputs via standard `wpkh(@0/**)` policy. No server, no registration.
- **Balance display**: Tappable — cycles sats → BTC (8 decimals) → USD. Sats formatted with thousand separators (196 732).
- **Privacy score**: 0-100 based on address reuse (-15 each), dust UTXOs (-5), UTXO count (>20 = -10). Shown on Home page.
- **Script playground**: Step-by-step execution, guided lessons (8 from Mastering Bitcoin ch7), opcode reference (40+), script decoder (hex → opcodes), 15 loadable templates.
- **Wallet policy registration**: P2WSH/P2TR contracts require REGISTER_WALLET (INS=0x02) on first spend. HMAC stored in `Contract.walletPolicyHmac`.
- **Miniscript-aligned scripts**: All contract scripts match the Ledger's miniscript compiler output byte-for-byte.
- **External keys must be xpubs**: The Ledger V2 protocol requires xpub/tpub for ALL keys (no raw hex pubkeys).
- **Coin_type auto-detection**: Detects "Bitcoin" (coin_type=0) or "Bitcoin Test" (coin_type=1) app.
- **Master fingerprint from device**: Always fetched via GET_MASTER_FINGERPRINT (INS=0x05).
- **Keychain persistence**: iOS keychain survives app deletion. Versioned migration (currently v3).
- **xpub change detection**: Posts `.ledgerXpubChanged` notification → full wallet reset + rescan.
- **Address rotation**: Never reuse addresses. Fresh/Funded/Used tracking. Change addresses use `nextFreshChangeAddress()`.
- **Gap limit scan**: Scans from index 0 until 20 consecutive empty addresses found.
- **Coin control**: Manual UTXO selection in send flow + CoinJoin.
- **RBF**: Standard sends use sequence 0xFFFFFFFD; timelock spends use 0xFFFFFFFE.
- **Encrypted backups**: AES-256-GCM + PBKDF2 (600K rounds).

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
- **Note**: Pool is now a sub-view inside Contracts tab, not a separate tab.

### Channel (2-of-2 + CLTV refund)
- **Descriptor**: `wsh(or_d(multi(2,@0/**,@1/**),and_v(v:pk(@0/**),after(N))))`
- **Keys**: 2 (@0=sender internal, @1=receiver external xpub)

## Ledger V2 Signing Protocol

Reference: `app-bitcoin-new/doc/bitcoin.md`, `app-bitcoin-new/doc/wallet.md`

### Signing Flow (ContractSigner)
1. Build `WalletPolicyBuilder.Policy` from contract parameters
2. Auto-build `inputAddressInfos` if not provided (derives pubkey, fetches UTXOs, gets scriptPubKey from address)
3. Check if `contract.walletPolicyHmac` exists for this descriptor
4. If not: **REGISTER_WALLET** (INS=0x02) — user approves on Ledger screen — store HMAC
5. Detect Taproot (`descriptor.hasPrefix("tr(")`) and use `buildPSBTv2InputMapsForP2TR` instead of P2WSH maps
6. **SIGN_PSBT** (INS=0x04) with wallet_id + HMAC + PSBTv2 merkleized maps
7. Collect signatures from YIELD commands (500 round limit)
8. Build witness stacks and finalize transaction

### Taproot-specific PSBT Input Maps
- NO `WITNESS_SCRIPT` (key 0x05) — Ledger derives script from wallet policy
- Use `TAP_BIP32_DERIVATION` (key 0x16) with x-only pubkey (32 bytes, last 32 of compressed)
- Value format: `varint(0 leaf hashes) + fingerprint + path_elements`
- Purpose read from key origin string (supports both `84'` and `86'`)

### Common Error Codes
| SW | Meaning | Common Cause |
|----|---------|--------------|
| 0x6A80 | INCORRECT_DATA | Script mismatch, coin_type mismatch, wrong fingerprint, no internal inputs, UTXO scriptPubKey mismatch |
| 0x6A82 | NOT_SUPPORTED | Duplicate pubkeys in keysInfo (`is_policy_sane` rejection), bare xpub matching internal key, unsupported policy |
| 0x6985 | DENY | User rejected on Ledger screen |
| 0x9000 | OK | Success |
| 0xE000 | INTERRUPTED | Client command request (normal flow) |

### BLE Transport
- Frame format: `tag(0x05) + seq(2) + [length(2) first frame only] + data`
- Inter-frame delay: 50ms (configurable in `LedgerManager.sendAPDU`)
- Write type: `.withResponse` (Nano X requirement)
- Max payload per frame: ~59 bytes (first) / ~61 bytes (subsequent)

## UI Architecture

### Tab Structure (5 tabs)
1. **Home** — Balance, network stats, privacy score + UTXO health (side-by-side widgets), confirmation tracker, daily Bitcoin tip, contracts summary
2. **Wallet** — Addresses (receiving + change with status badges), UTXOs with freeze/thaw, transactions. Action buttons: Send / Receive / CoinJoin (Apple-style vertical icon+label). Balance taps to cycle sats/BTC/USD. Receive sheet with address index wheel picker.
3. **Contracts** — Hub with NavigationLinks to Vault, Inheritance, HTLC, Channel, Pool, OP_RETURN. Sub-views use standard nav bar with toolbar "+" buttons.
4. **Learn** — Mastering Bitcoin chapters fetched from GitHub API, rendered in WKWebView with dark theme CSS.
5. **Script** — Bitcoin Script playground with step-by-step execution, templates (15), opcode reference (40+), guided lessons (8), hex decoder. Header: Reset (circle) + Step (orange circle) + Run (green circle).

### Header Pattern
- **Tab roots** (Home, Wallet, Script): `PlugHeader` in a `List` with hidden nav bar
- **Sub-views** (Vault, Inheritance, etc.): standard `.navigationTitle()` + `.toolbar` with visible nav bar and back button
- **Home only**: shows TESTNET badge + Connect status + Settings gear

### Common Patterns
- Apple-style action buttons: vertical `VStack(icon, label)` with tinted background in `RoundedRectangle`
- Cards: `.ultraThinMaterial` background with 14-16pt rounded corners
- Contract rows: List-based with `.listRowInsets`, `.listRowBackground(.clear)`, `.listRowSeparator(.hidden)`
- Sheets: own `NavigationStack` with `.navigationBarTitleDisplayMode(.inline)` + cancel toolbar item

## Security

- **Zero keys on device**: Only xpubs. Private keys exist exclusively on the Ledger hardware.
- **Testnet-first**: Forces testnet on first launch.
- **Address rotation**: Never reuse spent-from addresses. Fresh change address per transaction.
- **Privacy score**: Tracks address reuse, exposed pubkeys, UTXO consolidation. Shown on Home.
- **Coin control**: Manual UTXO selection to prevent mixing KYC/non-KYC funds.
- **CoinJoin**: Serverless collaborative transactions for privacy. Fixed denomination + output shuffling.
- **Fee sniping defense**: nLockTime = currentBlockHeight on standard sends.
- **Dust protection**: Blocks outputs < 546 sats. Pinning warnings at 5+ unconfirmed UTXOs.
- **Encrypted backups**: AES-256-GCM + PBKDF2 (600K rounds).
- **Tor support**: Optional SOCKS5 proxy routing to mempool.space .onion address.
- **Wallet policy verification**: Ledger registers each P2WSH/P2TR policy with HMAC.
- **HTLC preimage backup**: Auto-saved to iOS Keychain (hardware-encrypted).
- **Keychain migration**: Versioned wipe on app update to clear stale data.

## Known Limitations

- **Single-key Taproot vaults**: Ledger's `is_policy_sane()` in `policy.c:2012` rejects duplicate compressed pubkeys in keysInfo. Single-key Taproot policies with script trees (e.g., `tr(@0/**,and_v(v:pk(@1/**),after(N)))` where @0 and @1 are the same xpub) cannot be registered. Vault creation is P2WSH only. [GitHub issue #442](https://github.com/LedgerHQ/app-bitcoin-new/issues/442).
- **Taproot vault funds recovery**: Existing Taproot vault funds cannot be spent via key-path (`tr(@0/**)`) because the address was tweaked with the script tree Merkle root, producing a different address than BIP-86 key-path.
- **BLE only**: No USB transport for Ledger. Same APDUs regardless of transport.
- **BackupManager vs BackupVM**: Two backup systems exist. `BackupVM` (with simpler XOR crypto) is the one wired to the UI. `BackupManager` (with proper PBKDF2+HMAC) is dead code.

## Website & Deployment

- **Domain**: bitcoin-plug.com
- **Hosted**: VPS via Cloudflare Tunnel
- **Static files**: `docs/index.html` + `docs/style.css`
- **Deploy**: `rsync -avz -e "ssh -p PORT -i ~/.ssh/id_ed25519" docs/ zak@IP:/home/zak/sites/plug/`
