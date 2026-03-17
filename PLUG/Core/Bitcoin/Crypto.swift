import Foundation
import CommonCrypto
import CryptoKit

// MARK: - Crypto utilities (HMAC-SHA512, SHA256, Hash160)
// Uses Apple CryptoKit/CommonCrypto - no external dependencies

enum Crypto {

    /// SHA-256 hash
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Double SHA-256 (used in Bitcoin for txids, block hashes, etc.)
    static func hash256(_ data: Data) -> Data {
        sha256(sha256(data))
    }

    /// Hash160 = RIPEMD160(SHA256(data)) - used for address generation
    static func hash160(_ data: Data) -> Data {
        RIPEMD160.hash(sha256(data))
    }

    /// HMAC-SHA512 - used for BIP32 key derivation
    static func hmacSHA512(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let auth = HMAC<SHA512>.authenticationCode(for: data, using: symmetricKey)
        return Data(auth)
    }
}

// MARK: - Data hex helpers

extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}

// MARK: - VarInt encoding (Bitcoin serialization)

enum VarInt {
    static func encode(_ value: UInt64) -> Data {
        var data = Data()
        if value < 0xFD {
            data.append(UInt8(value))
        } else if value <= 0xFFFF {
            data.append(0xFD)
            var v = UInt16(value).littleEndian
            data.append(Data(bytes: &v, count: 2))
        } else if value <= 0xFFFFFFFF {
            data.append(0xFE)
            var v = UInt32(value).littleEndian
            data.append(Data(bytes: &v, count: 4))
        } else {
            data.append(0xFF)
            var v = value.littleEndian
            data.append(Data(bytes: &v, count: 8))
        }
        return data
    }

    static func decode(_ data: Data, offset: Int) -> (value: UInt64, bytesRead: Int)? {
        guard offset < data.count else { return nil }
        let first = data[offset]
        switch first {
        case 0..<0xFD:
            return (UInt64(first), 1)
        case 0xFD:
            guard offset + 2 < data.count else { return nil }
            let v = UInt16(data[offset + 1]) | (UInt16(data[offset + 2]) << 8)
            return (UInt64(v), 3)
        case 0xFE:
            guard offset + 4 < data.count else { return nil }
            let v = UInt32(data[offset + 1]) | (UInt32(data[offset + 2]) << 8) |
                    (UInt32(data[offset + 3]) << 16) | (UInt32(data[offset + 4]) << 24)
            return (UInt64(v), 5)
        case 0xFF:
            guard offset + 8 < data.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 {
                v |= UInt64(data[offset + 1 + i]) << (i * 8)
            }
            return (v, 9)
        default:
            return nil
        }
    }
}
