import Foundation

// MARK: - Bitcoin Script Interpreter (~40 opcodes)
// Interactive stack machine with execution log

@MainActor
final class ScriptVM: ObservableObject {

    @Published var scriptText: String = ""
    @Published var stack: [Data] = []
    @Published var altStack: [Data] = []
    @Published var log: [String] = []
    @Published var error: String?
    @Published var isValid: Bool?

    // MARK: - Execute

    func execute() {
        stack.removeAll()
        altStack.removeAll()
        log.removeAll()
        error = nil
        isValid = nil

        let tokens = tokenize(scriptText)

        for token in tokens {
            do {
                try executeToken(token)
            } catch let err {
                error = err.localizedDescription
                log.append("ERROR: \(err.localizedDescription)")
                isValid = false
                return
            }
        }

        // Script is valid if stack is non-empty and top is truthy
        if let top = stack.last {
            isValid = !top.isEmpty && top != Data([0x00])
            log.append(isValid! ? "VALID" : "INVALID (top of stack is false)")
        } else {
            isValid = false
            log.append("INVALID (empty stack)")
        }
    }

    func reset() {
        scriptText = ""
        stack.removeAll()
        altStack.removeAll()
        log.removeAll()
        error = nil
        isValid = nil
    }

    // MARK: - Tokenizer

    private func tokenize(_ script: String) -> [String] {
        script
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Token execution

    private func executeToken(_ token: String) throws {
        // Check if it's an opcode
        if let op = OpCode.fromName(token) {
            log.append("  \(op.name)")
            try executeOpcode(op)
            return
        }

        // Check if it's a hex data push
        if token.hasPrefix("0x") || token.hasPrefix("0X") {
            let hexStr = String(token.dropFirst(2))
            if let data = Data(hex: hexStr) {
                stack.append(data)
                log.append("  PUSH \(data.hex)")
                return
            }
        }

        // Try as decimal number
        if let num = Int64(token) {
            let encoded = ScriptNumber.encode(num)
            stack.append(encoded)
            log.append("  PUSH \(num)")
            return
        }

        throw ScriptError.unknownToken(token)
    }

    // MARK: - Opcode execution

    private func executeOpcode(_ op: OpCode) throws {
        switch op {
        // Constants
        case .op_0:
            stack.append(Data())
        case .op_1negate:
            stack.append(ScriptNumber.encode(-1))
        case .op_1, .op_2, .op_3, .op_4, .op_5, .op_6, .op_7, .op_8,
             .op_9, .op_10, .op_11, .op_12, .op_13, .op_14, .op_15, .op_16:
            let n = Int64(op.rawValue) - Int64(OpCode.op_1.rawValue) + 1
            stack.append(ScriptNumber.encode(n))

        // Stack ops
        case .op_dup:
            guard let top = stack.last else { throw ScriptError.stackUnderflow }
            stack.append(top)
        case .op_drop:
            guard !stack.isEmpty else { throw ScriptError.stackUnderflow }
            stack.removeLast()
        case .op_2drop:
            guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
            stack.removeLast(2)
        case .op_2dup:
            guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
            stack.append(contentsOf: stack.suffix(2))
        case .op_nip:
            guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
            stack.remove(at: stack.count - 2)
        case .op_over:
            guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
            stack.append(stack[stack.count - 2])
        case .op_swap:
            guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
            stack.swapAt(stack.count - 1, stack.count - 2)
        case .op_rot:
            guard stack.count >= 3 else { throw ScriptError.stackUnderflow }
            let item = stack.remove(at: stack.count - 3)
            stack.append(item)
        case .op_tuck:
            guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
            stack.insert(stack.last!, at: stack.count - 2)
        case .op_toaltstack:
            guard let top = stack.popLast() else { throw ScriptError.stackUnderflow }
            altStack.append(top)
        case .op_fromaltstack:
            guard let top = altStack.popLast() else { throw ScriptError.stackUnderflow }
            stack.append(top)
        case .op_size:
            guard let top = stack.last else { throw ScriptError.stackUnderflow }
            stack.append(ScriptNumber.encode(Int64(top.count)))

        // Arithmetic
        case .op_1add:
            try unaryArith { $0 + 1 }
        case .op_1sub:
            try unaryArith { $0 - 1 }
        case .op_negate:
            try unaryArith { -$0 }
        case .op_abs:
            try unaryArith { abs($0) }
        case .op_not:
            try unaryArith { $0 == 0 ? 1 : 0 }
        case .op_0notequal:
            try unaryArith { $0 != 0 ? 1 : 0 }
        case .op_add:
            try binaryArith { $0 + $1 }
        case .op_sub:
            try binaryArith { $0 - $1 }
        case .op_booland:
            try binaryArith { ($0 != 0 && $1 != 0) ? 1 : 0 }
        case .op_boolor:
            try binaryArith { ($0 != 0 || $1 != 0) ? 1 : 0 }
        case .op_numequal:
            try binaryArith { $0 == $1 ? 1 : 0 }
        case .op_numnotequal:
            try binaryArith { $0 != $1 ? 1 : 0 }
        case .op_lessthan:
            try binaryArith { $0 < $1 ? 1 : 0 }
        case .op_greaterthan:
            try binaryArith { $0 > $1 ? 1 : 0 }
        case .op_lessthanorequal:
            try binaryArith { $0 <= $1 ? 1 : 0 }
        case .op_greaterthanorequal:
            try binaryArith { $0 >= $1 ? 1 : 0 }
        case .op_min:
            try binaryArith { min($0, $1) }
        case .op_max:
            try binaryArith { max($0, $1) }
        case .op_within:
            guard stack.count >= 3 else { throw ScriptError.stackUnderflow }
            let maxVal = ScriptNumber.decode(stack.removeLast())
            let minVal = ScriptNumber.decode(stack.removeLast())
            let x = ScriptNumber.decode(stack.removeLast())
            stack.append(ScriptNumber.encode((x >= minVal && x < maxVal) ? 1 : 0))

        // Crypto
        case .op_sha256:
            guard let top = stack.popLast() else { throw ScriptError.stackUnderflow }
            stack.append(Crypto.sha256(top))
        case .op_hash160:
            guard let top = stack.popLast() else { throw ScriptError.stackUnderflow }
            stack.append(Crypto.hash160(top))
        case .op_hash256:
            guard let top = stack.popLast() else { throw ScriptError.stackUnderflow }
            stack.append(Crypto.hash256(top))
        case .op_ripemd160:
            guard let top = stack.popLast() else { throw ScriptError.stackUnderflow }
            stack.append(RIPEMD160.hash(top))

        // Equality
        case .op_equal:
            guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
            let b = stack.removeLast()
            let a = stack.removeLast()
            // Compare as script numbers first (handles different encodings of same value),
            // fall back to byte comparison for non-numeric data
            let numA = ScriptNumber.decode(a)
            let numB = ScriptNumber.decode(b)
            let equal = (a == b) || (ScriptNumber.encode(numA) == a && ScriptNumber.encode(numB) == b && numA == numB)
            stack.append(equal ? ScriptNumber.encode(1) : Data())
        case .op_equalverify:
            guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
            let b = stack.removeLast()
            let a = stack.removeLast()
            let numA = ScriptNumber.decode(a)
            let numB = ScriptNumber.decode(b)
            let equal = (a == b) || (ScriptNumber.encode(numA) == a && ScriptNumber.encode(numB) == b && numA == numB)
            guard equal else { throw ScriptError.verifyFailed("OP_EQUALVERIFY") }

        // Verify
        case .op_verify:
            guard let top = stack.popLast() else { throw ScriptError.stackUnderflow }
            let val = ScriptNumber.decode(top)
            guard val != 0 else { throw ScriptError.verifyFailed("OP_VERIFY") }

        // Signature verification (stub - real verification happens on Ledger)
        case .op_checksig:
            guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
            _ = stack.removeLast() // pubkey
            _ = stack.removeLast() // sig
            stack.append(ScriptNumber.encode(1)) // Assume valid in interpreter
            log.append("  (signature check assumed valid)")
        case .op_checksigverify:
            guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
            _ = stack.removeLast()
            _ = stack.removeLast()
            log.append("  (signature check assumed valid)")
        case .op_checkmultisig:
            guard stack.count >= 1 else { throw ScriptError.stackUnderflow }
            let n = Int(ScriptNumber.decode(stack.removeLast()))
            guard stack.count >= n else { throw ScriptError.stackUnderflow }
            for _ in 0..<n { _ = stack.removeLast() } // pubkeys
            guard stack.count >= 1 else { throw ScriptError.stackUnderflow }
            let mVal = Int(ScriptNumber.decode(stack.removeLast()))
            guard stack.count >= mVal else { throw ScriptError.stackUnderflow }
            for _ in 0..<mVal { _ = stack.removeLast() } // sigs
            if !stack.isEmpty { _ = stack.removeLast() } // OP_0 bug
            stack.append(ScriptNumber.encode(1)) // Assume valid
            log.append("  (multisig check assumed valid)")

        // Timelocks (just check format, don't enforce)
        case .op_checklocktimeverify:
            guard !stack.isEmpty else { throw ScriptError.stackUnderflow }
            log.append("  CLTV: lock until \(ScriptNumber.decode(stack.last!))")
        case .op_checksequenceverify:
            guard !stack.isEmpty else { throw ScriptError.stackUnderflow }
            log.append("  CSV: relative lock \(ScriptNumber.decode(stack.last!))")

        // Flow control (simplified)
        case .op_if, .op_notif, .op_else, .op_endif:
            log.append("  (flow control - simplified in interpreter)")

        // NOP
        case .op_nop:
            break

        case .op_return:
            throw ScriptError.opReturn

        default:
            throw ScriptError.unknownOpcode(op.rawValue)
        }

        logStack()
    }

    // MARK: - Helpers

    private func unaryArith(_ op: (Int64) -> Int64) throws {
        guard let top = stack.popLast() else { throw ScriptError.stackUnderflow }
        stack.append(ScriptNumber.encode(op(ScriptNumber.decode(top))))
    }

    private func binaryArith(_ op: (Int64, Int64) -> Int64) throws {
        guard stack.count >= 2 else { throw ScriptError.stackUnderflow }
        let b = ScriptNumber.decode(stack.removeLast())
        let a = ScriptNumber.decode(stack.removeLast())
        stack.append(ScriptNumber.encode(op(a, b)))
    }

    private func logStack() {
        let items = stack.map { $0.isEmpty ? "[]" : $0.hex }
        log.append("  Stack: [\(items.joined(separator: ", "))]")
    }

    // MARK: - Quick insert opcodes

    static let quickOpcodes: [(String, String)] = [
        ("OP_DUP", "OP_DUP"), ("OP_HASH160", "OP_HASH160"),
        ("OP_EQUALVERIFY", "OP_EQUALVERIFY"), ("OP_CHECKSIG", "OP_CHECKSIG"),
        ("OP_ADD", "OP_ADD"), ("OP_SUB", "OP_SUB"),
        ("OP_EQUAL", "OP_EQUAL"), ("OP_VERIFY", "OP_VERIFY"),
        ("OP_IF", "OP_IF"), ("OP_ELSE", "OP_ELSE"), ("OP_ENDIF", "OP_ENDIF"),
        ("OP_CLTV", "OP_CHECKLOCKTIMEVERIFY"), ("OP_CSV", "OP_CHECKSEQUENCEVERIFY"),
        ("OP_DROP", "OP_DROP"), ("OP_SWAP", "OP_SWAP"),
        ("OP_0", "OP_0"), ("OP_1", "OP_1"),
        ("OP_CHECKMULTISIG", "OP_CHECKMULTISIG"),
        ("OP_RETURN", "OP_RETURN"), ("OP_SHA256", "OP_SHA256"),
    ]

    enum ScriptError: LocalizedError {
        case stackUnderflow
        case unknownToken(String)
        case unknownOpcode(UInt8)
        case verifyFailed(String)
        case opReturn

        var errorDescription: String? {
            switch self {
            case .stackUnderflow: return "Stack underflow"
            case .unknownToken(let t): return "Token inconnu: \(t)"
            case .unknownOpcode(let o): return "Opcode inconnu: 0x\(String(format: "%02x", o))"
            case .verifyFailed(let op): return "\(op) échoué"
            case .opReturn: return "OP_RETURN rencontré"
            }
        }
    }
}
