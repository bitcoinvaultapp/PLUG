import Foundation

// MARK: - Bitcoin Script Builder
// Constructs raw Bitcoin scripts with opcodes for CLTV, CSV, multisig, etc.

enum OpCode: UInt8 {
    case op_0 = 0x00
    case op_pushdata1 = 0x4c
    case op_pushdata2 = 0x4d
    case op_pushdata4 = 0x4e
    case op_1negate = 0x4f
    case op_1 = 0x51
    case op_2 = 0x52
    case op_3 = 0x53
    case op_4 = 0x54
    case op_5 = 0x55
    case op_6 = 0x56
    case op_7 = 0x57
    case op_8 = 0x58
    case op_9 = 0x59
    case op_10 = 0x5a
    case op_11 = 0x5b
    case op_12 = 0x5c
    case op_13 = 0x5d
    case op_14 = 0x5e
    case op_15 = 0x5f
    case op_16 = 0x60

    case op_nop = 0x61
    case op_if = 0x63
    case op_notif = 0x64
    case op_ifdup = 0x73
    case op_else = 0x67
    case op_endif = 0x68
    case op_verify = 0x69
    case op_return = 0x6a

    case op_toaltstack = 0x6b
    case op_fromaltstack = 0x6c
    case op_drop = 0x75
    case op_dup = 0x76
    case op_nip = 0x77
    case op_over = 0x78
    case op_pick = 0x79
    case op_roll = 0x7a
    case op_rot = 0x7b
    case op_swap = 0x7c
    case op_tuck = 0x7d
    case op_2drop = 0x6d
    case op_2dup = 0x6e
    case op_3dup = 0x6f
    case op_2over = 0x70
    case op_2rot = 0x71
    case op_2swap = 0x72

    case op_size = 0x82

    case op_equal = 0x87
    case op_equalverify = 0x88

    case op_1add = 0x8b
    case op_1sub = 0x8c
    case op_negate = 0x8f
    case op_abs = 0x90
    case op_not = 0x91
    case op_0notequal = 0x92
    case op_add = 0x93
    case op_sub = 0x94
    case op_booland = 0x9a
    case op_boolor = 0x9b
    case op_numequal = 0x9c
    case op_numequalverify = 0x9d
    case op_numnotequal = 0x9e
    case op_lessthan = 0x9f
    case op_greaterthan = 0xa0
    case op_lessthanorequal = 0xa1
    case op_greaterthanorequal = 0xa2
    case op_min = 0xa3
    case op_max = 0xa4
    case op_within = 0xa5

    case op_ripemd160 = 0xa6
    case op_sha1 = 0xa7
    case op_sha256 = 0xa8
    case op_hash160 = 0xa9
    case op_hash256 = 0xaa

    case op_checksig = 0xac
    case op_checksigverify = 0xad
    case op_checkmultisig = 0xae
    case op_checkmultisigverify = 0xaf

    case op_checklocktimeverify = 0xb1 // CLTV - BIP65
    case op_checksequenceverify = 0xb2 // CSV - BIP112

    var name: String {
        switch self {
        case .op_0: return "OP_0"
        case .op_pushdata1: return "OP_PUSHDATA1"
        case .op_pushdata2: return "OP_PUSHDATA2"
        case .op_pushdata4: return "OP_PUSHDATA4"
        case .op_1negate: return "OP_1NEGATE"
        case .op_1: return "OP_1"
        case .op_2: return "OP_2"
        case .op_3: return "OP_3"
        case .op_4: return "OP_4"
        case .op_5: return "OP_5"
        case .op_6: return "OP_6"
        case .op_7: return "OP_7"
        case .op_8: return "OP_8"
        case .op_9: return "OP_9"
        case .op_10: return "OP_10"
        case .op_11: return "OP_11"
        case .op_12: return "OP_12"
        case .op_13: return "OP_13"
        case .op_14: return "OP_14"
        case .op_15: return "OP_15"
        case .op_16: return "OP_16"
        case .op_nop: return "OP_NOP"
        case .op_if: return "OP_IF"
        case .op_notif: return "OP_NOTIF"
        case .op_ifdup: return "OP_IFDUP"
        case .op_else: return "OP_ELSE"
        case .op_endif: return "OP_ENDIF"
        case .op_verify: return "OP_VERIFY"
        case .op_return: return "OP_RETURN"
        case .op_toaltstack: return "OP_TOALTSTACK"
        case .op_fromaltstack: return "OP_FROMALTSTACK"
        case .op_drop: return "OP_DROP"
        case .op_dup: return "OP_DUP"
        case .op_nip: return "OP_NIP"
        case .op_over: return "OP_OVER"
        case .op_pick: return "OP_PICK"
        case .op_roll: return "OP_ROLL"
        case .op_rot: return "OP_ROT"
        case .op_swap: return "OP_SWAP"
        case .op_tuck: return "OP_TUCK"
        case .op_2drop: return "OP_2DROP"
        case .op_2dup: return "OP_2DUP"
        case .op_3dup: return "OP_3DUP"
        case .op_2over: return "OP_2OVER"
        case .op_2rot: return "OP_2ROT"
        case .op_2swap: return "OP_2SWAP"
        case .op_size: return "OP_SIZE"
        case .op_equal: return "OP_EQUAL"
        case .op_equalverify: return "OP_EQUALVERIFY"
        case .op_1add: return "OP_1ADD"
        case .op_1sub: return "OP_1SUB"
        case .op_negate: return "OP_NEGATE"
        case .op_abs: return "OP_ABS"
        case .op_not: return "OP_NOT"
        case .op_0notequal: return "OP_0NOTEQUAL"
        case .op_add: return "OP_ADD"
        case .op_sub: return "OP_SUB"
        case .op_booland: return "OP_BOOLAND"
        case .op_boolor: return "OP_BOOLOR"
        case .op_numequal: return "OP_NUMEQUAL"
        case .op_numequalverify: return "OP_NUMEQUALVERIFY"
        case .op_numnotequal: return "OP_NUMNOTEQUAL"
        case .op_lessthan: return "OP_LESSTHAN"
        case .op_greaterthan: return "OP_GREATERTHAN"
        case .op_lessthanorequal: return "OP_LESSTHANOREQUAL"
        case .op_greaterthanorequal: return "OP_GREATERTHANOREQUAL"
        case .op_min: return "OP_MIN"
        case .op_max: return "OP_MAX"
        case .op_within: return "OP_WITHIN"
        case .op_ripemd160: return "OP_RIPEMD160"
        case .op_sha1: return "OP_SHA1"
        case .op_sha256: return "OP_SHA256"
        case .op_hash160: return "OP_HASH160"
        case .op_hash256: return "OP_HASH256"
        case .op_checksig: return "OP_CHECKSIG"
        case .op_checksigverify: return "OP_CHECKSIGVERIFY"
        case .op_checkmultisig: return "OP_CHECKMULTISIG"
        case .op_checkmultisigverify: return "OP_CHECKMULTISIGVERIFY"
        case .op_checklocktimeverify: return "OP_CHECKLOCKTIMEVERIFY"
        case .op_checksequenceverify: return "OP_CHECKSEQUENCEVERIFY"
        default: return "OP_UNKNOWN(\(rawValue))"
        }
    }

    /// Parse opcode from name string
    static func fromName(_ name: String) -> OpCode? {
        let upper = name.uppercased()
        for i: UInt8 in 0...0xb2 {
            if let op = OpCode(rawValue: i), op.name == upper {
                return op
            }
        }
        // Aliases
        if upper == "OP_CLTV" { return .op_checklocktimeverify }
        if upper == "OP_CSV" { return .op_checksequenceverify }
        return nil
    }
}

// MARK: - Script number encoding (Bitcoin-specific)

enum ScriptNumber {
    /// Encode an integer as a Bitcoin script number (minimal encoding)
    static func encode(_ value: Int64) -> Data {
        if value == 0 { return Data() }

        var result = Data()
        var absValue = value < 0 ? -value : value

        while absValue > 0 {
            result.append(UInt8(absValue & 0xFF))
            absValue >>= 8
        }

        // If the most significant byte has its high bit set, add an extra byte
        if result.last! & 0x80 != 0 {
            result.append(value < 0 ? 0x80 : 0x00)
        } else if value < 0 {
            result[result.count - 1] |= 0x80
        }

        return result
    }

    /// Decode a Bitcoin script number
    static func decode(_ data: Data) -> Int64 {
        guard !data.isEmpty else { return 0 }

        var result: Int64 = 0
        for i in 0..<data.count {
            result |= Int64(data[i]) << (i * 8)
        }

        // Check sign bit
        if data.last! & 0x80 != 0 {
            result &= ~(Int64(0x80) << ((data.count - 1) * 8))
            result = -result
        }

        return result
    }
}

// MARK: - Script builder

class ScriptBuilder {
    private(set) var data = Data()

    @discardableResult
    func addOp(_ op: OpCode) -> ScriptBuilder {
        data.append(op.rawValue)
        return self
    }

    @discardableResult
    func pushData(_ bytes: Data) -> ScriptBuilder {
        if bytes.count == 0 {
            data.append(OpCode.op_0.rawValue)
        } else if bytes.count <= 75 {
            data.append(UInt8(bytes.count))
            data.append(bytes)
        } else if bytes.count <= 255 {
            data.append(OpCode.op_pushdata1.rawValue)
            data.append(UInt8(bytes.count))
            data.append(bytes)
        } else if bytes.count <= 65535 {
            data.append(OpCode.op_pushdata2.rawValue)
            var len = UInt16(bytes.count).littleEndian
            data.append(Data(bytes: &len, count: 2))
            data.append(bytes)
        } else {
            data.append(OpCode.op_pushdata4.rawValue)
            var len = UInt32(bytes.count).littleEndian
            data.append(Data(bytes: &len, count: 4))
            data.append(bytes)
        }
        return self
    }

    @discardableResult
    func pushNumber(_ value: Int64) -> ScriptBuilder {
        if value == -1 {
            data.append(OpCode.op_1negate.rawValue)
        } else if value == 0 {
            data.append(OpCode.op_0.rawValue)
        } else if value >= 1 && value <= 16 {
            data.append(OpCode.op_1.rawValue + UInt8(value - 1))
        } else {
            pushData(ScriptNumber.encode(value))
        }
        return self
    }

    var script: Data { data }

    /// P2WSH witness program = SHA256(script)
    var witnessScriptHash: Data {
        Crypto.sha256(data)
    }

    /// P2WSH address
    func p2wshAddress(isTestnet: Bool) -> String? {
        let hash = witnessScriptHash
        let hrp = isTestnet ? "tb" : "bc"
        return Bech32.segwitEncode(hrp: hrp, version: 0, program: hash)
    }

    /// Generate descriptor string
    func descriptor(isTestnet: Bool) -> String {
        return "wsh(\(data.hex))"
    }
}

// MARK: - Predefined script templates

extension ScriptBuilder {

    /// Vault: CLTV time-lock vault
    /// Miniscript: and_v(v:pk(KEY), after(N))
    /// Script: <KEY> OP_CHECKSIGVERIFY <N> OP_CHECKLOCKTIMEVERIFY
    /// This format matches the Ledger's miniscript compiler output exactly.
    static func vaultScript(locktime: Int64, pubkey: Data) -> ScriptBuilder {
        ScriptBuilder()
            .pushData(pubkey)
            .addOp(.op_checksigverify)
            .pushNumber(locktime)
            .addOp(.op_checklocktimeverify)
    }

    /// Inheritance: CSV timelock with owner priority
    /// Miniscript: or_d(pk(@0),and_v(v:pk(@1),older(N)))
    /// Script: <OWNER> OP_CHECKSIG OP_IFDUP OP_NOTIF <HEIR> OP_CHECKSIGVERIFY <N> OP_CSV OP_ENDIF
    /// This format matches the Ledger's miniscript compiler output exactly.
    static func inheritanceScript(ownerPubkey: Data, heirPubkey: Data, csvBlocks: Int64) -> ScriptBuilder {
        ScriptBuilder()
            .pushData(ownerPubkey)
            .addOp(.op_checksig)
            .addOp(.op_ifdup)
            .addOp(.op_notif)
            .pushData(heirPubkey)
            .addOp(.op_checksigverify)
            .pushNumber(csvBlocks)
            .addOp(.op_checksequenceverify)
            .addOp(.op_endif)
    }

    /// Pool: M-of-N multisig (BIP67 sorted keys)
    /// OP_0 <M> <pubkey1> ... <pubkeyN> <N> OP_CHECKMULTISIG
    static func multisigScript(m: Int, pubkeys: [Data]) -> ScriptBuilder {
        // BIP67: sort public keys lexicographically
        let sorted = pubkeys.sorted { (a: Data, b: Data) -> Bool in a.hex < b.hex }

        let builder = ScriptBuilder()
        builder.pushNumber(Int64(m))
        for key in sorted {
            builder.pushData(key)
        }
        builder.pushNumber(Int64(sorted.count))
        builder.addOp(.op_checkmultisig)
        return builder
    }
}
