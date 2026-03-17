import Foundation

// MARK: - Miniscript Policy Compiler
// Parses simplified Miniscript policy language and compiles to Bitcoin Script (P2WSH)
// Supports: pk, older, after, and_v, or_d, thresh, multi

struct Miniscript {

    // MARK: - Policy AST

    indirect enum Policy {
        case pk(Data)                       // pk(<pubkey>)
        case after(Int64)                   // after(<blockheight>) - absolute CLTV
        case older(Int64)                   // older(<blocks>) - relative CSV
        case andV(Policy, Policy)           // and_v(X, Y)
        case orD(Policy, Policy)            // or_d(X, Y) - X preferred, Y fallback
        case thresh(Int, [Policy])          // thresh(k, X1, X2, ...) - k-of-n
        case multi(Int, [Data])             // multi(k, pk1, pk2, ...) - multisig shorthand
    }

    // MARK: - Parse policy string

    /// Parse a Miniscript policy string into AST
    /// Example: "and_v(pk(02ab...),after(800000))"
    static func parse(_ input: String) -> Policy? {
        var chars = Array(input.trimmingCharacters(in: .whitespacesAndNewlines))
        var idx = 0
        return parsePolicy(&chars, &idx)
    }

    private static func parsePolicy(_ chars: inout [Character], _ idx: inout Int) -> Policy? {
        skipWhitespace(&chars, &idx)
        guard idx < chars.count else { return nil }

        let token = readToken(&chars, &idx)

        switch token {
        case "pk":
            guard consume("(", &chars, &idx) else { return nil }
            let arg = readUntil(")", &chars, &idx)
            guard consume(")", &chars, &idx) else { return nil }
            guard let pubkey = Data(hex: arg), pubkey.count == 33 else { return nil }
            return .pk(pubkey)

        case "after":
            guard consume("(", &chars, &idx) else { return nil }
            let arg = readUntil(")", &chars, &idx)
            guard consume(")", &chars, &idx) else { return nil }
            guard let blocks = Int64(arg) else { return nil }
            return .after(blocks)

        case "older":
            guard consume("(", &chars, &idx) else { return nil }
            let arg = readUntil(")", &chars, &idx)
            guard consume(")", &chars, &idx) else { return nil }
            guard let blocks = Int64(arg) else { return nil }
            return .older(blocks)

        case "and_v":
            guard consume("(", &chars, &idx) else { return nil }
            guard let left = parsePolicy(&chars, &idx) else { return nil }
            guard consume(",", &chars, &idx) else { return nil }
            guard let right = parsePolicy(&chars, &idx) else { return nil }
            guard consume(")", &chars, &idx) else { return nil }
            return .andV(left, right)

        case "or_d":
            guard consume("(", &chars, &idx) else { return nil }
            guard let left = parsePolicy(&chars, &idx) else { return nil }
            guard consume(",", &chars, &idx) else { return nil }
            guard let right = parsePolicy(&chars, &idx) else { return nil }
            guard consume(")", &chars, &idx) else { return nil }
            return .orD(left, right)

        case "thresh":
            guard consume("(", &chars, &idx) else { return nil }
            let kStr = readUntil(",", &chars, &idx)
            guard let k = Int(kStr) else { return nil }
            var policies: [Policy] = []
            while consume(",", &chars, &idx) {
                guard let p = parsePolicy(&chars, &idx) else { return nil }
                policies.append(p)
            }
            guard consume(")", &chars, &idx) else { return nil }
            return .thresh(k, policies)

        case "multi":
            guard consume("(", &chars, &idx) else { return nil }
            let kStr = readUntil(",", &chars, &idx)
            guard let k = Int(kStr) else { return nil }
            var keys: [Data] = []
            while consume(",", &chars, &idx) {
                skipWhitespace(&chars, &idx)
                let keyHex = readUntil(",)", &chars, &idx)
                guard let key = Data(hex: keyHex), key.count == 33 else { return nil }
                keys.append(key)
            }
            guard consume(")", &chars, &idx) else { return nil }
            return .multi(k, keys)

        default:
            return nil
        }
    }

    // MARK: - Compile to Bitcoin Script

    /// Compile a policy AST to a Bitcoin Script
    static func compile(_ policy: Policy) -> ScriptBuilder {
        let builder = ScriptBuilder()
        compileInto(builder, policy)
        return builder
    }

    private static func compileInto(_ b: ScriptBuilder, _ policy: Policy) {
        switch policy {
        case .pk(let pubkey):
            // <pubkey> OP_CHECKSIG
            b.pushData(pubkey)
            b.addOp(.op_checksig)

        case .after(let blocks):
            // <blocks> OP_CHECKLOCKTIMEVERIFY OP_DROP OP_1
            b.pushNumber(blocks)
            b.addOp(.op_checklocktimeverify)
            b.addOp(.op_drop)
            b.addOp(.op_1)

        case .older(let blocks):
            // <blocks> OP_CHECKSEQUENCEVERIFY OP_DROP OP_1
            b.pushNumber(blocks)
            b.addOp(.op_checksequenceverify)
            b.addOp(.op_drop)
            b.addOp(.op_1)

        case .andV(let left, let right):
            // Compile left (must verify), then compile right
            compileVerify(b, left)
            compileInto(b, right)

        case .orD(let preferred, let fallback):
            // OP_IF <preferred> OP_ELSE <fallback> OP_ENDIF
            compileInto(b, preferred)
            b.addOp(.op_notif)
            compileInto(b, fallback)
            b.addOp(.op_endif)

        case .thresh(let k, let policies):
            // Compile each policy, sum results, check >= k
            guard !policies.isEmpty else { return }
            compileInto(b, policies[0])
            for i in 1..<policies.count {
                b.addOp(.op_swap)
                compileInto(b, policies[i])
                b.addOp(.op_add)
            }
            b.pushNumber(Int64(k))
            b.addOp(.op_equal)

        case .multi(let k, let keys):
            // Standard multisig: OP_M <keys...> OP_N OP_CHECKMULTISIG
            let sorted = keys.sorted { (a: Data, b: Data) -> Bool in a.hex < b.hex }
            b.pushNumber(Int64(k))
            for key in sorted {
                b.pushData(key)
            }
            b.pushNumber(Int64(sorted.count))
            b.addOp(.op_checkmultisig)
        }
    }

    /// Compile a policy in "verify" mode (must leave nothing or true on stack)
    private static func compileVerify(_ b: ScriptBuilder, _ policy: Policy) {
        switch policy {
        case .pk(let pubkey):
            b.pushData(pubkey)
            b.addOp(.op_checksigverify)
        case .after(let blocks):
            b.pushNumber(blocks)
            b.addOp(.op_checklocktimeverify)
            b.addOp(.op_drop)
        case .older(let blocks):
            b.pushNumber(blocks)
            b.addOp(.op_checksequenceverify)
            b.addOp(.op_drop)
        default:
            compileInto(b, policy)
            b.addOp(.op_verify)
        }
    }

    // MARK: - Generate P2WSH address from policy

    static func policyToAddress(_ policyString: String, isTestnet: Bool) -> (address: String, script: Data)? {
        guard let policy = parse(policyString) else { return nil }
        let builder = compile(policy)
        guard let address = builder.p2wshAddress(isTestnet: isTestnet) else { return nil }
        return (address, builder.script)
    }

    // MARK: - Policy description

    static func describe(_ policy: Policy) -> String {
        switch policy {
        case .pk(let key):
            return "pk(\(key.hex.prefix(8))...)"
        case .after(let b):
            return "after(\(b))"
        case .older(let b):
            return "older(\(b))"
        case .andV(let l, let r):
            return "and_v(\(describe(l)),\(describe(r)))"
        case .orD(let l, let r):
            return "or_d(\(describe(l)),\(describe(r)))"
        case .thresh(let k, let ps):
            return "thresh(\(k),\(ps.map { describe($0) }.joined(separator: ",")))"
        case .multi(let k, let keys):
            return "multi(\(k),\(keys.map { $0.hex.prefix(8) + "..." }.joined(separator: ",")))"
        }
    }

    // MARK: - Tokenizer helpers

    private static func skipWhitespace(_ chars: inout [Character], _ idx: inout Int) {
        while idx < chars.count && chars[idx].isWhitespace { idx += 1 }
    }

    private static func readToken(_ chars: inout [Character], _ idx: inout Int) -> String {
        skipWhitespace(&chars, &idx)
        var token = ""
        while idx < chars.count && chars[idx].isLetter || (idx < chars.count && chars[idx] == "_") {
            token.append(chars[idx])
            idx += 1
        }
        return token
    }

    private static func consume(_ char: Character, _ chars: inout [Character], _ idx: inout Int) -> Bool {
        skipWhitespace(&chars, &idx)
        guard idx < chars.count && chars[idx] == char else { return false }
        idx += 1
        return true
    }

    private static func readUntil(_ terminators: String, _ chars: inout [Character], _ idx: inout Int) -> String {
        skipWhitespace(&chars, &idx)
        var result = ""
        let termSet = Set(terminators)
        while idx < chars.count && !termSet.contains(chars[idx]) {
            result.append(chars[idx])
            idx += 1
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
