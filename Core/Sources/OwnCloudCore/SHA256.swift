import Foundation

/// A minimal, dependency-free SHA-256 (FIPS 180-4).
///
/// The package is deliberately Foundation-only and Linux-buildable (see
/// `Package.swift`), so it cannot lean on CryptoKit (Apple-only) or pull in
/// swift-crypto and its ASN.1 tree just to hash a PKCE code verifier. This is the
/// one primitive the oCIS OIDC sign-in flow (Task 7.8) needs: PKCE S256 hashes the
/// code verifier before it goes on the wire. Correctness is pinned to the
/// published FIPS/RFC vectors in `SHA256Tests`.
public enum SHA256 {

    /// The 64 round constants: first 32 bits of the fractional parts of the cube
    /// roots of the first 64 primes.
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// The 32-byte digest of `message`.
    public static func hash(_ message: [UInt8]) -> [UInt8] {
        // Initial hash values: fractional parts of the square roots of the first 8 primes.
        var h0: UInt32 = 0x6a09e667, h1: UInt32 = 0xbb67ae85, h2: UInt32 = 0x3c6ef372, h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f, h5: UInt32 = 0x9b05688c, h6: UInt32 = 0x1f83d9ab, h7: UInt32 = 0x5be0cd19

        // Pad: append 0x80, then zeros, then the 64-bit big-endian bit length,
        // so the total is a multiple of 64 bytes.
        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var w = [UInt32](repeating: 0, count: 64)
        for blockStart in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let j = blockStart + i * 4
                w[i] = (UInt32(padded[j]) << 24) | (UInt32(padded[j + 1]) << 16)
                     | (UInt32(padded[j + 2]) << 8) | UInt32(padded[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                h = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }

            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d
            h4 = h4 &+ e; h5 = h5 &+ f; h6 = h6 &+ g; h7 = h7 &+ h
        }

        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
            digest.append(UInt8((word >> 24) & 0xff))
            digest.append(UInt8((word >> 16) & 0xff))
            digest.append(UInt8((word >> 8) & 0xff))
            digest.append(UInt8(word & 0xff))
        }
        return digest
    }

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
