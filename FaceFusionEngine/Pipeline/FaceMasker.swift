//
//  FaceMasker.swift
//  FaceFusionEngine
//
//  The swapper returns a hard-edged square. Pasting that back as-is leaves a
//  visible seam, so the crop is composited through a feathered mask that falls
//  off before the crop boundary.
//

import Foundation
import os

struct FaceMasker {

    /// Inset percentages applied before feathering, as (top, right, bottom, left).
    struct Padding {
        var top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0
        static let none = Padding()
    }

    /// The mask depends only on its parameters, not on image content, so it is
    /// built once and reused. This matters: the enhancer's 512px mask at the
    /// default blur needs a ~150-tap separable Gaussian, which is far too
    /// expensive to redo on every frame of a video.
    private struct MaskKey: Hashable {
        var size: Int
        var blur: Int          // quantised, so slider drags do not thrash the cache
        var padding: [Int]
    }
    private static let cache = OSAllocatedUnfairLock(initialState: [MaskKey: FloatMask]())

    /// A soft-edged rectangular mask covering the crop.
    ///
    /// - Parameter blur: 0...1. Scaled against the crop size to give the
    ///   feather radius, matching the reference's `face_mask_blur`.
    static func boxMask(size: Int,
                        blur: Double,
                        padding: Padding = .none) -> FloatMask {
        let key = MaskKey(size: size,
                          blur: Int((blur * 200).rounded()),
                          padding: [Int(padding.top), Int(padding.right),
                                    Int(padding.bottom), Int(padding.left)])
        if let cached = cache.withLock({ $0[key] }) { return cached }

        let mask = build(size: size, blur: blur, padding: padding)
        cache.withLock { storage in
            // Bounded: only a handful of (size, blur) pairs ever occur.
            if storage.count > 32 { storage.removeAll() }
            storage[key] = mask
        }
        return mask
    }

    private static func build(size: Int,
                              blur: Double,
                              padding: Padding) -> FloatMask {
        let blurAmount = Int(Double(size) * 0.5 * blur)
        // Always keep at least a one-pixel border so the edge never lands
        // exactly on the crop boundary.
        let blurArea = max(blurAmount / 2, 1)

        var mask = FloatMask(width: size, height: size, repeating: 1)

        let top = max(blurArea, Int(Double(size) * padding.top / 100))
        let bottom = max(blurArea, Int(Double(size) * padding.bottom / 100))
        let left = max(blurArea, Int(Double(size) * padding.left / 100))
        let right = max(blurArea, Int(Double(size) * padding.right / 100))

        for y in 0 ..< size {
            for x in 0 ..< size {
                let inside = y >= top && y < size - bottom && x >= left && x < size - right
                if !inside { mask.values[y * size + x] = 0 }
            }
        }

        guard blurAmount > 0 else { return mask }
        return mask.blurred(sigma: Float(blurAmount) * 0.25)
    }
}
