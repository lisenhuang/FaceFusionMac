//
//  Geometry.swift
//  FaceFusionEngine
//
//  Face alignment maths.
//
//  Every model in the pipeline expects a face cropped and rotated into a
//  canonical pose. The canonical poses are five key points ("warp templates")
//  expressed in units of the crop size, and the mapping onto them is a
//  similarity transform: uniform scale, rotation and translation, no shear.
//

import Foundation
import CoreGraphics

/// Canonical five-point layouts, normalised to the crop size.
/// Values are the templates used by FaceFusion, which in turn inherits them
/// from InsightFace's alignment conventions.
enum WarpTemplate {
    /// Used by ArcFace when encoding identity, at 112x112.
    static let arcface112v2: [CGPoint] = [
        CGPoint(x: 0.34191607, y: 0.46157411),
        CGPoint(x: 0.65653393, y: 0.45983393),
        CGPoint(x: 0.50022500, y: 0.64050536),
        CGPoint(x: 0.37097589, y: 0.82469196),
        CGPoint(x: 0.63151696, y: 0.82325089),
    ]

    /// Used by inswapper, at 128x128. Note this is not a rescaled 112 template.
    static let arcface128: [CGPoint] = [
        CGPoint(x: 0.36167656, y: 0.40387734),
        CGPoint(x: 0.63696719, y: 0.40235469),
        CGPoint(x: 0.50019687, y: 0.56044219),
        CGPoint(x: 0.38710391, y: 0.72160547),
        CGPoint(x: 0.61507734, y: 0.72034453),
    ]

    /// Used by GFPGAN and other restorers, at 512x512.
    static let ffhq512: [CGPoint] = [
        CGPoint(x: 0.37691676, y: 0.46864664),
        CGPoint(x: 0.62285697, y: 0.46912813),
        CGPoint(x: 0.50123859, y: 0.61331904),
        CGPoint(x: 0.39308822, y: 0.72541100),
        CGPoint(x: 0.61150205, y: 0.72490465),
    ]

    static func scaled(_ template: [CGPoint], to size: Int) -> [CGPoint] {
        let s = CGFloat(size)
        return template.map { CGPoint(x: $0.x * s, y: $0.y * s) }
    }
}

enum Geometry {

    /// Least-squares similarity transform mapping `source` onto `target`.
    ///
    /// This is the closed form of the 2-D Procrustes problem, and is what
    /// OpenCV's `estimateAffinePartial2D` converges to. The reference pipeline
    /// calls it with a RANSAC reprojection threshold of 100px across only five
    /// points, which never rejects an inlier, so the plain least-squares
    /// solution matches it while staying deterministic.
    ///
    /// Solving for `[[a, -b], [b, a]]` plus a translation:
    ///     a = Σ(xᵢuᵢ + yᵢvᵢ) / Σ(xᵢ² + yᵢ²)
    ///     b = Σ(xᵢvᵢ − yᵢuᵢ) / Σ(xᵢ² + yᵢ²)
    /// over points centred on their respective means.
    static func similarityTransform(from source: [CGPoint],
                                    to target: [CGPoint]) -> CGAffineTransform {
        precondition(source.count == target.count && !source.isEmpty)
        let n = CGFloat(source.count)

        let srcMean = source.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / n, y: $0.y + $1.y / n)
        }
        let dstMean = target.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / n, y: $0.y + $1.y / n)
        }

        var numeratorA: CGFloat = 0   // Σ(xu + yv)
        var numeratorB: CGFloat = 0   // Σ(xv − yu)
        var denominator: CGFloat = 0  // Σ(x² + y²)

        for i in 0 ..< source.count {
            let x = source[i].x - srcMean.x
            let y = source[i].y - srcMean.y
            let u = target[i].x - dstMean.x
            let v = target[i].y - dstMean.y
            numeratorA += x * u + y * v
            numeratorB += x * v - y * u
            denominator += x * x + y * y
        }

        guard denominator > .ulpOfOne else {
            return CGAffineTransform(translationX: dstMean.x - srcMean.x,
                                     y: dstMean.y - srcMean.y)
        }

        let a = numeratorA / denominator
        let b = numeratorB / denominator

        // CGAffineTransform applies x' = a·x + c·y + tx, y' = b·x + d·y + ty,
        // so a rotation-and-scale block is (a, b, -b, a).
        let tx = dstMean.x - (a * srcMean.x - b * srcMean.y)
        let ty = dstMean.y - (b * srcMean.x + a * srcMean.y)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    /// The transform taking a face in image space onto a canonical template.
    static func alignmentTransform(landmarks: [CGPoint],
                                   template: [CGPoint],
                                   cropSize: Int) -> CGAffineTransform {
        similarityTransform(from: landmarks,
                            to: WarpTemplate.scaled(template, to: cropSize))
    }

    /// A pure scale-and-translate transform, as used by the 68-point landmarker.
    static func translationTransform(scale: CGFloat, translation: CGPoint) -> CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: translation.x, ty: translation.y)
    }

    static func apply(_ t: CGAffineTransform, to point: CGPoint) -> CGPoint {
        CGPoint(x: t.a * point.x + t.c * point.y + t.tx,
                y: t.b * point.x + t.d * point.y + t.ty)
    }

    static func apply(_ t: CGAffineTransform, to points: [CGPoint]) -> [CGPoint] {
        points.map { apply(t, to: $0) }
    }

    /// Axis-aligned bounds of a rectangle after transformation.
    static func transformedBounds(width: Int, height: Int,
                                  by t: CGAffineTransform) -> CGRect {
        let corners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: CGFloat(width), y: 0),
            CGPoint(x: CGFloat(width), y: CGFloat(height)),
            CGPoint(x: 0, y: CGFloat(height)),
        ].map { apply(t, to: $0) }

        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Reduces the 68-point constellation to the five points the swapper wants:
    /// the two eye centroids, the nose tip, and the mouth corners.
    static func fivePoints(from landmarks68: [CGPoint]) -> [CGPoint] {
        precondition(landmarks68.count >= 68)
        func centroid(_ range: Range<Int>) -> CGPoint {
            var sum = CGPoint.zero
            for i in range { sum.x += landmarks68[i].x; sum.y += landmarks68[i].y }
            let n = CGFloat(range.count)
            return CGPoint(x: sum.x / n, y: sum.y / n)
        }
        return [
            centroid(36 ..< 42),   // left eye
            centroid(42 ..< 48),   // right eye
            landmarks68[30],       // nose tip
            landmarks68[48],       // left mouth corner
            landmarks68[54],       // right mouth corner
        ]
    }
}
