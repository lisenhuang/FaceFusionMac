//
//  Float16Bits.swift
//  FaceFusionEngine
//
//  Widening IEEE-754 binary16 to binary32 without the `Float16` type.
//
//  Swift declares `Float16` only where the hardware has the instructions for
//  it, which on macOS means arm64 and not x86_64. A Release build targets
//  `generic/platform=macOS` and so compiles both slices, and the x86_64 one
//  fails the moment `Float16` is named — which is unconditional here, because
//  `inswapper_128_fp16` hands back fp16 tensors and `emap` is stored as fp16
//  inside the graph.
//
//  Doing the widening in integer arithmetic compiles everywhere and is exactly
//  lossless: every binary16 value has an exact binary32 counterpart, including
//  the subnormals, which the wider exponent range turns into ordinary
//  normalised numbers.
//

import Foundation

extension Float {

    /// Widens one IEEE-754 binary16 value from its raw bits.
    ///
    /// binary16 is 1 sign bit, 5 exponent bits biased by 15, and 10 mantissa
    /// bits; binary32 is 1, 8 biased by 127, and 23. So in the ordinary case
    /// the sign moves up 16 places, the mantissa up 13, and the exponent is
    /// rebiased by 112. Both ends of the exponent range mean something else
    /// and are handled separately.
    init(float16Bits bits: UInt16) {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits >> 10) & 0x1F
        let mantissa = UInt32(bits) & 0x03FF

        switch exponent {
        case 0:
            guard mantissa != 0 else {
                self = Float(bitPattern: sign)          // ±0
                return
            }
            // Subnormal as a binary16, but an ordinary normalised number as a
            // binary32 — the wider exponent has room for it. Shift the
            // mantissa up until its leading 1 reaches the implicit-bit
            // position, paying one off the exponent per shift.
            var shifted = mantissa
            var shifts: UInt32 = 0
            while shifted & 0x0400 == 0 {
                shifted <<= 1
                shifts += 1
            }
            shifted &= 0x03FF                           // drop the now-implicit 1
            // (127 - 15 + 1) - shifts, folded so it cannot underflow UInt32.
            self = Float(bitPattern: sign | ((113 - shifts) << 23) | (shifted << 13))

        case 0x1F:
            // Infinity or NaN. An all-ones exponent stays all-ones, and the
            // mantissa carries any NaN payload across unchanged.
            self = Float(bitPattern: sign | (0xFF << 23) | (mantissa << 13))

        default:
            // 127 - 15 = 112, added rather than subtracted so that an exponent
            // below 15 cannot wrap the unsigned arithmetic.
            self = Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
        }
    }
}
