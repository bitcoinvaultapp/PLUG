import XCTest
@testable import PLUG

// MARK: - Unit tests for critical Bitcoin components
// Covers BIP32 key derivation, P2WPKH address generation, script building,
// Base58Check encoding, VarInt encoding, and Bech32 encoding.

final class BitcoinTests: XCTestCase {

    // Shared test tpub (BIP84 testnet, derived from known test mnemonic)
    private let testTpub = "tpubDCtKfsNyRhULjZ9XMS4VKKtVcPdVDi8MKUbcSD9MJDyjRu1A2ND5MiipozyyspBT9bg8upEp7a8EAgFxNxXn1d7QkdbL52Ty5jiSLcxPt1P"

    // MARK: - 1. Secp256k1 / BIP32 Key Derivation Tests

    func testParseTpub() {
        let xpub = ExtendedPublicKey.fromBase58(testTpub)
        XCTAssertNotNil(xpub, "Failed to parse valid tpub")
        XCTAssertEqual(xpub!.key.count, 33, "Compressed public key should be 33 bytes")
        XCTAssertEqual(xpub!.chainCode.count, 32, "Chain code should be 32 bytes")
        XCTAssertTrue(xpub!.key[0] == 0x02 || xpub!.key[0] == 0x03, "Key should start with 02 or 03")
    }

    func testInvalidTpubReturnsNil() {
        XCTAssertNil(ExtendedPublicKey.fromBase58("notavalidxpub"))
        XCTAssertNil(ExtendedPublicKey.fromBase58(""))
        // Corrupted checksum (changed last char)
        let corrupted = "tpubDCtKfsNyRhULjZ9XMS4VKKtVcPdVDi8MKUbcSD9MJDyjRu1A2ND5MiipozyyspBT9bg8upEp7a8EAgFxNxXn1d7QkdbL52Ty5jiSLcxPt1Q"
        XCTAssertNil(ExtendedPublicKey.fromBase58(corrupted), "Corrupted checksum should fail")
    }

    func testBIP32DerivationChild00() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        guard let child0 = xpub.deriveChild(index: 0) else {
            XCTFail("Failed to derive /0"); return
        }
        guard let child00 = child0.deriveChild(index: 0) else {
            XCTFail("Failed to derive /0/0"); return
        }

        // Verify it's a valid compressed pubkey (33 bytes, starts with 02 or 03)
        XCTAssertEqual(child00.key.count, 33)
        XCTAssertTrue(child00.key[0] == 0x02 || child00.key[0] == 0x03)
    }

    func testBIP32DerivationChild01() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        guard let child0 = xpub.deriveChild(index: 0) else {
            XCTFail("Failed to derive /0"); return
        }
        guard let child01 = child0.deriveChild(index: 1) else {
            XCTFail("Failed to derive /0/1"); return
        }

        XCTAssertEqual(child01.key.count, 33)
        XCTAssertTrue(child01.key[0] == 0x02 || child01.key[0] == 0x03)
        // Different from /0/0
        guard let child00 = child0.deriveChild(index: 0) else { return }
        XCTAssertNotEqual(child01.key, child00.key, "Different indices should produce different keys")
    }

    func testBIP32DerivationChild02() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        guard let child0 = xpub.deriveChild(index: 0) else {
            XCTFail("Failed to derive /0"); return
        }
        guard let child02 = child0.deriveChild(index: 2) else {
            XCTFail("Failed to derive /0/2"); return
        }

        XCTAssertEqual(child02.key.count, 33)
        XCTAssertTrue(child02.key[0] == 0x02 || child02.key[0] == 0x03)
        // Different from /0/0 and /0/1
        guard let child00 = child0.deriveChild(index: 0) else { return }
        guard let child01 = child0.deriveChild(index: 1) else { return }
        XCTAssertNotEqual(child02.key, child00.key)
        XCTAssertNotEqual(child02.key, child01.key)
    }

    func testBIP32DerivePathEquivalent() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        // derivePath([0, 1]) should equal deriveChild(0).deriveChild(1)
        guard let viaPath = xpub.derivePath([0, 1]) else {
            XCTFail("derivePath failed"); return
        }
        guard let viaManual = xpub.deriveChild(index: 0)?.deriveChild(index: 1) else {
            XCTFail("manual derivation failed"); return
        }
        XCTAssertEqual(viaPath.key, viaManual.key)
        XCTAssertEqual(viaPath.chainCode, viaManual.chainCode)
    }

    func testHardenedDerivationRejected() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        // Hardened index (>= 0x80000000) must return nil for public key derivation
        XCTAssertNil(xpub.deriveChild(index: 0x80000000))
    }

    func testDerivedKeyDepthIncreases() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        let originalDepth = xpub.depth
        guard let child = xpub.deriveChild(index: 0) else {
            XCTFail("derivation failed"); return
        }
        XCTAssertEqual(child.depth, originalDepth + 1)
    }

    // MARK: - 2. Address Generation Tests

    func testP2WPKHAddressIndex0() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        let addrs = AddressDerivation.deriveAddresses(
            xpub: xpub, change: 0, startIndex: 0, count: 2, isTestnet: true
        )
        XCTAssertEqual(addrs.count, 2)
        XCTAssertEqual(addrs[0].address, "tb1qzdr7s2sr0dwmkwx033r4nujzk86u0cy6fmzfjk")
    }

    func testP2WPKHAddressIndex1() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        let addrs = AddressDerivation.deriveAddresses(
            xpub: xpub, change: 0, startIndex: 0, count: 2, isTestnet: true
        )
        XCTAssertEqual(addrs[1].address, "tb1qyvvdvmuylm6ufp6ljvas8rwx8qcl3ksnad49ra")
    }

    func testP2WPKHAddressCount() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        let addrs = AddressDerivation.deriveAddresses(
            xpub: xpub, change: 0, startIndex: 0, count: 20, isTestnet: true
        )
        XCTAssertEqual(addrs.count, 20, "Should derive exactly 20 addresses (gap limit)")
    }

    func testP2WPKHAddressTestnetPrefix() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        let addrs = AddressDerivation.deriveAddresses(
            xpub: xpub, change: 0, startIndex: 0, count: 5, isTestnet: true
        )
        for addr in addrs {
            XCTAssertTrue(addr.address.hasPrefix("tb1q"), "Testnet P2WPKH should start with tb1q, got: \(addr.address)")
        }
    }

    func testSegwitAddressDirectly() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        guard let child00 = xpub.derivePath([0, 0]) else {
            XCTFail("derivation failed"); return
        }
        let address = child00.segwitAddress(isTestnet: true)
        XCTAssertEqual(address, "tb1qzdr7s2sr0dwmkwx033r4nujzk86u0cy6fmzfjk")
    }

    // MARK: - 3. ScriptBuilder Tests

    func testVaultScriptStructure() {
        let pubkey = Data(hex: "0320b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let builder = ScriptBuilder.vaultScript(locktime: 900000, pubkey: pubkey)
        let hex = builder.script.hex

        // Script: <PUSH 33 bytes> <pubkey> OP_CHECKSIGVERIFY <locktime> OP_CHECKLOCKTIMEVERIFY
        XCTAssertTrue(hex.hasPrefix("21"), "Should start with PUSH 33 (0x21)")
        XCTAssertTrue(hex.contains("ad"), "Should contain OP_CHECKSIGVERIFY (0xAD)")
        XCTAssertTrue(hex.hasSuffix("b1"), "Should end with OP_CHECKLOCKTIMEVERIFY (0xB1)")
    }

    func testVaultScriptContainsPubkey() {
        let pubkeyHex = "0320b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8"
        let pubkey = Data(hex: pubkeyHex)!
        let builder = ScriptBuilder.vaultScript(locktime: 900000, pubkey: pubkey)
        let hex = builder.script.hex

        XCTAssertTrue(hex.contains(pubkeyHex), "Script should contain the pubkey")
    }

    func testInheritanceScriptStructure() {
        let owner = Data(hex: "0320b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let heir = Data(hex: "025b813f54de8a89b3968e42d924926fadb15ae8d0cf28cac7363a244b8ee37637")!
        let builder = ScriptBuilder.inheritanceScript(ownerPubkey: owner, heirPubkey: heir, csvBlocks: 52560)
        let hex = builder.script.hex

        // Script: <OWNER> OP_CHECKSIG OP_IFDUP OP_NOTIF <HEIR> OP_CHECKSIGVERIFY <N> OP_CSV OP_ENDIF
        XCTAssertTrue(hex.contains("ac"), "Should contain OP_CHECKSIG (0xAC)")
        XCTAssertTrue(hex.contains("73"), "Should contain OP_IFDUP (0x73)")
        XCTAssertTrue(hex.contains("64"), "Should contain OP_NOTIF (0x64)")
        XCTAssertTrue(hex.contains("ad"), "Should contain OP_CHECKSIGVERIFY (0xAD)")
        XCTAssertTrue(hex.contains("b2"), "Should contain OP_CHECKSEQUENCEVERIFY (0xB2)")
        XCTAssertTrue(hex.hasSuffix("68"), "Should end with OP_ENDIF (0x68)")
    }

    func testMultisigScript2of3() {
        let key1 = Data(hex: "0320b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let key2 = Data(hex: "025b813f54de8a89b3968e42d924926fadb15ae8d0cf28cac7363a244b8ee37637")!
        let key3 = Data(hex: "036708577352d4c6232e8a887376826d63d949f46416c4cf11c7b4905593dc82d3")!

        let builder = ScriptBuilder.multisigScript(m: 2, pubkeys: [key1, key2, key3])
        let hex = builder.script.hex

        // Should start with OP_2 (0x52) for M=2
        XCTAssertTrue(hex.hasPrefix("52"), "Should start with OP_2 for 2-of-3")
        // Should contain OP_3 before OP_CHECKMULTISIG
        XCTAssertTrue(hex.contains("53"), "Should contain OP_3 for N=3")
        // Should end with OP_CHECKMULTISIG (0xAE)
        XCTAssertTrue(hex.hasSuffix("ae"), "Should end with OP_CHECKMULTISIG")
    }

    func testMultisigKeysSortedBIP67() {
        let key1 = Data(hex: "0320b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let key2 = Data(hex: "025b813f54de8a89b3968e42d924926fadb15ae8d0cf28cac7363a244b8ee37637")!
        let key3 = Data(hex: "036708577352d4c6232e8a887376826d63d949f46416c4cf11c7b4905593dc82d3")!

        // Regardless of input order, output should be sorted lexicographically
        let builder1 = ScriptBuilder.multisigScript(m: 2, pubkeys: [key1, key2, key3])
        let builder2 = ScriptBuilder.multisigScript(m: 2, pubkeys: [key3, key1, key2])
        let builder3 = ScriptBuilder.multisigScript(m: 2, pubkeys: [key2, key3, key1])

        XCTAssertEqual(builder1.script, builder2.script, "BIP67: script should be identical regardless of key order")
        XCTAssertEqual(builder2.script, builder3.script, "BIP67: script should be identical regardless of key order")
    }

    func testScriptBuilderPushNumber() {
        // OP_0 for 0
        let b0 = ScriptBuilder()
        b0.pushNumber(0)
        XCTAssertEqual(b0.script, Data([0x00]))

        // OP_1 through OP_16
        let b1 = ScriptBuilder()
        b1.pushNumber(1)
        XCTAssertEqual(b1.script, Data([0x51]))

        let b16 = ScriptBuilder()
        b16.pushNumber(16)
        XCTAssertEqual(b16.script, Data([0x60]))

        // OP_1NEGATE for -1
        let bNeg = ScriptBuilder()
        bNeg.pushNumber(-1)
        XCTAssertEqual(bNeg.script, Data([0x4f]))
    }

    func testP2WSHAddress() {
        let pubkey = Data(hex: "0320b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let builder = ScriptBuilder.vaultScript(locktime: 900000, pubkey: pubkey)
        let address = builder.p2wshAddress(isTestnet: true)
        XCTAssertNotNil(address, "P2WSH address should be generated")
        XCTAssertTrue(address!.hasPrefix("tb1q"), "Testnet P2WSH v0 should start with tb1q")
    }

    // MARK: - 4. Base58Check Tests

    func testBase58RoundTrip() {
        guard let xpub = ExtendedPublicKey.fromBase58(testTpub) else {
            XCTFail("Failed to parse tpub"); return
        }
        let reencoded = xpub.toBase58(isTestnet: true)
        XCTAssertEqual(reencoded, testTpub, "Base58 round-trip should produce identical tpub")
    }

    func testBase58DecodeInvalidChecksum() {
        // Flip a character to invalidate checksum
        let bad = "tpubDCtKfsNyRhULjZ9XMS4VKKtVcPdVDi8MKUbcSD9MJDyjRu1A2ND5MiipozyyspBT9bg8upEp7a8EAgFxNxXn1d7QkdbL52Ty5jiSLcxPt1Q"
        XCTAssertNil(Base58Check.decode(bad), "Invalid checksum should return nil")
    }

    func testBase58DecodeInvalidCharacter() {
        // '0' (zero), 'O', 'I', 'l' are not in Base58 alphabet
        XCTAssertNil(Base58Check.decode("0InvalidBase58"), "Invalid character '0' should return nil")
        XCTAssertNil(Base58Check.decode("OInvalidBase58"), "Invalid character 'O' should return nil")
        XCTAssertNil(Base58Check.decode("IInvalidBase58"), "Invalid character 'I' should return nil")
        XCTAssertNil(Base58Check.decode("lInvalidBase58"), "Invalid character 'l' should return nil")
    }

    func testBase58EncodeDecodeSmallPayload() {
        let payload = Data([0x00, 0x01, 0x02, 0x03])
        let encoded = Base58Check.encode(payload)
        guard let decoded = Base58Check.decode(encoded) else {
            XCTFail("Failed to decode Base58Check encoded string"); return
        }
        XCTAssertEqual(decoded, payload, "Encode/decode round-trip should preserve payload")
    }

    // MARK: - 5. VarInt Tests

    func testVarIntEncodeSingleByte() {
        XCTAssertEqual(VarInt.encode(0), Data([0x00]))
        XCTAssertEqual(VarInt.encode(1), Data([0x01]))
        XCTAssertEqual(VarInt.encode(252), Data([0xFC]))
    }

    func testVarIntEncodeTwoBytes() {
        XCTAssertEqual(VarInt.encode(253), Data([0xFD, 0xFD, 0x00]))
        XCTAssertEqual(VarInt.encode(255), Data([0xFD, 0xFF, 0x00]))
        XCTAssertEqual(VarInt.encode(65535), Data([0xFD, 0xFF, 0xFF]))
    }

    func testVarIntEncodeFourBytes() {
        // 65536 = 0x10000
        XCTAssertEqual(VarInt.encode(65536), Data([0xFE, 0x00, 0x00, 0x01, 0x00]))
    }

    func testVarIntDecodeRoundTrip() {
        let testValues: [UInt64] = [0, 1, 252, 253, 254, 255, 1000, 65535, 65536, 100000]
        for value in testValues {
            let encoded = VarInt.encode(value)
            guard let (decoded, bytesRead) = VarInt.decode(encoded, offset: 0) else {
                XCTFail("Failed to decode VarInt for value \(value)"); continue
            }
            XCTAssertEqual(decoded, value, "VarInt round-trip failed for \(value)")
            XCTAssertEqual(bytesRead, encoded.count, "Bytes read should equal encoded length for \(value)")
        }
    }

    // MARK: - 6. Bech32 Tests

    func testBech32SegwitEncode() {
        let program = Data(hex: "1347e82a037b5dbb38cf8c4759f242b1f5c7e09a")!
        let address = Bech32.segwitEncode(hrp: "tb", version: 0, program: program)
        XCTAssertEqual(address, "tb1qzdr7s2sr0dwmkwx033r4nujzk86u0cy6fmzfjk")
    }

    func testBech32SegwitDecode() {
        guard let result = Bech32.segwitDecode(hrp: "tb", addr: "tb1qzdr7s2sr0dwmkwx033r4nujzk86u0cy6fmzfjk") else {
            XCTFail("Failed to decode bech32 address"); return
        }
        XCTAssertEqual(result.version, 0, "Should be SegWit version 0")
        XCTAssertEqual(result.program.hex, "1347e82a037b5dbb38cf8c4759f242b1f5c7e09a")
    }

    func testBech32RoundTrip() {
        let original = "tb1qzdr7s2sr0dwmkwx033r4nujzk86u0cy6fmzfjk"
        guard let decoded = Bech32.segwitDecode(hrp: "tb", addr: original) else {
            XCTFail("Failed to decode"); return
        }
        let reencoded = Bech32.segwitEncode(hrp: "tb", version: decoded.version, program: decoded.program)
        XCTAssertEqual(reencoded, original, "Bech32 round-trip should produce identical address")
    }

    func testBech32InvalidHrp() {
        let result = Bech32.segwitDecode(hrp: "bc", addr: "tb1qzdr7s2sr0dwmkwx033r4nujzk86u0cy6fmzfjk")
        XCTAssertNil(result, "Decoding with wrong HRP should fail")
    }

    func testBech32MainnetAddress() {
        // Verify mainnet encoding uses bc1 prefix
        let program = Data(hex: "1347e82a037b5dbb38cf8c4759f242b1f5c7e09a")!
        let address = Bech32.segwitEncode(hrp: "bc", version: 0, program: program)
        XCTAssertNotNil(address)
        XCTAssertTrue(address!.hasPrefix("bc1q"), "Mainnet P2WPKH should start with bc1q")
    }

    // MARK: - 7. ScriptNumber Tests

    func testScriptNumberEncode() {
        XCTAssertEqual(ScriptNumber.encode(0), Data())
        XCTAssertEqual(ScriptNumber.encode(1), Data([0x01]))
        XCTAssertEqual(ScriptNumber.encode(127), Data([0x7f]))
        XCTAssertEqual(ScriptNumber.encode(128), Data([0x80, 0x00])) // high bit set, needs extra byte
        XCTAssertEqual(ScriptNumber.encode(-1), Data([0x81]))
    }

    func testScriptNumberRoundTrip() {
        let testValues: [Int64] = [0, 1, -1, 127, 128, -128, 255, 256, -256, 900000, -900000]
        for value in testValues {
            let encoded = ScriptNumber.encode(value)
            let decoded = ScriptNumber.decode(encoded)
            XCTAssertEqual(decoded, value, "ScriptNumber round-trip failed for \(value)")
        }
    }

    // MARK: - 8. Data Hex Extension Tests

    func testDataHexInit() {
        let data = Data(hex: "deadbeef")
        XCTAssertNotNil(data)
        XCTAssertEqual(data!.count, 4)
        XCTAssertEqual(data![0], 0xDE)
        XCTAssertEqual(data![1], 0xAD)
        XCTAssertEqual(data![2], 0xBE)
        XCTAssertEqual(data![3], 0xEF)
    }

    func testDataHexRoundTrip() {
        let original = "0320b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8"
        let data = Data(hex: original)!
        XCTAssertEqual(data.hex, original)
    }

    func testDataHexInvalidInput() {
        XCTAssertNil(Data(hex: "xyz"))
        XCTAssertNil(Data(hex: "0"))  // odd length
    }

    // MARK: - 9. Secp256k1 Low-Level Tests

    func testSecp256k1ParsePublicKey() {
        let pubkeyData = Data(hex: "0320b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let point = Secp256k1.parsePublicKey(pubkeyData)
        XCTAssertNotNil(point, "Valid compressed pubkey should parse")
        XCTAssertFalse(point!.isInfinity)
    }

    func testSecp256k1RejectInvalidKey() {
        // All zeros is not a valid point
        let invalid = Data(repeating: 0, count: 33)
        XCTAssertNil(Secp256k1.parsePublicKey(invalid))
    }

    func testSecp256k1OrderConstant() {
        // secp256k1 order n = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
        let nHex = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
        let nFromHex = UInt256(hex: nHex)
        XCTAssertNotNil(nFromHex)
        XCTAssertEqual(nFromHex!, Secp256k1.n)
    }

    // MARK: - 10. Taproot (P2TR / BIP340/341) Tests

    func testXOnlyKey() {
        let compressed = Data(hex: "0320b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let xOnly = Secp256k1.xOnly(compressed)
        XCTAssertEqual(xOnly.count, 32)
        XCTAssertEqual(xOnly.hex, "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")
    }

    func testLiftXOnly() {
        let xOnly = Data(hex: "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let full = Secp256k1.liftXOnly(xOnly)
        XCTAssertEqual(full.count, 33)
        XCTAssertEqual(full[0], 0x02, "Lifted x-only key should have 0x02 prefix (even Y)")
    }

    func testHasEvenY() {
        let even = Data(hex: "0220b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let odd = Data(hex: "0320b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        XCTAssertTrue(Secp256k1.hasEvenY(even))
        XCTAssertFalse(Secp256k1.hasEvenY(odd))
    }

    func testTweakAdd() {
        let pubkey = Data(hex: "0220b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let tweak = Crypto.sha256(Data("test_tweak".utf8))
        let result = Secp256k1.tweakAdd(pubkey: pubkey, tweak: tweak)
        XCTAssertNotNil(result, "tweakAdd should succeed with valid inputs")
        XCTAssertEqual(result!.key.count, 33)
        XCTAssertNotEqual(result!.key, pubkey, "Tweaked key should differ from original")
    }

    func testTaggedHash() {
        let data = Data("hello".utf8)
        let hash1 = TaprootBuilder.taggedHash(tag: "TapLeaf", data: data)
        let hash2 = TaprootBuilder.taggedHash(tag: "TapBranch", data: data)
        XCTAssertEqual(hash1.count, 32)
        XCTAssertEqual(hash2.count, 32)
        XCTAssertNotEqual(hash1, hash2, "Different tags should produce different hashes")
    }

    func testTaggedHashDeterministic() {
        let data = Data("test".utf8)
        let h1 = TaprootBuilder.taggedHash(tag: "TapTweak", data: data)
        let h2 = TaprootBuilder.taggedHash(tag: "TapTweak", data: data)
        XCTAssertEqual(h1, h2, "Tagged hash should be deterministic")
    }

    func testTapLeafHash() {
        let script = Data(hex: "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8ac")!
        let leafHash = TaprootBuilder.tapLeafHash(script: script)
        XCTAssertEqual(leafHash.count, 32, "TapLeaf hash should be 32 bytes")
    }

    func testTapBranchHashSorting() {
        let a = Crypto.sha256(Data("leaf_a".utf8))
        let b = Crypto.sha256(Data("leaf_b".utf8))
        // Order should not matter — canonical sorting
        let hash1 = TaprootBuilder.tapBranchHash(left: a, right: b)
        let hash2 = TaprootBuilder.tapBranchHash(left: b, right: a)
        XCTAssertEqual(hash1, hash2, "TapBranch should sort children canonically")
    }

    func testComputeMerkleRootSingleLeaf() {
        let script = Data(hex: "51")! // OP_1
        let root = TaprootBuilder.computeMerkleRoot(scripts: [script])
        XCTAssertNotNil(root)
        XCTAssertEqual(root!.count, 32)
        // Single leaf: root == tapLeafHash
        XCTAssertEqual(root!, TaprootBuilder.tapLeafHash(script: script))
    }

    func testComputeMerkleRootTwoLeaves() {
        let s1 = Data(hex: "51")! // OP_1
        let s2 = Data(hex: "52")! // OP_2
        let root = TaprootBuilder.computeMerkleRoot(scripts: [s1, s2])
        XCTAssertNotNil(root)
        let expected = TaprootBuilder.tapBranchHash(
            left: TaprootBuilder.tapLeafHash(script: s1),
            right: TaprootBuilder.tapLeafHash(script: s2)
        )
        XCTAssertEqual(root!, expected)
    }

    func testComputeMerkleRootEmpty() {
        XCTAssertNil(TaprootBuilder.computeMerkleRoot(scripts: []))
    }

    func testTweakPublicKey() {
        let internalKey = Data(hex: "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let tweaked = TaprootBuilder.tweakPublicKey(internalKey: internalKey, merkleRoot: nil)
        XCTAssertNotNil(tweaked, "Key tweaking should succeed")
        XCTAssertEqual(tweaked!.count, 32, "Tweaked key should be 32 bytes (x-only)")
        XCTAssertNotEqual(tweaked!, internalKey, "Tweaked key should differ from internal key")
    }

    func testTweakPublicKeyWithMerkleRoot() {
        let internalKey = Data(hex: "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let script = Data(hex: "51")!
        let merkleRoot = TaprootBuilder.computeMerkleRoot(scripts: [script])

        let tweakedNoScript = TaprootBuilder.tweakPublicKey(internalKey: internalKey, merkleRoot: nil)
        let tweakedWithScript = TaprootBuilder.tweakPublicKey(internalKey: internalKey, merkleRoot: merkleRoot)

        XCTAssertNotNil(tweakedNoScript)
        XCTAssertNotNil(tweakedWithScript)
        XCTAssertNotEqual(tweakedNoScript, tweakedWithScript, "Merkle root should change the tweaked key")
    }

    func testTweakPublicKeyFull() {
        let internalKey = Data(hex: "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let result = TaprootBuilder.tweakPublicKeyFull(internalKey: internalKey, merkleRoot: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.xOnly.count, 32)
        XCTAssertEqual(result!.full.count, 33)
        XCTAssertTrue(result!.parityBit == 0 || result!.parityBit == 1)
    }

    func testP2TRScriptPubKey() {
        let tweakedKey = Data(repeating: 0xAB, count: 32)
        let spk = TaprootBuilder.p2trScriptPubKey(tweakedKey: tweakedKey)
        XCTAssertEqual(spk.count, 34, "P2TR scriptPubKey should be 34 bytes")
        XCTAssertEqual(spk[0], 0x51, "First byte should be OP_1")
        XCTAssertEqual(spk[1], 0x20, "Second byte should be push 32")
        XCTAssertEqual(Data(spk[2...]), tweakedKey)
    }

    func testTaprootAddressGeneration() {
        let internalKey = Data(hex: "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let address = TaprootBuilder.taprootAddress(internalKey: internalKey, isTestnet: true)
        XCTAssertNotNil(address, "P2TR address should be generated")
        XCTAssertTrue(address!.hasPrefix("tb1p"), "Testnet P2TR should start with tb1p")
    }

    func testTaprootAddressMainnet() {
        let internalKey = Data(hex: "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let address = TaprootBuilder.taprootAddress(internalKey: internalKey, isTestnet: false)
        XCTAssertNotNil(address)
        XCTAssertTrue(address!.hasPrefix("bc1p"), "Mainnet P2TR should start with bc1p")
    }

    func testTaprootAddressWithScripts() {
        let internalKey = Data(hex: "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let script = Data(hex: "51")!
        let addrNoScript = TaprootBuilder.taprootAddress(internalKey: internalKey, isTestnet: true)
        let addrWithScript = TaprootBuilder.taprootAddress(internalKey: internalKey, scripts: [script], isTestnet: true)
        XCTAssertNotNil(addrNoScript)
        XCTAssertNotNil(addrWithScript)
        XCTAssertNotEqual(addrNoScript, addrWithScript, "Scripts should change the address")
    }

    func testControlBlock() {
        let internalKey = Data(hex: "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let script = Data(hex: "51")!
        let cb = TaprootBuilder.controlBlock(internalKey: internalKey, scripts: [script], scriptIndex: 0)
        XCTAssertNotNil(cb)
        // Single leaf: control block = 1 byte (version|parity) + 32 bytes (internal key) = 33 bytes
        XCTAssertEqual(cb!.count, 33, "Single-leaf control block should be 33 bytes")
        XCTAssertTrue(cb![0] & 0xFE == TaprootBuilder.tapscriptLeafVersion, "Should contain leaf version")
    }

    func testControlBlockTwoScripts() {
        let internalKey = Data(hex: "20b911c22be58f73e2acb9ca493243aeed6fdb27fe92b31b2d787dd4c9e7c0f8")!
        let s1 = Data(hex: "51")!
        let s2 = Data(hex: "52")!
        let cb = TaprootBuilder.controlBlock(internalKey: internalKey, scripts: [s1, s2], scriptIndex: 0)
        XCTAssertNotNil(cb)
        // Two leaves: 1 + 32 + 32 (one sibling hash) = 65 bytes
        XCTAssertEqual(cb!.count, 65, "Two-leaf control block should be 65 bytes")
    }

    func testKeyPathWitness() {
        let sig = Data(repeating: 0xAB, count: 64)
        let witness = TaprootBuilder.keyPathWitness(signature: sig)
        XCTAssertEqual(witness.count, 1)
        XCTAssertEqual(witness[0], sig)
    }

    func testScriptPathWitness() {
        let sig = Data(repeating: 0xAB, count: 64)
        let script = Data(hex: "51")!
        let cb = Data(repeating: 0xCD, count: 33)
        let witness = TaprootBuilder.scriptPathWitness(stack: [sig], script: script, controlBlock: cb)
        XCTAssertEqual(witness.count, 3) // sig, script, controlBlock
        XCTAssertEqual(witness[0], sig)
        XCTAssertEqual(witness[1], script)
        XCTAssertEqual(witness[2], cb)
    }

    // MARK: - CoinSelection Tests

    func testCoinSelectionLargestFirst() {
        let utxos = [
            UTXO(txid: "aa", vout: 0, value: 1000, address: "addr1", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
            UTXO(txid: "bb", vout: 0, value: 5000, address: "addr2", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
            UTXO(txid: "cc", vout: 0, value: 3000, address: "addr3", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
        ]
        let result = CoinSelection.select(from: utxos, target: 4000, feeRate: 1.0, strategy: .largestFirst)
        XCTAssertNotNil(result, "Should find selection for 4000 sats")
        XCTAssertEqual(result!.selectedUTXOs.first?.value, 5000, "Largest UTXO should be selected first")
    }

    func testCoinSelectionSmallestFirst() {
        let utxos = [
            UTXO(txid: "aa", vout: 0, value: 1000, address: "addr1", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
            UTXO(txid: "bb", vout: 0, value: 5000, address: "addr2", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
            UTXO(txid: "cc", vout: 0, value: 3000, address: "addr3", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
        ]
        let result = CoinSelection.select(from: utxos, target: 2000, feeRate: 1.0, strategy: .smallestFirst)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.selectedUTXOs.first?.value, 1000, "Smallest UTXO should be selected first")
    }

    func testCoinSelectionInsufficientFunds() {
        let utxos = [
            UTXO(txid: "aa", vout: 0, value: 500, address: "addr1", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
        ]
        let result = CoinSelection.select(from: utxos, target: 10000, feeRate: 1.0)
        XCTAssertNil(result, "Should fail with insufficient funds")
    }

    func testCoinSelectionDustFiltered() {
        let utxos = [
            UTXO(txid: "aa", vout: 0, value: 100, address: "addr1", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
            UTXO(txid: "bb", vout: 0, value: 5000, address: "addr2", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
        ]
        let result = CoinSelection.select(from: utxos, target: 1000, feeRate: 1.0)
        XCTAssertNotNil(result)
        // Dust UTXO (100 sats < 546) should be filtered out
        XCTAssertFalse(result!.selectedUTXOs.contains { $0.value == 100 })
    }

    func testCoinSelectionFrozenFiltered() {
        let utxos = [
            UTXO(txid: "aa", vout: 0, value: 5000, address: "addr1", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
            UTXO(txid: "bb", vout: 0, value: 3000, address: "addr2", scriptPubKey: "", status: .init(confirmed: true, blockHeight: 1, blockHash: nil)),
        ]
        let result = CoinSelection.select(from: utxos, target: 2000, feeRate: 1.0, frozenOutpoints: Set(["aa:0"]))
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.selectedUTXOs.contains { $0.txid == "aa" }, "Frozen UTXO should be excluded")
    }

    // MARK: - Fee Estimation Tests

    func testFeeEstimationP2WPKH() {
        let fee = CoinSelection.estimateFee(inputCount: 1, outputCount: 2, feeRate: 10.0)
        // 11 overhead + 68 input + 62 outputs = 141 vbytes * 10 = 1410
        XCTAssertEqual(fee, 1410)
    }

    func testFeeEstimationP2WSH() {
        let fee = CoinSelection.estimateP2WSHFee(inputCount: 1, outputCount: 1, witnessSize: 100, feeRate: 5.0)
        // P2WSH input: 41 + (100+3)/4 = 41 + 25 = 66 vbytes
        // Total: 11 + 66 + 31 = 108 vbytes * 5 = 540
        XCTAssertEqual(fee, 540)
    }

    func testFeeEstimationZeroRate() {
        let fee = CoinSelection.estimateFee(inputCount: 1, outputCount: 1, feeRate: 0)
        XCTAssertEqual(fee, 0)
    }

    // MARK: - Dust Threshold Tests

    func testDustThresholdConstant() {
        XCTAssertEqual(CoinSelection.dustThreshold, 546)
        XCTAssertEqual(SpendManager.dustThreshold, 546)
    }

    // MARK: - TxID Validation Tests

    func testValidTxid() {
        let valid = String(repeating: "a", count: 64)
        XCTAssertTrue(valid.count == 64 && valid.allSatisfy(\.isHexDigit))
    }

    func testInvalidTxidTooShort() {
        let short = "abc123"
        XCTAssertFalse(short.count == 64)
    }

    func testInvalidTxidNonHex() {
        let invalid = String(repeating: "g", count: 64)
        XCTAssertFalse(invalid.allSatisfy(\.isHexDigit))
    }

    // MARK: - BalanceUnit Format Tests

    func testFormatBTC() {
        let result = BalanceUnit.format(100_000_000, btcPrice: 0)
        XCTAssertEqual(result, "1.00000000 BTC")
    }

    func testFormatSats() {
        let result = BalanceUnit.formatSats(196732)
        XCTAssertTrue(result.contains("196"), "Should contain the number")
        XCTAssertTrue(result.contains("732"), "Should contain the number")
    }

    func testFormatSplitBTC() {
        let (value, unit) = BalanceUnit.formatSplit(50_000_000)
        XCTAssertEqual(value, "0.50000000")
        XCTAssertEqual(unit, "BTC")
    }

    // MARK: - Sequence Number Tests

    func testSequenceRBF() {
        XCTAssertEqual(SpendManager.seqRBF, 0xFFFFFFFD)
    }

    func testSequenceLocktime() {
        XCTAssertEqual(SpendManager.seqLocktime, 0xFFFFFFFE)
    }

    // MARK: - PSBT Builder Tests

    func testPSBTMagicBytes() {
        let magic = PSBTBuilder.magic
        XCTAssertEqual(magic, Data([0x70, 0x73, 0x62, 0x74, 0xFF]))
    }

    func testBuildEmptyPSBT() {
        let input = PSBTBuilder.TxInput(
            txid: Data(count: 32), vout: 0, sequence: 0xFFFFFFFF,
            witnessUtxo: PSBTBuilder.TxOutput(value: 1000, scriptPubKey: Data([0x00, 0x14] + [UInt8](repeating: 0, count: 20)))
        )
        let output = PSBTBuilder.TxOutput(value: 900, scriptPubKey: Data([0x00, 0x14] + [UInt8](repeating: 0, count: 20)))
        let psbt = PSBTBuilder.buildPSBT(inputs: [input], outputs: [output])
        XCTAssertTrue(psbt.starts(with: PSBTBuilder.magic), "PSBT should start with magic bytes")
    }

    func testParsePSBTRoundTrip() {
        let input = PSBTBuilder.TxInput(
            txid: Data(count: 32), vout: 0, sequence: 0xFFFFFFFD,
            witnessUtxo: PSBTBuilder.TxOutput(value: 5000, scriptPubKey: Data([0x00, 0x14] + [UInt8](repeating: 0xAB, count: 20)))
        )
        let output = PSBTBuilder.TxOutput(value: 4500, scriptPubKey: Data([0x00, 0x14] + [UInt8](repeating: 0xCD, count: 20)))
        let psbt = PSBTBuilder.buildPSBT(inputs: [input], outputs: [output], locktime: 890000)
        let parsed = PSBTBuilder.parsePSBT(psbt)
        XCTAssertNotNil(parsed, "Should parse valid PSBT")
        XCTAssertNotNil(parsed?.unsignedTx, "Should have unsigned tx")
    }

    // MARK: - WalletAddress Cache Validation Tests

    func testWalletAddressCacheValidP2WPKH() {
        let addr = WalletAddress(index: 0, address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", publicKey: "00", isChange: false)
        XCTAssertTrue(addr.address.count < 55, "P2WPKH should be < 55 chars")
    }

    func testWalletAddressCacheInvalidP2WSH() {
        let addr = WalletAddress(index: 0, address: "bc1q" + String(repeating: "a", count: 58), publicKey: "00", isChange: false)
        XCTAssertTrue(addr.address.count >= 55, "P2WSH addresses are >= 55 chars — cache should reject")
    }

    func testWalletAddressType() {
        let segwit = WalletAddress(index: 0, address: "bc1q...", publicKey: "00", isChange: false, addressType: .p2wpkh)
        let taproot = WalletAddress(index: 0, address: "bc1p...", publicKey: "00", isChange: false, addressType: .p2tr)
        XCTAssertEqual(segwit.addressType, .p2wpkh)
        XCTAssertEqual(taproot.addressType, .p2tr)
    }

    // MARK: - TxID Byte Order Tests

    func testTxidToInternalOrder() {
        let txid = "0102030405060708091011121314151617181920212223242526272829303132"
        let reversed = SpendManager.txidToInternalOrder(txid)
        XCTAssertEqual(reversed.count, 32)
        // Internal order is reversed
        XCTAssertEqual(reversed[0], 0x32)
        XCTAssertEqual(reversed[31], 0x01)
    }
}
