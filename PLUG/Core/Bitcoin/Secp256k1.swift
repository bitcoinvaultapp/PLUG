import Foundation
import libsecp256k1

// MARK: - secp256k1 wrapper using libsecp256k1 (Bitcoin Core's C library)
// All EC operations use the battle-tested, constant-time, audited C implementation.

// Shared context (thread-safe for verification operations)
private let secp256k1Ctx: OpaquePointer = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY))

// MARK: - Fixed-width 256-bit unsigned integer (kept for BInt/Base58)

struct UInt256: Equatable, Comparable {
    var w0: UInt64; var w1: UInt64; var w2: UInt64; var w3: UInt64

    static let zero = UInt256(w0: 0, w1: 0, w2: 0, w3: 0)
    static let one  = UInt256(w0: 1, w1: 0, w2: 0, w3: 0)

    init(w0: UInt64 = 0, w1: UInt64 = 0, w2: UInt64 = 0, w3: UInt64 = 0) {
        self.w0 = w0; self.w1 = w1; self.w2 = w2; self.w3 = w3
    }
    init(_ v: UInt64) { self.init(w0: v) }

    init?(hex: String) {
        let s = hex.count < 64 ? String(repeating: "0", count: 64 - hex.count) + hex : hex
        guard s.count == 64 else { return nil }
        let idx = s.startIndex
        guard let h3 = UInt64(s[idx..<s.index(idx, offsetBy: 16)], radix: 16),
              let h2 = UInt64(s[s.index(idx, offsetBy: 16)..<s.index(idx, offsetBy: 32)], radix: 16),
              let h1 = UInt64(s[s.index(idx, offsetBy: 32)..<s.index(idx, offsetBy: 48)], radix: 16),
              let h0 = UInt64(s[s.index(idx, offsetBy: 48)..<s.index(idx, offsetBy: 64)], radix: 16) else { return nil }
        self.init(w0: h0, w1: h1, w2: h2, w3: h3)
    }

    init?(data: Data) {
        guard data.count >= 1 && data.count <= 32 else { return nil }
        let padded = Data(repeating: 0, count: 32 - data.count) + data
        self.init(
            w0: Self.readUInt64BE(padded, offset: 24), w1: Self.readUInt64BE(padded, offset: 16),
            w2: Self.readUInt64BE(padded, offset: 8), w3: Self.readUInt64BE(padded, offset: 0)
        )
    }

    private static func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
        var r: UInt64 = 0; for i in 0..<8 { r = (r << 8) | UInt64(data[offset + i]) }; return r
    }

    func toData() -> Data {
        var d = Data(count: 32)
        for i in 0..<8 { d[i] = UInt8((w3 >> (56 - i * 8)) & 0xFF) }
        for i in 0..<8 { d[8+i] = UInt8((w2 >> (56 - i * 8)) & 0xFF) }
        for i in 0..<8 { d[16+i] = UInt8((w1 >> (56 - i * 8)) & 0xFF) }
        for i in 0..<8 { d[24+i] = UInt8((w0 >> (56 - i * 8)) & 0xFF) }
        return d
    }

    var isZero: Bool { w0 == 0 && w1 == 0 && w2 == 0 && w3 == 0 }
    var isEven: Bool { w0 & 1 == 0 }
    var bit0: Bool { w0 & 1 != 0 }

    static func == (a: UInt256, b: UInt256) -> Bool { a.w0 == b.w0 && a.w1 == b.w1 && a.w2 == b.w2 && a.w3 == b.w3 }
    static func < (a: UInt256, b: UInt256) -> Bool {
        if a.w3 != b.w3 { return a.w3 < b.w3 }; if a.w2 != b.w2 { return a.w2 < b.w2 }
        if a.w1 != b.w1 { return a.w1 < b.w1 }; return a.w0 < b.w0
    }

    static func addWithCarry(_ a: UInt256, _ b: UInt256) -> (UInt256, Bool) {
        var r = UInt256.zero; var c: Bool
        (r.w0, c) = a.w0.addingReportingOverflow(b.w0); let c0: UInt64 = c ? 1 : 0
        (r.w1, c) = a.w1.addingReportingOverflow(b.w1); let c1a = c
        (r.w1, c) = r.w1.addingReportingOverflow(c0); let c1: UInt64 = (c1a || c) ? 1 : 0
        (r.w2, c) = a.w2.addingReportingOverflow(b.w2); let c2a = c
        (r.w2, c) = r.w2.addingReportingOverflow(c1); let c2: UInt64 = (c2a || c) ? 1 : 0
        (r.w3, c) = a.w3.addingReportingOverflow(b.w3); let c3a = c
        (r.w3, c) = r.w3.addingReportingOverflow(c2); return (r, c3a || c)
    }

    static func sub(_ a: UInt256, _ b: UInt256) -> UInt256 {
        var r = UInt256.zero; var bw: Bool
        (r.w0, bw) = a.w0.subtractingReportingOverflow(b.w0); let b0: UInt64 = bw ? 1 : 0
        (r.w1, bw) = a.w1.subtractingReportingOverflow(b.w1); let b1a = bw
        (r.w1, bw) = r.w1.subtractingReportingOverflow(b0); let b1: UInt64 = (b1a || bw) ? 1 : 0
        (r.w2, bw) = a.w2.subtractingReportingOverflow(b.w2); let b2a = bw
        (r.w2, bw) = r.w2.subtractingReportingOverflow(b1); let b2: UInt64 = (b2a || bw) ? 1 : 0
        (r.w3, bw) = a.w3.subtractingReportingOverflow(b.w3); (r.w3, _) = r.w3.subtractingReportingOverflow(b2)
        return r
    }

    func shiftedRight1() -> UInt256 {
        UInt256(w0: (w0 >> 1) | (w1 << 63), w1: (w1 >> 1) | (w2 << 63), w2: (w2 >> 1) | (w3 << 63), w3: w3 >> 1)
    }
}

// MARK: - secp256k1 curve operations (backed by libsecp256k1 C library)

struct Secp256k1 {

    static let n = UInt256(w0: 0xBFD25E8CD0364141, w1: 0xBAAEDCE6AF48A03B, w2: 0xFFFFFFFFFFFFFFFE, w3: 0xFFFFFFFFFFFFFFFF)

    struct Point: Equatable {
        let compressed: Data
        let isInfinity: Bool
        var x: UInt256 { compressed.count == 33 ? (UInt256(data: Data(compressed[1...])) ?? .zero) : .zero }
        var y: UInt256 { .zero }

        static let infinity = Point(compressed: Data(), isInfinity: true)
        init(compressed: Data, isInfinity: Bool = false) { self.compressed = compressed; self.isInfinity = isInfinity }
        init(x: UInt256, y: UInt256, isInfinity: Bool = false) {
            if isInfinity { self.compressed = Data(); self.isInfinity = true }
            else { self.compressed = Data([y.isEven ? 0x02 : 0x03]) + x.toData(); self.isInfinity = false }
        }
    }

    static let G: Point = {
        let gx = UInt256(w0: 0x59F2815B16F81798, w1: 0x029BFCDB2DCE28D9, w2: 0x55A06295CE870B07, w3: 0x79BE667EF9DCBBAC)
        return Point(compressed: Data([0x02]) + gx.toData())
    }()

    // MARK: - Public API

    static func parsePublicKey(_ data: Data) -> Point? {
        guard data.count == 33, (data[0] == 0x02 || data[0] == 0x03) else { return nil }
        var pubkey = secp256k1_pubkey()
        let ok = data.withUnsafeBytes { ptr in
            secp256k1_ec_pubkey_parse(secp256k1Ctx, &pubkey, ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), 33)
        }
        guard ok == 1 else { return nil }
        return Point(compressed: data)
    }

    static func serializePublicKey(_ point: Point) -> Data {
        guard !point.isInfinity else { return Data() }
        return point.compressed
    }

    static func pointAdd(_ p1: Point, _ p2: Point) -> Point {
        if p1.isInfinity { return p2 }
        if p2.isInfinity { return p1 }

        var pk1 = secp256k1_pubkey()
        var pk2 = secp256k1_pubkey()

        let ok1 = p1.compressed.withUnsafeBytes { secp256k1_ec_pubkey_parse(secp256k1Ctx, &pk1, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), 33) }
        let ok2 = p2.compressed.withUnsafeBytes { secp256k1_ec_pubkey_parse(secp256k1Ctx, &pk2, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), 33) }
        guard ok1 == 1, ok2 == 1 else { return .infinity }

        var result = secp256k1_pubkey()
        var ptrs: [UnsafePointer<secp256k1_pubkey>?] = []
        let ok = withUnsafePointer(to: &pk1) { ptr1 in
            withUnsafePointer(to: &pk2) { ptr2 in
                var arr: [UnsafePointer<secp256k1_pubkey>?] = [ptr1, ptr2]
                return secp256k1_ec_pubkey_combine(secp256k1Ctx, &result, &arr, 2)
            }
        }
        guard ok == 1 else { return .infinity }

        var output = Data(count: 33)
        var outputLen = 33
        output.withUnsafeMutableBytes { ptr in
            secp256k1_ec_pubkey_serialize(secp256k1Ctx, ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), &outputLen, &result, UInt32(SECP256K1_EC_COMPRESSED))
        }
        return Point(compressed: output)
    }

    static func scalarMultiply(_ k: UInt256, _ point: Point) -> Point {
        if point.compressed == G.compressed {
            return scalarMultiplyGenerator(k)
        }
        guard !point.isInfinity else { return .infinity }

        // k * P: parse P, then tweak by k
        var pk = secp256k1_pubkey()
        let parseOk = point.compressed.withUnsafeBytes {
            secp256k1_ec_pubkey_parse(secp256k1Ctx, &pk, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), 33)
        }
        guard parseOk == 1 else { return .infinity }

        var tweak = k.toData()
        let tweakOk = tweak.withUnsafeBytes {
            secp256k1_ec_pubkey_tweak_mul(secp256k1Ctx, &pk, $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        guard tweakOk == 1 else { return .infinity }

        var output = Data(count: 33)
        var outputLen = 33
        output.withUnsafeMutableBytes {
            secp256k1_ec_pubkey_serialize(secp256k1Ctx, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), &outputLen, &pk, UInt32(SECP256K1_EC_COMPRESSED))
        }
        return Point(compressed: output)
    }

    /// BIP32 child key derivation: parentKey + IL * G
    static func deriveChildPublicKey(parentKey: Data, scalar: UInt256) -> Data? {
        guard parentKey.count == 33 else { return nil }

        var pk = secp256k1_pubkey()
        let parseOk = parentKey.withUnsafeBytes {
            secp256k1_ec_pubkey_parse(secp256k1Ctx, &pk, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), 33)
        }
        guard parseOk == 1 else { return nil }

        var tweak = scalar.toData()
        let tweakOk = tweak.withUnsafeBytes {
            secp256k1_ec_pubkey_tweak_add(secp256k1Ctx, &pk, $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        guard tweakOk == 1 else { return nil }

        var output = Data(count: 33)
        var outputLen = 33
        output.withUnsafeMutableBytes {
            secp256k1_ec_pubkey_serialize(secp256k1Ctx, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), &outputLen, &pk, UInt32(SECP256K1_EC_COMPRESSED))
        }
        return output
    }

    // MARK: - Private

    private static func scalarMultiplyGenerator(_ k: UInt256) -> Point {
        var seckey = k.toData()
        var pk = secp256k1_pubkey()
        let ok = seckey.withUnsafeBytes {
            secp256k1_ec_pubkey_create(secp256k1Ctx, &pk, $0.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        guard ok == 1 else { return .infinity }

        var output = Data(count: 33)
        var outputLen = 33
        output.withUnsafeMutableBytes {
            secp256k1_ec_pubkey_serialize(secp256k1Ctx, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), &outputLen, &pk, UInt32(SECP256K1_EC_COMPRESSED))
        }
        return Point(compressed: output)
    }
}

// MARK: - BInt wrapper (kept for Base58 compatibility)

struct BInt: Equatable, Comparable, CustomStringConvertible {
    var value: UInt256
    static let zero = BInt(value: .zero); static let one = BInt(value: .one)
    init(_ v: Int) { value = UInt256(UInt64(v < 0 ? 0 : v)) }
    init(_ v: UInt64) { value = UInt256(v) }
    init(value: UInt256) { self.value = value }
    init?(data: Data) { guard let v = UInt256(data: data) else { return nil }; self.value = v }
    init?(_ string: String, radix: Int) { guard radix == 16, let v = UInt256(hex: string) else { return nil }; self.value = v }
    var isEven: Bool { value.isEven }; var isZero: Bool { value.isZero }; var isNegative: Bool = false
    var description: String {
        if isZero { return "0" }; var hex = ""; let d = value.toData(); var lz = true
        for b in d { if lz && b == 0 { continue }; lz = false; hex += String(format: "%02x", b) }
        return hex.isEmpty ? "0" : hex
    }
    func toData() -> Data { value.toData() }
    var magnitude: [UInt64] { [value.w0, value.w1, value.w2, value.w3] }
    static func == (a: BInt, b: BInt) -> Bool { a.value == b.value }
    static func < (a: BInt, b: BInt) -> Bool { a.isNegative != b.isNegative ? a.isNegative : (a.isNegative ? b.value < a.value : a.value < b.value) }
    static func + (a: BInt, b: BInt) -> BInt { BInt(value: UInt256.addWithCarry(a.value, b.value).0) }
    static func - (a: BInt, b: BInt) -> BInt {
        if a.value >= b.value { return BInt(value: UInt256.sub(a.value, b.value)) }
        var r = BInt(value: UInt256.sub(b.value, a.value)); r.isNegative = true; return r
    }
    func divMod(_ divisor: BInt) -> (BInt, BInt) {
        let d = divisor.value.w0; guard d > 0 else { fatalError("Division by zero") }
        var rem: UInt64 = 0; let limbs = [value.w3, value.w2, value.w1, value.w0]; var q: [UInt64] = [0,0,0,0]
        for i in 0..<4 { let (qq, r) = d.dividingFullWidth((high: rem, low: limbs[i])); q[i] = qq; rem = r }
        return (BInt(value: UInt256(w0: q[3], w1: q[2], w2: q[1], w3: q[0])), BInt(UInt64(rem)))
    }
    static func / (a: BInt, b: BInt) -> BInt { a.divMod(b).0 }
    static func % (a: BInt, b: BInt) -> BInt { a.divMod(b).1 }
    func mod(_ m: BInt) -> BInt { self % m }
    static func >> (a: BInt, b: Int) -> BInt { var v = a.value; for _ in 0..<b { v = v.shiftedRight1() }; return BInt(value: v) }
}
