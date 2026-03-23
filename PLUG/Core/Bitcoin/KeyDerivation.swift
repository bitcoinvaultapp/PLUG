import Foundation

// MARK: - BIP32 HD Key Derivation (public key only, non-hardened)
// Derives child public keys from xpub for address generation.
// Private keys never leave the Ledger device.

struct ExtendedPublicKey {
    let key: Data       // 33 bytes compressed public key
    let chainCode: Data // 32 bytes chain code
    let depth: UInt8
    let fingerprint: Data // 4 bytes
    let childIndex: UInt32

    /// Parse an xpub/tpub string (Base58Check encoded)
    static func fromBase58(_ xpub: String) -> ExtendedPublicKey? {
        guard let decoded = Base58Check.decode(xpub) else { return nil }
        guard decoded.count == 78 else { return nil }

        // First 4 bytes: version (xpub = 0488B21E, tpub = 043587CF)
        let depth = decoded[4]
        let fingerprint = Data(decoded[5..<9])
        let childIndex = UInt32(decoded[9]) << 24 | UInt32(decoded[10]) << 16 |
                         UInt32(decoded[11]) << 8 | UInt32(decoded[12])
        let chainCode = Data(decoded[13..<45])
        let key = Data(decoded[45..<78])

        guard key[0] == 0x02 || key[0] == 0x03 else { return nil }

        return ExtendedPublicKey(
            key: key,
            chainCode: chainCode,
            depth: depth,
            fingerprint: fingerprint,
            childIndex: childIndex
        )
    }

    /// Derive a non-hardened child public key (BIP32)
    /// index must be < 0x80000000 (non-hardened)
    func deriveChild(index: UInt32) -> ExtendedPublicKey? {
        guard index < 0x80000000 else { return nil } // Only non-hardened

        // Data = serP(parentKey) || ser32(index)
        var data = key
        var indexBE = index.bigEndian
        data.append(Data(bytes: &indexBE, count: 4))

        // HMAC-SHA512(Key = chainCode, Data = data)
        let hmac = Crypto.hmacSHA512(key: chainCode, data: data)
        let il = Data(hmac[0..<32])
        let ir = Data(hmac[32..<64])

        // Parse IL as 256-bit integer
        guard let ilInt = BInt(data: il) else { return nil }

        // Check IL < n (order of secp256k1)
        guard ilInt.value < Secp256k1.n else { return nil }

        // childKey = point(IL) + parentKey
        guard let childKey = Secp256k1.deriveChildPublicKey(parentKey: key, scalar: ilInt.value) else { return nil }

        // Parent fingerprint = first 4 bytes of Hash160(parentKey)
        let parentHash = Crypto.hash160(key)
        let fp = Data(parentHash[0..<4])

        return ExtendedPublicKey(
            key: childKey,
            chainCode: ir,
            depth: depth + 1,
            fingerprint: fp,
            childIndex: index
        )
    }

    /// Derive a path like m/0/i (for receiving) or m/1/i (for change)
    func derivePath(_ components: [UInt32]) -> ExtendedPublicKey? {
        var current: ExtendedPublicKey? = self
        for index in components {
            current = current?.deriveChild(index: index)
        }
        return current
    }

    /// Generate a P2WPKH (SegWit v0) address from this key
    func segwitAddress(isTestnet: Bool) -> String? {
        let hash = Crypto.hash160(key)
        let hrp = isTestnet ? "tb" : "bc"
        return Bech32.segwitEncode(hrp: hrp, version: 0, program: hash)
    }

    /// Generate a P2TR (SegWit v1, Taproot) address from this key.
    /// Uses x-only key tweaked with no script tree (key-path only, BIP86).
    func taprootAddress(isTestnet: Bool) -> String? {
        let xOnly = Secp256k1.xOnly(key)
        return TaprootBuilder.taprootAddress(internalKey: xOnly, isTestnet: isTestnet)
    }

    /// Serialize back to xpub/tpub Base58Check
    func toBase58(isTestnet: Bool) -> String {
        var data = Data()
        // Version bytes
        if isTestnet {
            data.append(contentsOf: [0x04, 0x35, 0x87, 0xCF]) // tpub
        } else {
            data.append(contentsOf: [0x04, 0x88, 0xB2, 0x1E]) // xpub
        }
        data.append(depth)
        data.append(fingerprint)
        var idx = childIndex.bigEndian
        data.append(Data(bytes: &idx, count: 4))
        data.append(chainCode)
        data.append(key)
        return Base58Check.encode(data)
    }
}

// MARK: - Base58Check encoding (for xpub/tpub)

enum Base58Check {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    // MARK: - Arbitrary-precision Base58 using [UInt8] byte array arithmetic
    // BInt/UInt256 is limited to 256 bits — xpubs are 82 bytes (656 bits).
    // We use simple byte-array big-number arithmetic here instead.

    /// Multiply a big number (byte array, big-endian) by a small int and add a small int
    private static func mulAdd(_ num: inout [UInt8], _ mul: Int, _ add: Int) {
        var carry = add
        for i in stride(from: num.count - 1, through: 0, by: -1) {
            let v = Int(num[i]) * mul + carry
            num[i] = UInt8(v % 256)
            carry = v / 256
        }
        // Extend if needed
        while carry > 0 {
            num.insert(UInt8(carry % 256), at: 0)
            carry /= 256
        }
    }

    /// Divide a big number by a small int, return remainder
    private static func divMod(_ num: inout [UInt8], _ divisor: Int) -> Int {
        var remainder = 0
        for i in 0..<num.count {
            let v = remainder * 256 + Int(num[i])
            num[i] = UInt8(v / divisor)
            remainder = v % divisor
        }
        // Strip leading zeros
        while num.count > 1 && num[0] == 0 {
            num.removeFirst()
        }
        return remainder
    }

    /// Check if byte array is zero
    private static func isZero(_ num: [UInt8]) -> Bool {
        num.allSatisfy { $0 == 0 }
    }

    static func encode(_ data: Data) -> String {
        var payload = data
        let checksum = Crypto.hash256(payload).prefix(4)
        payload.append(contentsOf: checksum)

        // Count leading zeros
        var leadingZeros = 0
        for byte in payload {
            if byte == 0 { leadingZeros += 1 } else { break }
        }

        // Convert to base58 using byte-array arithmetic
        var num = Array(payload)
        var result = [Character]()

        while !isZero(num) {
            let rem = divMod(&num, 58)
            result.insert(alphabet[rem], at: 0)
        }

        for _ in 0..<leadingZeros {
            result.insert("1", at: 0)
        }

        return String(result)
    }

    static func decode(_ string: String) -> Data? {
        // Build reverse lookup
        var alphaMap = [Character: Int]()
        for (i, c) in alphabet.enumerated() {
            alphaMap[c] = i
        }

        // Convert from base58 to byte array using mulAdd
        var num: [UInt8] = [0]
        for char in string {
            guard let index = alphaMap[char] else { return nil }
            mulAdd(&num, 58, index)
        }

        // Handle leading '1's (= 0x00 bytes)
        var leadingOnes = 0
        for char in string {
            if char == "1" { leadingOnes += 1 } else { break }
        }

        var data = Data(repeating: 0, count: leadingOnes)
        // Skip leading zero in num if it's just padding
        if num.count == 1 && num[0] == 0 && leadingOnes > 0 {
            // num is zero, all leading ones
        } else {
            data.append(contentsOf: num)
        }

        // Verify checksum (last 4 bytes)
        guard data.count >= 4 else { return nil }
        let payload = Data(data[0..<(data.count - 4)])
        let checksum = Data(data[(data.count - 4)...])
        let expectedChecksum = Crypto.hash256(payload).prefix(4)

        guard checksum == expectedChecksum else { return nil }

        return payload
    }
}

// MARK: - Address derivation helper

struct AddressDerivation {

    /// BIP44/84 derivation paths
    /// Mainnet P2WPKH: m/84'/0'/0'/change/index
    /// Testnet P2WPKH: m/84'/1'/0'/change/index
    /// From xpub we derive: change/index (non-hardened)

    static func deriveAddresses(
        xpub: ExtendedPublicKey,
        change: UInt32 = 0,
        startIndex: UInt32 = 0,
        count: UInt32 = 20,
        isTestnet: Bool,
        taproot: Bool = false
    ) -> [(index: UInt32, address: String, publicKey: Data)] {
        var addresses: [(UInt32, String, Data)] = []

        guard let changeLevelKey = xpub.deriveChild(index: change) else { return [] }

        for i in startIndex..<(startIndex + count) {
            guard let childKey = changeLevelKey.deriveChild(index: i) else { continue }
            let address: String?
            if taproot {
                address = childKey.taprootAddress(isTestnet: isTestnet)
            } else {
                address = childKey.segwitAddress(isTestnet: isTestnet)
            }
            guard let addr = address else { continue }
            addresses.append((i, addr, childKey.key))
        }

        return addresses
    }

    /// Scan for used addresses with gap limit (BIP44 gap limit = 20)
    static func scanAddresses(
        xpub: ExtendedPublicKey,
        change: UInt32 = 0,
        isTestnet: Bool,
        gapLimit: Int = 20,
        checkUsed: (String) async -> Bool
    ) async -> [(index: UInt32, address: String, publicKey: Data)] {
        var usedAddresses: [(UInt32, String, Data)] = []
        var consecutiveUnused = 0
        var index: UInt32 = 0

        guard let changeLevelKey = xpub.deriveChild(index: change) else { return [] }

        while consecutiveUnused < gapLimit {
            guard let childKey = changeLevelKey.deriveChild(index: index),
                  let address = childKey.segwitAddress(isTestnet: isTestnet) else {
                index += 1
                continue
            }

            let used = await checkUsed(address)
            if used {
                usedAddresses.append((index, address, childKey.key))
                consecutiveUnused = 0
            } else {
                consecutiveUnused += 1
            }
            index += 1
        }

        return usedAddresses
    }

    /// Derive P2TR (Taproot) addresses using BIP86 path convention.
    /// From xpub at m/86'/coin_type'/0', we derive: change/index
    static func deriveTaprootAddresses(
        xpub: ExtendedPublicKey,
        change: UInt32 = 0,
        startIndex: UInt32 = 0,
        count: UInt32 = 20,
        isTestnet: Bool
    ) -> [(index: UInt32, address: String, publicKey: Data)] {
        var addresses: [(UInt32, String, Data)] = []

        guard let changeLevelKey = xpub.deriveChild(index: change) else { return [] }

        for i in startIndex..<(startIndex + count) {
            guard let childKey = changeLevelKey.deriveChild(index: i),
                  let address = childKey.taprootAddress(isTestnet: isTestnet) else { continue }
            addresses.append((i, address, childKey.key))
        }

        return addresses
    }
}
