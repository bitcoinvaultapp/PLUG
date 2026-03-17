import Foundation

// MARK: - BIP157/BIP158 Compact Block Filter Scanning
// Golomb-Rice Coded Set (GCS) filter matching
// Uses SipHash-2-4 for element hashing

struct BlockFilterService {

    // GCS parameters per BIP158
    static let P: UInt8 = 19            // false positive rate 2^-19
    static let M: UInt64 = 784_931      // filter parameter

    // MARK: - SipHash-2-4

    /// SipHash-2-4 keyed hash function used in BIP158 filter matching
    static func sipHash(key: Data, data: Data) -> UInt64 {
        guard key.count >= 16 else { return 0 }

        // Parse 128-bit key as two little-endian UInt64s
        var k0: UInt64 = 0
        var k1: UInt64 = 0
        key.withUnsafeBytes { ptr in
            k0 = ptr.load(fromByteOffset: 0, as: UInt64.self).littleEndian
            k1 = ptr.load(fromByteOffset: 8, as: UInt64.self).littleEndian
        }

        var v0: UInt64 = k0 ^ 0x736f6d6570736575
        var v1: UInt64 = k1 ^ 0x646f72616e646f6d
        var v2: UInt64 = k0 ^ 0x6c7967656e657261
        var v3: UInt64 = k1 ^ 0x7465646279746573

        let length = data.count
        let blocks = length / 8

        // Compress rounds
        func sipRound() {
            v0 = v0 &+ v1
            v1 = rotateLeft(v1, by: 13)
            v1 ^= v0
            v0 = rotateLeft(v0, by: 32)
            v2 = v2 &+ v3
            v3 = rotateLeft(v3, by: 16)
            v3 ^= v2
            v0 = v0 &+ v3
            v3 = rotateLeft(v3, by: 21)
            v3 ^= v0
            v2 = v2 &+ v1
            v1 = rotateLeft(v1, by: 17)
            v1 ^= v2
            v2 = rotateLeft(v2, by: 32)
        }

        // Process 8-byte blocks
        data.withUnsafeBytes { ptr in
            for i in 0..<blocks {
                let m = ptr.load(fromByteOffset: i * 8, as: UInt64.self).littleEndian
                v3 ^= m
                sipRound()
                sipRound()
                v0 ^= m
            }
        }

        // Process remaining bytes + length
        var last: UInt64 = UInt64(length & 0xff) << 56
        let remaining = length - (blocks * 8)
        if remaining > 0 {
            data.withUnsafeBytes { ptr in
                let offset = blocks * 8
                for i in 0..<remaining {
                    last |= UInt64(ptr.load(fromByteOffset: offset + i, as: UInt8.self)) << (i * 8)
                }
            }
        }

        v3 ^= last
        sipRound()
        sipRound()
        v0 ^= last

        // Finalization
        v2 ^= 0xff
        sipRound()
        sipRound()
        sipRound()
        sipRound()

        return v0 ^ v1 ^ v2 ^ v3
    }

    private static func rotateLeft(_ value: UInt64, by amount: UInt64) -> UInt64 {
        (value << amount) | (value >> (64 - amount))
    }

    // MARK: - GCS Bit Reader

    private struct BitReader {
        let data: Data
        var byteOffset: Int = 0
        var bitOffset: UInt8 = 0

        mutating func readBit() -> UInt64? {
            guard byteOffset < data.count else { return nil }
            let bit = UInt64((data[byteOffset] >> (7 - bitOffset)) & 1)
            bitOffset += 1
            if bitOffset == 8 {
                bitOffset = 0
                byteOffset += 1
            }
            return bit
        }

        /// Read unary-encoded value (count of 1-bits before first 0-bit)
        mutating func readUnary() -> UInt64? {
            var count: UInt64 = 0
            while let bit = readBit() {
                if bit == 0 {
                    return count
                }
                count += 1
            }
            return nil
        }

        /// Read P bits as a value
        mutating func readBits(_ count: UInt8) -> UInt64? {
            var value: UInt64 = 0
            for _ in 0..<count {
                guard let bit = readBit() else { return nil }
                value = (value << 1) | bit
            }
            return value
        }
    }

    // MARK: - Filter Matching

    /// Check if any of our scripts match the compact block filter
    static func matchFilter(filterData: Data, scripts: [Data], blockHash: Data) -> Bool {
        guard !scripts.isEmpty, filterData.count > 4 else { return false }

        // First bytes encode N (number of elements) as VarInt
        guard let (n, nBytesRead) = VarInt.decode(filterData, offset: 0) else {
            return false
        }
        guard n > 0 else { return false }

        let filterBody = filterData.suffix(from: nBytesRead)

        // SipHash key is first 16 bytes of block hash
        let sipKey = blockHash.prefix(16)

        // Hash our scripts
        let f = n * M
        var targetHashes = scripts.map { script -> UInt64 in
            let h = sipHash(key: sipKey, data: script)
            return fastReduce(h, f: f)
        }
        targetHashes.sort()

        // Decode GCS and match
        var reader = BitReader(data: filterBody)
        var lastValue: UInt64 = 0
        var targetIdx = 0

        for _ in 0..<n {
            guard targetIdx < targetHashes.count else { break }

            // Read Golomb-Rice encoded delta
            guard let quotient = reader.readUnary() else { return false }
            guard let remainder = reader.readBits(P) else { return false }

            let delta = (quotient << UInt64(P)) | remainder
            lastValue = lastValue &+ delta

            // Check against sorted target hashes
            while targetIdx < targetHashes.count && targetHashes[targetIdx] < lastValue {
                targetIdx += 1
            }

            if targetIdx < targetHashes.count && targetHashes[targetIdx] == lastValue {
                return true
            }
        }

        return false
    }

    /// Fast modular reduction without division: (value * f) >> 64
    private static func fastReduce(_ value: UInt64, f: UInt64) -> UInt64 {
        let (_, high) = value.multipliedFullWidth(by: f)
        return high
    }

    // MARK: - Network

    /// Fetch compact block filter for a given block hash from mempool API
    static func fetchFilter(blockHash: String) async throws -> Data {
        let baseURL = NetworkConfig.shared.mempoolBaseURL
        guard let url = URL(string: "\(baseURL)/block/\(blockHash)/filter") else {
            throw FilterError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw FilterError.networkError
        }

        // Response is hex-encoded filter
        guard let hexString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let filterData = Data(hex: hexString) else {
            throw FilterError.decodingError
        }

        return filterData
    }

    /// Scan a range of blocks for transactions matching our scripts
    static func scanBlocks(startHeight: Int, endHeight: Int, scripts: [Data]) async -> [Int] {
        guard !scripts.isEmpty, startHeight <= endHeight else { return [] }

        var matchingHeights: [Int] = []

        for height in startHeight...endHeight {
            do {
                let blockHash = try await MempoolAPI.shared.getBlockHash(height: height)
                let hashTrimmed = blockHash.trimmingCharacters(in: .whitespacesAndNewlines)

                guard let blockHashData = Data(hex: hashTrimmed) else { continue }

                let filterData = try await fetchFilter(blockHash: hashTrimmed)

                if matchFilter(filterData: filterData, scripts: scripts, blockHash: blockHashData) {
                    matchingHeights.append(height)
                }
            } catch {
                continue // Skip blocks we can't fetch
            }
        }

        return matchingHeights
    }

    // MARK: - Errors

    enum FilterError: LocalizedError {
        case invalidURL
        case networkError
        case decodingError

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid filter URL"
            case .networkError: return "Network error"
            case .decodingError: return "Filter decoding error"
            }
        }
    }
}
