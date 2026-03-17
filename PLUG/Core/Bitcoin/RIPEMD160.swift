import Foundation

// MARK: - RIPEMD-160 pure Swift implementation
// No external dependencies - implemented from the spec

struct RIPEMD160 {

    private static let k0: UInt32 = 0x00000000
    private static let k1: UInt32 = 0x5A827999
    private static let k2: UInt32 = 0x6ED9EBA1
    private static let k3: UInt32 = 0x8F1BBCDC
    private static let k4: UInt32 = 0xA953FD4E

    private static let kk0: UInt32 = 0x50A28BE6
    private static let kk1: UInt32 = 0x5C4DD124
    private static let kk2: UInt32 = 0x6D703EF3
    private static let kk3: UInt32 = 0x7A6D76E9
    private static let kk4: UInt32 = 0x00000000

    private static let r: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
        4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13
    ]

    private static let rr: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
        12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11
    ]

    private static let s: [UInt32] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
        9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6
    ]

    private static let ss: [UInt32] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
        8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11
    ]

    private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case 0..<16:  return x ^ y ^ z
        case 16..<32: return (x & y) | (~x & z)
        case 32..<48: return (x | ~y) ^ z
        case 48..<64: return (x & z) | (y & ~z)
        case 64..<80: return x ^ (y | ~z)
        default: fatalError()
        }
    }

    private static func kLeft(_ j: Int) -> UInt32 {
        switch j {
        case 0..<16:  return k0
        case 16..<32: return k1
        case 32..<48: return k2
        case 48..<64: return k3
        case 64..<80: return k4
        default: fatalError()
        }
    }

    private static func kRight(_ j: Int) -> UInt32 {
        switch j {
        case 0..<16:  return kk0
        case 16..<32: return kk1
        case 32..<48: return kk2
        case 48..<64: return kk3
        case 64..<80: return kk4
        default: fatalError()
        }
    }

    static func hash(_ message: Data) -> Data {
        var msg = message
        let originalLength = msg.count

        // Padding
        msg.append(0x80)
        while msg.count % 64 != 56 {
            msg.append(0x00)
        }

        // Length in bits as 64-bit little-endian
        var bitLength = UInt64(originalLength) * 8
        msg.append(Data(bytes: &bitLength, count: 8))

        // Initial hash values
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        // Process each 512-bit block
        let blockCount = msg.count / 64
        for i in 0..<blockCount {
            let blockStart = i * 64
            var x = [UInt32](repeating: 0, count: 16)
            for j in 0..<16 {
                let offset = blockStart + j * 4
                x[j] = UInt32(msg[offset]) |
                        (UInt32(msg[offset + 1]) << 8) |
                        (UInt32(msg[offset + 2]) << 16) |
                        (UInt32(msg[offset + 3]) << 24)
            }

            var al = h0, bl = h1, cl = h2, dl = h3, el = h4
            var ar = h0, br = h1, cr = h2, dr = h3, er = h4

            for j in 0..<80 {
                // Left round
                let tl = al &+ f(j, bl, cl, dl) &+ x[r[j]] &+ kLeft(j)
                let rotatedL = (tl << s[j]) | (tl >> (32 - s[j]))
                let newAl = rotatedL &+ el
                al = el; el = dl; dl = (cl << 10) | (cl >> 22); cl = bl; bl = newAl

                // Right round
                let tr = ar &+ f(79 - j, br, cr, dr) &+ x[rr[j]] &+ kRight(j)
                let rotatedR = (tr << ss[j]) | (tr >> (32 - ss[j]))
                let newAr = rotatedR &+ er
                ar = er; er = dr; dr = (cr << 10) | (cr >> 22); cr = br; br = newAr
            }

            let t = h1 &+ cl &+ dr
            h1 = h2 &+ dl &+ er
            h2 = h3 &+ el &+ ar
            h3 = h4 &+ al &+ br
            h4 = h0 &+ bl &+ cr
            h0 = t
        }

        var result = Data(count: 20)
        for (i, val) in [h0, h1, h2, h3, h4].enumerated() {
            result[i * 4] = UInt8(val & 0xFF)
            result[i * 4 + 1] = UInt8((val >> 8) & 0xFF)
            result[i * 4 + 2] = UInt8((val >> 16) & 0xFF)
            result[i * 4 + 3] = UInt8((val >> 24) & 0xFF)
        }

        return result
    }
}
