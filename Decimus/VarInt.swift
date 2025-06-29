// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

enum VarIntError: Error {
    case invalidLength
    case invalidValue
}

struct VarInt: ExpressibleByIntegerLiteral, Equatable {
    typealias IntegerLiteralType = UInt64
    let value: IntegerLiteralType

    init(integerLiteral value: IntegerLiteralType) {
        self.value = value
    }

    init(_ value: any BinaryInteger) {
        self.init(integerLiteral: UInt64(value))
    }

    func toWireFormat() -> Data {
        var data = Data()
        self.toWireFormat(&data)
        return data
    }

    func toWireFormat(_ buffer: inout Data) {
        // 6 bits
        if self.value <= 0x3F {
            buffer.append(UInt8(self.value))
            return
        }

        // 14 bits
        if self.value <= 0x3FFF {
            buffer.append(UInt8(0x40 | (self.value >> 8)))
            buffer.append(UInt8(self.value & 0xFF))
            return
        }

        // 30 bits
        if self.value <= 0x3FFFFFFF {
            buffer.append(UInt8(0x80 | (self.value >> 24)))
            buffer.append(UInt8((self.value >> 16) & 0xFF))
            buffer.append(UInt8((self.value >> 8) & 0xFF))
            buffer.append(UInt8(self.value & 0xFF))
            return
        }

        // 62 bits
        buffer.append(UInt8(0xC0 | (self.value >> 56)))
        buffer.append(UInt8((self.value >> 48) & 0xFF))
        buffer.append(UInt8((self.value >> 40) & 0xFF))
        buffer.append(UInt8((self.value >> 32) & 0xFF))
        buffer.append(UInt8((self.value >> 24) & 0xFF))
        buffer.append(UInt8((self.value >> 16) & 0xFF))
        buffer.append(UInt8((self.value >> 8) & 0xFF))
        buffer.append(UInt8(self.value & 0xFF))
    }

    init(wireFormat data: Data, bytesRead: inout Int) throws {
        guard !data.isEmpty else {
            throw VarIntError.invalidLength
        }

        let data = data.advanced(by: bytesRead)
        let firstByte = data[0]
        let length = 1 << (firstByte >> 6)

        guard data.count >= length else {
            throw VarIntError.invalidLength
        }

        switch length {
        case 1:
            self.value = UInt64(firstByte & 0x3F)
        case 2:
            self.value = (UInt64(firstByte & 0x3F) << 8) |
                UInt64(data[1])
        case 4:
            self.value = (UInt64(firstByte & 0x3F) << 24) |
                (UInt64(data[1]) << 16) |
                (UInt64(data[2]) << 8) |
                UInt64(data[3])
        case 8:
            let first = (UInt64(firstByte & 0x3F) << 56)
            self.value = first |
                (UInt64(data[1]) << 48) |
                (UInt64(data[2]) << 40) |
                (UInt64(data[3]) << 32) |
                (UInt64(data[4]) << 24) |
                (UInt64(data[5]) << 16) |
                (UInt64(data[6]) << 8) |
                UInt64(data[7])
        default:
            throw VarIntError.invalidLength
        }
        bytesRead += length
    }
}

extension VarInt: CustomStringConvertible {
    var description: String {
        return value.description
    }
}
