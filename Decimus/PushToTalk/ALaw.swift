enum AudioCodec {
    static func aLawCompand(input: UnsafePointer<UInt16>, output: UnsafeMutablePointer<UInt8>, length: Int) {
        for index in 0..<length {
            output[index] = aLawCompand(input[index])
        }
    }

    static func aLawExpand(input: UnsafePointer<UInt8>, output: UnsafeMutablePointer<UInt16>, length: Int) {
        for index in 0..<length {
            output[index] = aLawExpand(input[index])
        }
    }

    private static func aLawCompand(_ uSample: UInt16) -> UInt8 {
        var sample = Int16(bitPattern: uSample)
        var exponent: Int16 = 0
        var mantissa: UInt16 = 0
        var sign: UInt16 = 0

        // Get the sign
        if sample >= 0 {
            sign = 0x80
        } else {
            sample = -sample
        }

        // Find the first bit set in our 13 bits
        var bit = 0
        for index in 0..<7 where ((sample << index) & 0x4000) != 0 {
            bit = index
            break
        }

        exponent = Int16(7 - bit)

        // Get our mantissa (abcd)
        if exponent == 0 {
            mantissa = UInt16((sample >> 4) & 0x0F)
        } else {
            mantissa = UInt16((sample >> (Int16(exponent) + 3)) & 0x0F)
            exponent <<= 4
        }

        return UInt8((sign + UInt16(exponent) + mantissa) ^ 0x55)
    }

    private static func aLawExpand(_ sample: UInt8) -> UInt16 {
        var sample = sample ^ 0xD5

        let sign = UInt16(sample & 0x80)
        let exponent = UInt8((sample & 0x70) >> 4)
        var mantissa = UInt16(sample & 0x0F) << 1

        if exponent == 0 {
            mantissa = (mantissa + 0x0001) << 2
        } else {
            mantissa = (mantissa + 0x0021) << (UInt16(exponent) + 1)
        }

        return sign != 0 ? UInt16(bitPattern: -Int16(mantissa)) : mantissa
    }
}
