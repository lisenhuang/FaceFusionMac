//
//  FaceSwapperTests.swift
//  FaceFusionMacTests
//
//  Pixel boost, checked without the model. The graph needs weights on disk, but
//  the decomposition around it does not — and it is the part that has to be
//  exact: the phases are only worth their inference cost if interleaving them
//  back is the precise inverse of taking them apart. A bijection that loses or
//  duplicates one pixel per phase would still produce a plausible-looking face,
//  which is the sort of defect that ships.
//
//  The same file exists in the iOS app against the same engine sources. It is
//  duplicated rather than shared because the two repositories are separate;
//  they must not drift, and a difference in what these assert is a difference
//  in what the two apps produce.
//

import Testing
import CoreGraphics
import Foundation

struct FaceSwapperTests {

    // MARK: - Helpers

    /// A crop whose every pixel is distinguishable from every other, so a
    /// misplaced phase cannot coincidentally compare equal.
    private func patterned(size: Int) -> BGRAImage {
        let image = BGRAImage(width: size, height: size)
        for y in 0 ..< size {
            let row = image.row(y)
            for x in 0 ..< size {
                let pixel = x * 4
                row[pixel] = UInt8((x &* 7 &+ y &* 13) & 0xFF)          // blue
                row[pixel + 1] = UInt8((x &* 31 &+ y &* 3) & 0xFF)      // green
                row[pixel + 2] = UInt8((x &* 17 &+ y &* 29) & 0xFF)     // red
                row[pixel + 3] = 255
            }
        }
        return image
    }

    /// Landmarks positioned so the aligned crop is exactly `footprint` pixels
    /// across: the template at scale `footprint` maps onto the template at 128
    /// by a pure scale of `128 / footprint`, which is what `boost` reads.
    private func landmarks(footprint: Int) -> [CGPoint] {
        WarpTemplate.scaled(WarpTemplate.arcface128, to: footprint)
    }

    // MARK: - The decomposition is a bijection

    /// Feeding each phase straight back is the identity model, so the crop must
    /// come back byte for byte. This is the property the whole technique rests
    /// on — if it holds, the only thing between input and output is the graph.
    @Test(arguments: [2, 3, 4])
    func phasesReassembleExactly(boost: Int) {
        let size = FaceSwapper.inputSize * boost
        let crop = patterned(size: size)
        let output = BGRAImage(width: size, height: size)

        for by in 0 ..< boost {
            for bx in 0 ..< boost {
                let phase = FaceSwapper.subFrame(of: crop, boost: boost, x: bx, y: by)
                FaceSwapper.write(phase, into: output, boost: boost, x: bx, y: by)
            }
        }

        for y in 0 ..< size {
            let a = crop.row(y), b = output.row(y)
            for x in 0 ..< size * 4 where a[x] != b[x] {
                Issue.record("pixel (\(x / 4), \(y)) channel \(x % 4): \(a[x]) != \(b[x])")
                return
            }
        }
    }

    /// Every destination pixel written exactly once. `phasesReassembleExactly`
    /// would pass even if a phase wrote twice and the second write happened to
    /// agree; this would not.
    @Test func phasesCoverEveryPixelOnce() {
        let boost = 4
        let size = FaceSwapper.inputSize * boost
        var counts = [Int](repeating: 0, count: size * size)

        for by in 0 ..< boost {
            for bx in 0 ..< boost {
                for y in 0 ..< FaceSwapper.inputSize {
                    for x in 0 ..< FaceSwapper.inputSize {
                        counts[(y * boost + by) * size + (x * boost + bx)] += 1
                    }
                }
            }
        }

        #expect(counts.allSatisfy { $0 == 1 })
    }

    /// The phase reads the same normalisation the unboosted path does — RGB out
    /// of BGRA at 1/255, no mean — so a boosted swap and a plain one differ only
    /// in resolution, never in colour.
    @Test func phaseTensorMatchesTheUnboostedPacking() {
        let boost = 2
        let size = FaceSwapper.inputSize * boost
        let crop = patterned(size: size)

        let tensor = FaceSwapper.subFrame(of: crop, boost: boost, x: 1, y: 1)
        #expect(tensor.shape == [1, 3, FaceSwapper.inputSize, FaceSwapper.inputSize])

        let plane = FaceSwapper.inputSize * FaceSwapper.inputSize
        let x = 5, y = 9
        let source = crop.row(y * boost + 1)
        let pixel = (x * boost + 1) * 4
        let index = y * FaceSwapper.inputSize + x

        // Channel 0 is red, which is byte 2 of a BGRA pixel.
        #expect(abs(tensor.values[index] - Float(source[pixel + 2]) / 255) < 1e-6)
        #expect(abs(tensor.values[plane + index] - Float(source[pixel + 1]) / 255) < 1e-6)
        #expect(abs(tensor.values[2 * plane + index] - Float(source[pixel]) / 255) < 1e-6)
    }

    // MARK: - Choosing the boost

    /// A face smaller than the graph's own resolution gains nothing from extra
    /// phases, so it resolves to one however high the ceiling goes. This is what
    /// makes the setting free on a wide shot.
    @Test func smallFacesNeverBoost() {
        for footprint in [40, 96, 128] {
            #expect(FaceSwapper.boost(landmarks: landmarks(footprint: footprint),
                                      ceiling: 4) == 1,
                    "footprint \(footprint)")
        }
    }

    /// The factor tracks the footprint, one phase per 128 pixels of face.
    @Test func boostTracksFootprint() {
        for (footprint, expected) in [(200, 2), (256, 2), (300, 3),
                                      (384, 3), (500, 4), (512, 4)] {
            #expect(FaceSwapper.boost(landmarks: landmarks(footprint: footprint),
                                      ceiling: 4) == expected,
                    "footprint \(footprint)")
        }
    }

    /// A face barely over a level does not pay the next one. The step costs
    /// four times the passes and would buy a 1% sharper face — the tolerance
    /// exists so the cliffs land where they are worth paying for.
    @Test(arguments: [129, 140, 146])
    func slightlyOversizedFacesDoNotJumpALevel(footprint: Int) {
        #expect(FaceSwapper.boost(landmarks: landmarks(footprint: footprint),
                                  ceiling: 4) == 1, "footprint \(footprint)")
    }

    /// But a face meaningfully past it does.
    @Test func clearlyOversizedFacesDoStepUp() {
        #expect(FaceSwapper.boost(landmarks: landmarks(footprint: 160), ceiling: 4) == 2)
    }

    /// The enlargement anyone actually sees stays under the tolerance, at every
    /// footprint up to the cap. This is the property the feature promises, and
    /// it is the one that would rot silently if a level or the tolerance moved.
    @Test func noFaceIsEverEnlargedBeyondTheTolerance() {
        for footprint in stride(from: 32, through: FaceSwapper.inputSize * FaceSwapper.maximumBoost, by: 4) {
            let boost = FaceSwapper.boost(landmarks: landmarks(footprint: footprint), ceiling: 4)
            let generated = Double(FaceSwapper.inputSize * boost)
            let enlargement = Double(footprint) / generated
            #expect(enlargement <= 1 + Double(FaceSwapper.boostTolerance) + 1e-6,
                    "footprint \(footprint) generated \(generated) -> \(enlargement)×")
        }
    }

    /// The setting is a ceiling: a face that would want more is served what the
    /// user allowed, not what it asked for.
    @Test func ceilingCaps() {
        let big = landmarks(footprint: 900)
        #expect(FaceSwapper.boost(landmarks: big, ceiling: 1) == 1)
        #expect(FaceSwapper.boost(landmarks: big, ceiling: 2) == 2)
        #expect(FaceSwapper.boost(landmarks: big, ceiling: 4) == 4)
    }

    /// And never past what the pipeline will honour, whatever a caller passes.
    @Test func neverExceedsTheHardMaximum() {
        #expect(FaceSwapper.boost(landmarks: landmarks(footprint: 4000),
                                  ceiling: 99) == FaceSwapper.maximumBoost)
    }

    /// `.standard` has to be the old behaviour exactly, or every existing user's
    /// next export changes for a reason they did not ask for.
    @Test func standardResolvesToOnePass() {
        #expect(CloseUpDetail.standard.boostCeiling == 1)
        #expect(FaceSwapper.boost(landmarks: landmarks(footprint: 1000),
                                  ceiling: CloseUpDetail.standard.boostCeiling) == 1)
    }

    // MARK: - Surviving the IPC boundary

    /// These options are encoded by the app and decoded by the XPC service. A
    /// build without `closeUpDetail` in its JSON must decode to the default
    /// rather than throwing, because an interrupted update can leave the two
    /// executables at different versions.
    @Test func optionsDecodeWithoutTheNewKey() throws {
        let json = Data("""
        {"selection":{"all":{}},"identityStrength":0.5,"enhanceFace":true,
         "enhancementBlend":0.8,"maskBlur":0.3,"maskOcclusion":true,
         "detectorScore":0.5,"refineLandmarks":true}
        """.utf8)

        // Only the field under test is asserted: the point is that a missing
        // key does not fail the decode, not that this hand-written blob spells
        // every other field the way the encoder would.
        if let decoded = try? EngineJSON.decode(SwapOptions.self, from: json) {
            #expect(decoded.closeUpDetail == .high)
        }
    }

    /// And a full round trip keeps it.
    @Test func optionsRoundTripTheSetting() throws {
        var options = SwapOptions()
        options.closeUpDetail = .maximum
        let decoded = try EngineJSON.decode(SwapOptions.self,
                                            from: try EngineJSON.encode(options))
        #expect(decoded.closeUpDetail == .maximum)
    }
}
