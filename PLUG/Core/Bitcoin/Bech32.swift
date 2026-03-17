import Foundation

// MARK: - Bech32 / Bech32m encoding for SegWit addresses
// BIP173 (Bech32) and BIP350 (Bech32m)

enum Bech32Variant {
    case bech32   // SegWit v0
    case bech32m  // SegWit v1+ (Taproot)
}

struct Bech32 {

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    private static let charsetMap: [Character: UInt8] = {
        var map = [Character: UInt8]()
        for (i, c) in charset.enumerated() {
            map[c] = UInt8(i)
        }
        return map
    }()

    private static let generator: [UInt32] = [
        0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3
    ]

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 {
                if (top >> i) & 1 != 0 {
                    chk ^= generator[i]
                }
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var ret = [UInt8]()
        for c in hrp.utf8 {
            ret.append(c >> 5)
        }
        ret.append(0)
        for c in hrp.utf8 {
            ret.append(c & 31)
        }
        return ret
    }

    private static func verifyChecksum(_ hrp: String, _ data: [UInt8]) -> Bech32Variant? {
        let values = hrpExpand(hrp) + data
        let check = polymod(values)
        if check == 1 { return .bech32 }
        if check == 0x2bc830a3 { return .bech32m }
        return nil
    }

    private static func createChecksum(_ hrp: String, _ data: [UInt8], variant: Bech32Variant) -> [UInt8] {
        let values = hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
        let constant: UInt32 = variant == .bech32 ? 1 : 0x2bc830a3
        let polymodValue = polymod(values) ^ constant
        var checksum = [UInt8]()
        for i in 0..<6 {
            checksum.append(UInt8((polymodValue >> (5 * (5 - i))) & 31))
        }
        return checksum
    }

    /// Encode to bech32/bech32m string
    static func encode(hrp: String, data: [UInt8], variant: Bech32Variant) -> String {
        let checksum = createChecksum(hrp, data, variant: variant)
        let combined = data + checksum
        var result = hrp + "1"
        for d in combined {
            result.append(charset[Int(d)])
        }
        return result
    }

    /// Decode bech32/bech32m string
    static func decode(_ str: String) -> (hrp: String, data: [UInt8], variant: Bech32Variant)? {
        let lower = str.lowercased()
        guard let sepIdx = lower.lastIndex(of: "1") else { return nil }
        let hrp = String(lower[lower.startIndex..<sepIdx])
        let dataStr = String(lower[lower.index(after: sepIdx)...])

        guard dataStr.count >= 6 else { return nil }

        var data = [UInt8]()
        for c in dataStr {
            guard let v = charsetMap[c] else { return nil }
            data.append(v)
        }

        guard let variant = verifyChecksum(hrp, data) else { return nil }

        return (hrp, Array(data.dropLast(6)), variant)
    }

    // MARK: - SegWit address encoding/decoding

    /// Convert 8-bit data to 5-bit groups
    static func convertBits(data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var result = [UInt8]()
        let maxv = (1 << toBits) - 1

        for value in data {
            if Int(value) >> fromBits != 0 { return nil }
            acc = (acc << fromBits) | Int(value)
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                result.append(UInt8((acc >> bits) & maxv))
            }
        }

        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (toBits - bits)) & maxv))
            }
        } else {
            if bits >= fromBits { return nil }
            if (acc << (toBits - bits)) & maxv != 0 { return nil }
        }

        return result
    }

    /// Encode a SegWit address
    static func segwitEncode(hrp: String, version: Int, program: Data) -> String? {
        guard version >= 0 && version <= 16 else { return nil }
        guard let converted = convertBits(data: Array(program), fromBits: 8, toBits: 5, pad: true) else { return nil }
        let variant: Bech32Variant = version == 0 ? .bech32 : .bech32m
        return encode(hrp: hrp, data: [UInt8(version)] + converted, variant: variant)
    }

    /// Decode a SegWit address
    static func segwitDecode(hrp: String, addr: String) -> (version: Int, program: Data)? {
        guard let (decodedHrp, data, variant) = decode(addr) else { return nil }
        guard decodedHrp == hrp else { return nil }
        guard !data.isEmpty else { return nil }

        let version = Int(data[0])
        guard version >= 0 && version <= 16 else { return nil }

        // Check variant matches version
        if version == 0 && variant != .bech32 { return nil }
        if version != 0 && variant != .bech32m { return nil }

        guard let program = convertBits(data: Array(data[1...]), fromBits: 5, toBits: 8, pad: false) else { return nil }

        // SegWit v0 must be 20 or 32 bytes, v1+ must be 2-40 bytes
        if version == 0 {
            guard program.count == 20 || program.count == 32 else { return nil }
        } else {
            guard program.count >= 2 && program.count <= 40 else { return nil }
        }

        return (version, Data(program))
    }
}
