// Keccak256.swift
// VeniceE2EE
//
// Ethereum-style Keccak-256 (original Keccak padding 0x01, not SHA3's 0x06).
// Used only to check that an attestation's `signing_address` is the address
// of its `signing_public_key`; the address is what TDX REPORTDATA commits to.

import Foundation

enum Keccak256 {
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    private static let rotations: [Int] = [
        0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14,
    ]
    private static let rate = 136

    static func hash(_ data: Data) -> Data {
        var state = [UInt64](repeating: 0, count: 25)
        var message = [UInt8](data)
        message.append(0x01)
        while message.count % rate != 0 { message.append(0) }
        message[message.count - 1] |= 0x80

        for blockStart in stride(from: 0, to: message.count, by: rate) {
            for i in 0..<(rate / 8) {
                var lane: UInt64 = 0
                for b in 0..<8 { lane |= UInt64(message[blockStart + i * 8 + b]) << (8 * UInt64(b)) }
                state[i] ^= lane
            }
            permute(&state)
        }
        var out = Data()
        for i in 0..<4 {
            for b in 0..<8 { out.append(UInt8((state[i] >> (8 * UInt64(b))) & 0xff)) }
        }
        return out
    }

    private static func rotl(_ x: UInt64, _ n: Int) -> UInt64 {
        n == 0 ? x : (x << UInt64(n)) | (x >> UInt64(64 - n))
    }

    private static func permute(_ a: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        var b = [UInt64](repeating: 0, count: 25)
        for round in 0..<24 {
            for x in 0..<5 { c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
                for y in 0..<5 { a[x + 5 * y] ^= d }
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(a[x + 5 * y], rotations[x + 5 * y])
                }
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    a[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }
            a[0] ^= roundConstants[round]
        }
    }

    /// Ethereum address (last 20 bytes of Keccak-256 of X‖Y) for a 65-byte uncompressed key.
    static func ethereumAddress(uncompressedPublicKey key: Data) -> Data? {
        guard key.count == 65, key.first == 0x04 else { return nil }
        return hash(key.dropFirst()).suffix(20)
    }
}
