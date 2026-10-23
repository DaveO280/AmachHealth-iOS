// Hex.swift
// VeniceE2EE
//
// Lowercase hex, as Venice's E2EE wire format requires.

import Foundation

extension Data {
    var hexString: String {
        var out = ""
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(Self.hexDigits[Int(byte >> 4)])
            out.append(Self.hexDigits[Int(byte & 0x0f)])
        }
        return out
    }

    private static let hexDigits = Array("0123456789abcdef")

    /// Parses hex (either case, optional `0x`). Nil on odd length or a non-hex char.
    init?(hex: String) {
        var s = Substring(hex)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        guard s.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    /// Little-endian unsigned integer at `offset` (TDX quotes are little-endian).
    func uintLE(at offset: Int, size: Int) -> Int {
        var value = 0
        for i in 0..<size {
            value |= Int(self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }

    /// Bounds-checked sub-range starting at `offset` relative to `startIndex`.
    func slice(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        let start = startIndex + offset
        return Data(self[start..<(start + length)])
    }
}
