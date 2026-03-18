# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PLUG (**Programmable Locking UTXO Gateway**) is a Bitcoin programmability tool — not a wallet. It lets users create complex smart contract transactions on the Bitcoin network ("code money"). The **Ledger hardware wallet is always the signer** — users keep custody of their funds.

It supports standard P2WPKH transactions, advanced Bitcoin smart contracts (P2WSH): time-locked vaults (Vault), inheritance (Inheritance), multisig pools (Pool), HTLCs, payment channels — and **Taproot (P2TR)** contracts with Schnorr signatures and MAST.

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

### Python Signing Test (verify Ledger signing pipeline)
```bash
cd app-bitcoin-new
pip3 install ./bitcoin_client/
python3 -c "
from ledger_bitcoin import createClient, WalletPolicy, Chain
from ledger_bitcoin.client_base import TransportClient
transport = TransportClient('hid')
client = createClient(transport, chain=Chain.TEST, debug=True)
fpr = client.get_master_fingerprint()
xpub = client.get_extended_pubkey(\"m/84'/1'/0'\", display=False)
print(f'Fingerprint: {fpr.hex()}, xpub: {xpub}')
"
```

## Architecture

### PLUG App (PLUG/)

**MVVM + Swift Concurrency** with `@MainActor` ViewModels and `@Published` state.

- **Entry point**: `PLUGApp.swift` — routes to onboarding or 6-tab main view (Home, Wallet, Contracts, Pool, Learn, Script). Runs keychain migration on version bump (iOS keychain persists across app deletion). Current migration: v3 (full keychain wipe for demo mode removal).
- **Branding**: All tabs use `PlugHeader(pageName:)` — displays "PLUG." with orange dot + page name. No SwiftUI `.navigationTitle()` on main tabs.
- **Language**: English only. All user-facing strings are in English.
- **No demo mode**: Removed. App requires a real Ledger connection. Testnet is the dev environment.
- **Models/Models.swift** — UTXO, Transaction, Contract (with V2 wallet policy fields, Taproot fields: `isTaproot`, `taprootInternalKey`, `taprootMerkleRoot`, `taprootScripts`, `scriptPubKey`), WalletAddress (with `.Status` enum: fresh/funded/used), BlockchainInfo, FeeEstimate, etc.
- **Core/Bitcoin/** — Bitcoin protocol logic:
  - `PSBTBuilder` — BIP174/BIP371 PSBT construction with witness UTXOs, BIP32 derivation maps, and Taproot input keys (tapInternalKey, tapMerkleRoot, tapLeafScript, tapBip32Derivation)
  - `SpendManager` — All contract spend paths (P2WPKH, CLTV, CSV, multisig, HTLC, channels, P2TR key-path, P2TR script-path) with correct sequence/locktime/witness stacks
  - `CoinSelection` — Largest-first, smallest-first, exact-match strategies; 68 vbyte P2WPKH inputs, 546-sat dust threshold
  - `ScriptBuilder` — **All scripts use Ledger-compatible miniscript format**. Template scripts for each contract type match the Ledger's miniscript compiler output byte-for-byte.
  - `KeyDerivation` — BIP32 non-hardened derivation from xpub, BIP44 gap limit scan (20 consecutive empty addresses), P2WPKH and P2TR (BIP86) address generation
  - `Secp256k1` — Thin wrapper around **libsecp256k1** (Bitcoin Core's C library, via `GigaBitcoin/secp256k1.swift` SPM package). All EC operations use the battle-tested, constant-time, audited C implementation. Includes x-only key support (BIP340): `xOnly()`, `liftXOnly()`, `hasEvenY()`, `tweakAdd()`.
  - `TaprootBuilder` — BIP340/341/342: tagged hashes, MAST construction (tapLeafHash, tapBranchHash, computeMerkleRoot), key tweaking with parity tracking, control block construction, Merkle proof generation, P2TR scriptPubKey and address generation
  - `MuSig2` — Key aggregation, coefficient calculation, session management (signing deferred to Ledger)
- **Core/Ledger/** — Hardware wallet integration:
  - `LedgerManager` — CoreBluetooth BLE transport, APDU framing (tag=0x05, MTU=156), xpub retrieval with coin_type detection, master fingerprint via INS=0x05
  - `LedgerProtocol` (V1, CLA=0xE0) and `LedgerProtocolV2` (CLA=0xE1) — V2 uses merkleized PSBT signing with client command flow
  - `LedgerSigningV2` — V2 SIGN_PSBT + REGISTER_WALLET implementation: PSBTv2 map construction, Merkle trees, CommandInterpreter, wallet policy serialization, multi-key support for P2WSH and P2TR
  - `ContractSigner` — High-level orchestrator: builds wallet policy from contract, registers if needed (stores HMAC), signs via V2 merkleized PSBT. Supports P2WSH and Taproot spend paths.
  - `WalletPolicyBuilder` — Generates Ledger V2 wallet policy descriptors: `wsh(...)` for P2WSH, `tr(...)` for Taproot (key-path, vault, inheritance, HTLC)
- **Core/Network/** — `MempoolAPI` (mempool.space REST + TLS pinning + Tor SOCKS5 proxy routing via TorConfig), `NetworkConfig` (testnet/mainnet runtime switching), `WebSocketManager` (real-time blocks/price), `TorConfig` (SOCKS5 proxy to mempool.space .onion address)
- **Core/Storage/** — `KeychainStore` (xpubs, master fingerprint, coin_type — all keys in `KeychainKey` enum), `ContractStore`, `FrozenUTXOStore`, `TxLabelStore`, `AddressBook`, `BIP329Labels`, `BackupManager`, `BiometricStore`
- **Views/** — Shared components: `PlugHeader`, `BlockDurationPicker`, `ContractCreatedSheet`, `LearnView` (fetches Mastering Bitcoin chapters from GitHub API as rendered HTML, displayed in WKWebView with dark theme CSS), `KeyIndexPicker`
- **ViewModels/** — One per feature: `WalletVM` (gap limit scan, address rotation, coin control, change address rotation, xpub change detection via `.ledgerXpubChanged` notification), `HomeVM`, `VaultVM` (P2WSH + Taproot toggle), `InheritanceVM` (P2WSH + Taproot toggle), `PoolVM`, `HTLCVM`, `ChannelVM`, `BackupVM` (AES-256-GCM + PBKDF2 encrypted backups), etc.

### Ledger App (app-bitcoin-new/)

C application using Ledger SDK. Key source in `src/`:
- `handler/sign_psbt.c` — Main PSBT signing handler (merkleized V2 protocol)
- `common/wallet.c` — Wallet policy parsing and validation (`parse_policy_map_key_info`, `is_wallet_policy_standard`)
- `common/merkle.c` — Merkle tree protocol
- `handler/lib/get_merkle_preimage.c` — Preimage fetch with SHA256 hash verification
- `handler/lib/policy.c` — `get_wallet_script`, `get_derived_pubkey`, `get_extended_pubkey_from_client`
- `musig/` — MuSig2 support

Client libraries: `bitcoin_client/` (Python — reference implementation), `bitcoin_client_js/` (TypeScript), `bitcoin_client_rs/` (Rust).

Protocol specification: `doc/bitcoin.md` (commands), `doc/wallet.md` (wallet policies).

## Key Design Decisions

- **Testnet-first safety**: Forces testnet on first launch; mainnet broadcast is disabled during development
- **Ledger-only signing**: Private keys never leave the hardware device; the app only holds xpubs. No demo mode — real Ledger required.
- **All signing via V2 protocol**: Every signing path (P2WPKH sends, P2WSH contracts, P2TR Taproot) uses CLA=0xE1 merkleized PSBT protocol. No V1 legacy signing.
- **Wallet policy registration**: P2WSH/P2TR contracts require REGISTER_WALLET (INS=0x02) on first spend. HMAC is stored in `Contract.walletPolicyHmac` for future spends.
- **Miniscript-aligned scripts**: All contract scripts match the Ledger's miniscript compiler output byte-for-byte. This is critical — even semantically equivalent scripts with different byte order will cause 0x6A80.
- **External keys must be xpubs**: The Ledger V2 protocol requires xpub/tpub for ALL keys (no raw hex pubkeys). Multi-party contracts store counterparty xpubs in `Contract.heirXpub`, `Contract.receiverXpub`, `Contract.multisigXpubs`.
- **Coin_type auto-detection**: Detects whether "Bitcoin" (coin_type=0) or "Bitcoin Test" (coin_type=1) app is running. Saves coin_type to keychain (`KeychainStore.KeychainKey.ledgerCoinType`). All BIP32 paths, key origins, and PSBT derivations use this value.
- **Master fingerprint from device**: Always fetched via GET_MASTER_FINGERPRINT (INS=0x05), never derived from xpub parent fingerprint (which is different from the master fingerprint)
- **Keychain persistence**: iOS keychain survives app deletion. `PLUGApp.init()` runs versioned migration (`keychain_version`, currently v3) to clear stale data.
- **xpub change detection**: `LedgerVM.fetchAndSaveXpub()` posts `.ledgerXpubChanged` notification. `WalletVM` listens and does a full reset (addresses, UTXOs, transactions, statuses) then rescans.
- **Address rotation**: Never reuse addresses. Addresses tracked as Fresh/Funded/Used. Change addresses always use `nextFreshChangeAddress()`. Spent-from addresses marked as "PUBKEY EXPOSED".
- **Gap limit scan**: Wallet scans from index 0 until 20 consecutive empty addresses found (BIP44 standard). Finds all funds regardless of index.
- **Coin control**: Users can manually select which UTXOs to spend in the send flow.
- **Safety features**: Dust output warnings (< 546 sats), absurd fee alerts (> 100 sat/vB), fee sniping defense (nLockTime), duplicate key check (Pool), transaction pinning warning, HTLC preimage keychain backup, delete confirmation with balance warning
- **RBF**: Standard sends use sequence 0xFFFFFFFD (BIP125 RBF); timelock spends use 0xFFFFFFFE to enforce nLockTime
- **Network privacy**: Optional Tor routing via SOCKS5 proxy to mempool.space .onion address. Requires Orbot on device.
- **Encrypted backups**: AES-256-GCM with PBKDF2-HMAC-SHA256 key derivation (600,000 rounds). Random 32-byte salt per backup. Versioned format.

## Contract Script Formats (Miniscript-aligned)

**CRITICAL**: All scripts must match the Ledger's miniscript compiler output exactly. Different byte order = different P2WSH address = 0x6A80 signing failure.

### Vault (CLTV time-lock vault)
- **P2WSH**: `wsh(and_v(v:pk(@0/**),after(N)))`
- **P2TR**: `tr(@0/**,and_v(v:pk(@0/**),after(N)))`
- **Script**: `<KEY> OP_CHECKSIGVERIFY <N> OP_CHECKLOCKTIMEVERIFY`
- **Keys**: 1 (internal only)

### Inheritance (CSV inheritance)
- **P2WSH**: `wsh(or_d(pk(@0/**),and_v(v:pk(@1/**),older(N))))`
- **P2TR**: `tr(@0/**,{pk(@0/**),and_v(v:pk(@1/**),older(N))})`
- **Script**: `<OWNER> OP_CHECKSIG OP_IFDUP OP_NOTIF <HEIR> OP_CHECKSIGVERIFY <N> OP_CSV OP_ENDIF`
- **Keys**: 2 (@0=owner internal, @1=heir external xpub)

### HTLC (Hash Time-Lock)
- **Descriptor**: `wsh(andor(pk(@0/**),sha256(H),and_v(v:pk(@1/**),after(N))))`
- **Script**: `<RECEIVER> OP_CHECKSIG OP_NOTIF <SENDER> OP_CHECKSIGVERIFY <N> OP_CLTV OP_ELSE OP_SIZE <32> OP_EQUALVERIFY OP_SHA256 <H> OP_EQUAL OP_ENDIF`
- **Keys**: 2 (@0=receiver for claim, @1=sender; swapped for refund)

### Pool (M-of-N multisig)
- **Descriptor**: `wsh(sortedmulti(M,@0/**,@1/**,...,@(N-1)/**))`
- **Script**: `<M> <K1> ... <KN> <N> OP_CHECKMULTISIG` (keys BIP67 sorted)
- **Keys**: N (one internal with origin, rest external xpubs)

### Channel (2-of-2 + CLTV refund)
- **Descriptor**: `wsh(or_d(multi(2,@0/**,@1/**),and_v(v:pk(@0/**),after(N))))`
- **Script**: `<2> <SENDER> <RECEIVER> <2> OP_CHECKMULTISIG OP_IFDUP OP_NOTIF <SENDER> OP_CHECKSIGVERIFY <N> OP_CLTV OP_ENDIF`
- **Keys**: 2 (@0=sender internal, @1=receiver external xpub)

## Taproot (P2TR) — BIP340/341/342

### Key Operations (Secp256k1.swift)
- `xOnly(compressedKey)` — extract 32-byte x-only from 33-byte compressed key
- `liftXOnly(xOnlyKey)` — lift to full compressed key with even Y (0x02 prefix)
- `hasEvenY(compressedKey)` — check Y parity
- `tweakAdd(pubkey, tweak)` — constant-time key tweaking via secp256k1_ec_pubkey_tweak_add

### MAST Construction (TaprootBuilder.swift)
- `taggedHash(tag, data)` — BIP340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data)
- `tapLeafHash(script)` — TapLeaf = TaggedHash("TapLeaf", leafVersion || compactSize(script) || script)
- `tapBranchHash(left, right)` — lexicographically sorted children
- `computeMerkleRoot(scripts)` — balanced binary Merkle tree
- `tweakPublicKeyFull(internalKey, merkleRoot)` — returns TweakResult with xOnly + full + parityBit
- `controlBlock(internalKey, scripts, scriptIndex)` — for script-path spending

### Taproot Wallet Policies
- Key-path only: `tr(@0/**)`
- Vault: `tr(@0/**,and_v(v:pk(@0/**),after(N)))`
- Inheritance: `tr(@0/**,{pk(@0/**),and_v(v:pk(@1/**),older(N))})`
- HTLC: `tr(@0/**,andor(pk(@0/**),sha256(H),and_v(v:pk(@1/**),after(N))))`

### BIP86 Derivation
- Path: `m/86'/coin_type'/0'/change/index`
- `ExtendedPublicKey.taprootAddress(isTestnet:)` — P2TR address from key
- `AddressDerivation.deriveTaprootAddresses()` — batch derivation

## Ledger V2 Signing Protocol

Reference: `app-bitcoin-new/doc/bitcoin.md`, `app-bitcoin-new/doc/wallet.md`

### Signing Flow (ContractSigner)
1. Build `WalletPolicyBuilder.Policy` from contract parameters
2. Check if `contract.walletPolicyHmac` exists for this descriptor
3. If not: **REGISTER_WALLET** (INS=0x02) — user approves on Ledger screen — store HMAC
4. **SIGN_PSBT** (INS=0x04) with wallet_id + HMAC + PSBTv2 merkleized maps
5. Collect signatures from YIELD commands
6. Build witness stacks and finalize transaction

### Client Commands
| Code | Command | Response Format |
|------|---------|-----------------|
| 0x10 | YIELD | Empty (collect yielded data) |
| 0x40 | GET_PREIMAGE | varint(len) + byte(partial_len) + data |
| 0x41 | GET_MERKLE_LEAF_PROOF | 32-byte leaf_hash + proof_size + n_in_response + 32*n proof hashes |
| 0x42 | GET_MERKLE_LEAF_INDEX | 1-byte found + varint(index) |
| 0xA0 | GET_MORE_ELEMENTS | n_elements + element_size + data |

### Common Error Codes
| SW | Meaning | Common Cause |
|----|---------|--------------|
| 0x6A80 | INCORRECT_DATA | Script mismatch, coin_type mismatch, wrong fingerprint, no internal inputs |
| 0x6A82 | FILE_NOT_FOUND | Raw pubkey instead of xpub in key info, wrong app installed |
| 0x6985 | DENY | User rejected on Ledger screen |
| 0x9000 | OK | Success |
| 0xE000 | INTERRUPTED | Client command request (normal flow) |

### BLE Transport
- Frame format: `tag(0x05) + seq(2) + [length(2) first frame only] + data`
- Inter-frame delay: 50ms (configurable in `LedgerManager.sendAPDU`)
- Write type: `.withResponse` (Nano X requirement)
- Max payload per frame: ~59 bytes (first) / ~61 bytes (subsequent)

## Security

- **Zero keys on device**: Only xpubs. Private keys exist exclusively on the Ledger hardware.
- **Testnet-first**: Forces testnet on first launch. Mainnet is a conscious choice.
- **Address rotation**: Never reuse spent-from addresses. Fresh change address per transaction.
- **Coin control**: Manual UTXO selection to prevent mixing KYC/non-KYC funds.
- **Fee sniping defense**: nLockTime = currentBlockHeight on standard sends.
- **Dust protection**: Blocks outputs < 546 sats. Pinning warnings at 5+ unconfirmed UTXOs.
- **Encrypted backups**: AES-256-GCM + PBKDF2 (600K rounds). No more XOR.
- **Tor support**: Optional SOCKS5 proxy routing to mempool.space .onion address.
- **Wallet policy verification**: Ledger registers each P2WSH/P2TR policy with HMAC.
- **HTLC preimage backup**: Auto-saved to iOS Keychain (hardware-encrypted).
- **Keychain migration**: Versioned wipe on app update to clear stale data from previous sessions.

## Website & Deployment

- **Domain**: bitcoin-plug.com
- **Hosted**: VPS via Cloudflare Tunnel (same tunnel as planopti projects)
- **Static files**: `docs/index.html` + `docs/style.css`
- **Deploy**: `rsync -avz -e "ssh -p PORT -i ~/.ssh/id_ed25519" docs/ zak@IP:/home/zak/sites/plug/`
