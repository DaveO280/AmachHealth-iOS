// Keccak256.swift
// AmachHealth
//
// Pure Swift implementation of Keccak-256 — Ethereum's hash function.
// This is NOT the same as NIST SHA3-256 (different padding byte: 0x01 vs 0x06).
//
// No external dependencies — CryptoKit uses NIST SHA3, which is incompatible.
// Required for on-chain searchTag / eventHash computation that must match
// the web app's ethers.js keccak256 calls.

import Foundation

// MARK: - Keccak256

enum Keccak256 {

    // MARK: - Public

    /// Hash raw bytes using Keccak-256.  Returns a 32-byte digest.
    static func hash(_ input: [UInt8]) -> [UInt8] {
        var state = [UInt64](repeating: 0, count: 25)
        let rateBytes = 136  // (1600 - 512) / 8

        // Pad the message: append 0x01, zero-fill to rate boundary, set last bit.
        var msg = input
        msg.append(0x01)
        while msg.count % rateBytes != 0 { msg.append(0x00) }
        msg[msg.count - 1] |= 0x80

        // Absorb
        var offset = 0
        while offset < msg.count {
            for i in 0..<17 {  // rate / 8 = 136 / 8 = 17 lanes
                let b = offset + i * 8
                let lane = UInt64(msg[b])
                    | UInt64(msg[b + 1]) << 8
                    | UInt64(msg[b + 2]) << 16
                    | UInt64(msg[b + 3]) << 24
                    | UInt64(msg[b + 4]) << 32
                    | UInt64(msg[b + 5]) << 40
                    | UInt64(msg[b + 6]) << 48
                    | UInt64(msg[b + 7]) << 56
                state[i] ^= lane
            }
            keccakF1600(&state)
            offset += rateBytes
        }

        // Squeeze: first 32 bytes (4 lanes, little-endian)
        var output = [UInt8](repeating: 0, count: 32)
        for i in 0..<4 {
            let lane = state[i]
            output[i * 8 + 0] = UInt8(lane & 0xff)
            output[i * 8 + 1] = UInt8((lane >> 8)  & 0xff)
            output[i * 8 + 2] = UInt8((lane >> 16) & 0xff)
            output[i * 8 + 3] = UInt8((lane >> 24) & 0xff)
            output[i * 8 + 4] = UInt8((lane >> 32) & 0xff)
            output[i * 8 + 5] = UInt8((lane >> 40) & 0xff)
            output[i * 8 + 6] = UInt8((lane >> 48) & 0xff)
            output[i * 8 + 7] = UInt8((lane >> 56) & 0xff)
        }
        return output
    }

    // MARK: - Keccak-f[1600]

    private static let RC: [UInt64] = [
        0x0000000000000001, 0x0000000000008082,
        0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001,
        0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088,
        0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B,
        0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080,
        0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080,
        0x0000000080000001, 0x8000000080008008
    ]

    // Rotation offsets r[x][y] — state lane at (x, y) in the 5×5 matrix.
    // Index as ROT[x][y].
    private static let ROT: [[Int]] = [
        [ 0, 36,  3, 41, 18],
        [ 1, 44, 10, 45,  2],
        [62,  6, 43, 15, 61],
        [28, 55, 25, 21, 56],
        [27, 20, 39,  8, 14]
    ]

    /// Keccak-f[1600] permutation — 24 rounds of θ ρ π χ ι.
    /// State is a flat 25-element array; logical (x,y) maps to index x + 5*y.
    private static func keccakF1600(_ state: inout [UInt64]) {
        for round in 0..<24 {

            // θ — column-parity mixing
            var C = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                C[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            var D = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                D[x] = C[(x + 4) % 5] ^ rotl64(C[(x + 1) % 5], 1)
            }
            for x in 0..<5 {
                for y in 0..<5 { state[x + 5 * y] ^= D[x] }
            }

            // ρ + π — rotation and lane permutation
            var B = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    // π maps (x,y) → (y, (2x+3y) mod 5)
                    B[y + 5 * ((2 * x + 3 * y) % 5)] = rotl64(state[x + 5 * y], ROT[x][y])
                }
            }

            // χ — nonlinear mixing
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] = B[x + 5 * y] ^ ((~B[(x + 1) % 5 + 5 * y]) & B[(x + 2) % 5 + 5 * y])
                }
            }

            // ι — round constant injection
            state[0] ^= RC[round]
        }
    }

    private static func rotl64(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }
}
