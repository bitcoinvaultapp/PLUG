# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PLUG is a **Bitcoin programmability tool** — not a wallet. It lets users create complex smart contract transactions on the Bitcoin network ("code money"). The **Ledger hardware wallet is always the signer** — users keep custody of their funds.

It supports standard P2WPKH transactions and advanced Bitcoin smart contracts (P2WSH): time-locked vaults (Vault), inheritance (Inheritance), multisig pools (Pool), HTLCs, and payment channels.

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

- **Entry point**: `PLUGApp.swift` — routes to onboarding or 5-tab main view (Home, Wallet, Contracts, Pools, Script Editor). Runs keychain migration on version bump (iOS keychain persists across app deletion).
- **Branding**: All tabs use `PlugHeader(pageName:)` — displays "PLUG." with orange dot + page name + TESTNET badge + connect status + settings gear. No SwiftUI `.navigationTitle()` on main tabs.
- **Language**: English only. All user-facing strings are in English.
- **Models/Models.swift** — UTXO, Transaction, Contract (with V2 wallet policy fields: `walletPolicyHmac`, `walletPolicyDescriptor`, external xpubs), BlockchainInfo, FeeEstimate, etc.
- **Core/Bitcoin/** — Bitcoin protocol logic:
  - `PSBTBuilder` — BIP174 PSBT construction with witness UTXOs and BIP32 derivation maps
  - `SpendManager` — All contract spend paths (P2WPKH, CLTV, CSV, multisig, HTLC, channels) with correct sequence/locktime/witness stacks
  - `CoinSelection` — Largest-first, smallest-first, exact-match strategies; 68 vbyte P2WPKH inputs, 546-sat dust threshold
  - `ScriptBuilder` — **All scripts use Ledger-compatible miniscript format**. Template scripts for each contract type match the Ledger's miniscript compiler output byte-for-byte.
  - `KeyDerivation` — BIP32 non-hardened derivation from xpub, gap limit 20, P2WPKH address generation
  - `Secp256k1` — Thin wrapper around **libsecp256k1** (Bitcoin Core's C library, via `GigaBitcoin/secp256k1.swift` SPM package). All EC operations (pubkey parse/serialize, point add, scalar multiply, BIP32 tweak_add) use the battle-tested, constant-time, audited C implementation. `UInt256`/`BInt` are kept for Base58 encoding only — no hand-rolled EC arithmetic.
- **Core/Ledger/** — Hardware wallet integration:
  - `LedgerManager` — CoreBluetooth BLE transport, APDU framing (tag=0x05, MTU=156), xpub retrieval with coin_type detection, master fingerprint via INS=0x05
  - `LedgerProtocol` (V1, CLA=0xE0) and `LedgerProtocolV2` (CLA=0xE1) — V2 uses merkleized PSBT signing with client command flow
  - `LedgerSigningV2` — V2 SIGN_PSBT + REGISTER_WALLET implementation: PSBTv2 map construction, Merkle trees, CommandInterpreter, wallet policy serialization, multi-key support for P2WSH
  - `ContractSigner` — High-level orchestrator: builds wallet policy from contract, registers if needed (stores HMAC), signs via V2 merkleized PSBT. All contract signing goes through this.
  - `WalletPolicyBuilder` — Generates Ledger V2 wallet policy descriptors (miniscript) for each contract type
  - `DemoMode` — Simulated signing for testing without physical Ledger
- **Core/Network/** — `MempoolAPI` (mempool.space REST + TLS pinning), `NetworkConfig` (testnet/mainnet runtime switching), `WebSocketManager` (real-time blocks/price)
- **Core/Storage/** — `KeychainStore` (xpubs, master fingerprint, coin_type — all keys in `KeychainKey` enum), `ContractStore`, `FrozenUTXOStore`, `TxLabelStore`, `AddressBook`, `BIP329Labels`, `BackupManager`
- **Views/** — Shared components: `PlugHeader` (branded "PLUG. PageName" header with testnet badge, connect status, settings), `BlockDurationPicker` (human-friendly duration with calendar dates), `ContractCreatedSheet` (post-creation QR + next steps + export)
- **ViewModels/** — One per feature: `WalletVM` (send flow: build->sign->broadcast, xpub cache validation), `HomeVM` (dashboard aggregation), `VaultVM`, `InheritanceVM`, `PoolVM`, `HTLCVM`, `ChannelVM`, etc.

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
- **Ledger-only signing**: Private keys never leave the hardware device; the app only holds xpubs
- **All signing via V2 protocol**: Every signing path (P2WPKH sends AND P2WSH contracts) uses CLA=0xE1 merkleized PSBT protocol. No V1 legacy signing.
- **Wallet policy registration**: P2WSH contracts require REGISTER_WALLET (INS=0x02) on first spend. HMAC is stored in `Contract.walletPolicyHmac` for future spends.
- **Miniscript-aligned scripts**: All contract scripts match the Ledger's miniscript compiler output byte-for-byte. This is critical — even semantically equivalent scripts with different byte order will cause 0x6A80.
- **External keys must be xpubs**: The Ledger V2 protocol requires xpub/tpub for ALL keys (no raw hex pubkeys). Multi-party contracts store counterparty xpubs in `Contract.heirXpub`, `Contract.receiverXpub`, `Contract.multisigXpubs`.
- **Coin_type auto-detection**: Detects whether "Bitcoin" (coin_type=0) or "Bitcoin Test" (coin_type=1) app is running. Saves coin_type to keychain (`KeychainStore.KeychainKey.ledgerCoinType`). All BIP32 paths, key origins, and PSBT derivations use this value.
- **Master fingerprint from device**: Always fetched via GET_MASTER_FINGERPRINT (INS=0x05), never derived from xpub parent fingerprint (which is different from the master fingerprint)
- **Keychain persistence**: iOS keychain survives app deletion. `PLUGApp.init()` runs versioned migration (`keychain_version`) to clear stale data when the Ledger integration changes.
- **xpub cache validation**: `WalletVM.loadWallet()` compares stored xpub string with keychain to detect changes (no EC derivation needed for the check)
- **Safety features**: Dust output warnings (< 546 sats), absurd fee alerts (> 100 sat/vB), fee sniping defense (nLockTime), duplicate key check (Pool), transaction pinning warning, HTLC preimage keychain backup, delete confirmation with balance warning
- **RBF**: Standard sends use sequence 0xFFFFFFFD (BIP125 RBF); timelock spends use 0xFFFFFFFE to enforce nLockTime
- **Network**: All blockchain data comes from mempool.space API with certificate pinning

## Contract Script Formats (Miniscript-aligned)

**CRITICAL**: All scripts must match the Ledger's miniscript compiler output exactly. Different byte order = different P2WSH address = 0x6A80 signing failure.

### Vault (CLTV time-lock vault)
- **Descriptor**: `wsh(and_v(v:pk(@0/**),after(N)))`
- **Script**: `<KEY> OP_CHECKSIGVERIFY <N> OP_CHECKLOCKTIMEVERIFY`
- **Keys**: 1 (internal only)
- **Witness**: `[signature, witnessScript]`

### Inheritance (CSV inheritance)
- **Descriptor**: `wsh(or_d(pk(@0/**),and_v(v:pk(@1/**),older(N))))`
- **Script**: `<OWNER> OP_CHECKSIG OP_IFDUP OP_NOTIF <HEIR> OP_CHECKSIGVERIFY <N> OP_CSV OP_ENDIF`
- **Keys**: 2 (@0=owner internal, @1=heir external xpub)
- **Owner witness**: `[signature, witnessScript]`
- **Heir witness**: `[signature, <empty>, witnessScript]`

### HTLC (Hash Time-Lock)
- **Descriptor**: `wsh(andor(pk(@0/**),sha256(H),and_v(v:pk(@1/**),after(N))))`
- **Script**: `<RECEIVER> OP_CHECKSIG OP_NOTIF <SENDER> OP_CHECKSIGVERIFY <N> OP_CLTV OP_ELSE OP_SIZE <32> OP_EQUALVERIFY OP_SHA256 <H> OP_EQUAL OP_ENDIF`
- **Keys**: 2 (@0=receiver for claim, @1=sender; swapped for refund)
- **Claim witness**: `[preimage, signature, witnessScript]`
- **Refund witness**: `[signature, <empty>, witnessScript]`

### Pool (M-of-N multisig)
- **Descriptor**: `wsh(sortedmulti(M,@0/**,@1/**,...,@(N-1)/**))`
- **Script**: `<M> <K1> ... <KN> <N> OP_CHECKMULTISIG` (keys BIP67 sorted)
- **Keys**: N (one internal with origin, rest external xpubs)
- **Witness**: `[<empty>, sig1, ..., sigM, witnessScript]`

### Channel (2-of-2 + CLTV refund)
- **Descriptor**: `wsh(or_d(multi(2,@0/**,@1/**),and_v(v:pk(@0/**),after(N))))`
- **Script**: `<2> <SENDER> <RECEIVER> <2> OP_CHECKMULTISIG OP_IFDUP OP_NOTIF <SENDER> OP_CHECKSIGVERIFY <N> OP_CLTV OP_ENDIF`
- **Keys**: 2 (@0=sender internal, @1=receiver external xpub)
- **Cooperative close witness**: `[<empty>, senderSig, receiverSig, witnessScript]`
- **Refund witness**: `[senderSig, <empty>, witnessScript]`

## Ledger V2 Signing Protocol

Reference: `app-bitcoin-new/doc/bitcoin.md`, `app-bitcoin-new/doc/wallet.md`

### Signing Flow (ContractSigner)
1. Build `WalletPolicyBuilder.Policy` from contract parameters
2. Check if `contract.walletPolicyHmac` exists for this descriptor
3. If not: **REGISTER_WALLET** (INS=0x02) — user approves on Ledger screen — store HMAC
4. **SIGN_PSBT** (INS=0x04) with wallet_id + HMAC + PSBTv2 merkleized maps
5. Collect signatures from YIELD commands
6. Build witness stacks and finalize transaction

### Standard P2WPKH Sends
- Uses default policy `wpkh(@0/**)` with 32-byte zero HMAC (no registration needed)
- Handled by `LedgerSigningV2.signPSBT()`

### P2WSH Contract Signing
- Uses registered policy with stored HMAC
- Handled by `ContractSigner.signContractSpend()` → `LedgerSigningV2.signPSBTWithPolicy()`
- PSBTv2 input maps include WITNESS_SCRIPT (key 0x05) in addition to standard fields

### Client Commands
| Code | Command | Response Format |
|------|---------|-----------------|
| 0x10 | YIELD | Empty (collect yielded data) |
| 0x40 | GET_PREIMAGE | varint(len) + byte(partial_len) + data. Remainder queued as **single-byte** elements |
| 0x41 | GET_MERKLE_LEAF_PROOF | 32-byte leaf_hash + proof_size + n_in_response + 32*n proof hashes. Remainder queued as **32-byte** elements |
| 0x42 | GET_MERKLE_LEAF_INDEX | 1-byte found + varint(index) |
| 0xA0 | GET_MORE_ELEMENTS | n_elements + element_size + data. All elements must be same size. |

### Wallet Policy Serialization
```
version(0x02) + name_len + name + varint(desc_len) + SHA256(descriptor) + varint(n_keys) + keys_merkle_root
```

### Key Info Format
- **Internal key** (from Ledger): `[fingerprint/84'/coin_type'/0']xpub_or_tpub`
- **External key** (counterparty): `xpub_or_tpub` (no origin info, no raw hex pubkeys)

### PSBTv2 Global Map Keys
| Key | Value |
|-----|-------|
| 0x02 | TX_VERSION (uint32 LE) |
| 0x03 | FALLBACK_LOCKTIME (uint32 LE) |
| 0x04 | INPUT_COUNT (varint) |
| 0x05 | OUTPUT_COUNT (varint) |
| 0xFB | PSBT_GLOBAL_VERSION = 2 (uint32 LE per BIP-370) |

### PSBTv2 Input Map Keys
| Key | Value |
|-----|-------|
| 0x01 | WITNESS_UTXO: value(8 LE) + varint(spk_len) + scriptPubKey |
| 0x05 | WITNESS_SCRIPT: raw witness script bytes (P2WSH only) |
| 0x06+pubkey | BIP32_DERIVATION: fingerprint(4) + path_elements(uint32 LE each) |
| 0x0E | PREVIOUS_TXID (32 bytes, internal byte order) |
| 0x0F | OUTPUT_INDEX (uint32 LE) |
| 0x10 | SEQUENCE (uint32 LE) |

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

## Safety Features (from Mastering Bitcoin)

- **Dust output warning**: Blocks transactions where output < 546 sats
- **Absurd fee warning**: Orange alert when fee rate > 100 sat/vB
- **Fee sniping defense**: nLockTime = currentBlockHeight on standard sends
- **Duplicate key check**: Pool rejects same pubkey used twice
- **Transaction pinning warning**: Warns/blocks when > 5/20 unconfirmed UTXOs
- **HTLC preimage backup**: Auto-saved to keychain, recoverable with "Reveal" button
- **Delete confirmation**: Warns about funded balance before contract deletion
- **Confirmation depth**: Shows "N/6 confirmations" on funded contracts
