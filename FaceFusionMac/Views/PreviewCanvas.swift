//
//  PreviewCanvas.swift
//  FaceFusionMac
//
//  Shows the current frame, the faces the engine can see, and lets the user
//  click one to choose which face gets replaced.
//

import SwiftUI
import CoreVideo

struct PreviewCanvas: View {
    @Environment(AppModel.self) private var model

    private var displayedBuffer: CVPixelBuffer? {
        if model.showsOriginal { return model.previewFrame }
        return model.previewResult ?? model.previewFrame
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black.opacity(0.85))

                if let buffer = displayedBuffer, let image = PixelSurface.makeCGImage(from: buffer) {
                    let frameSize = CGSize(width: CVPixelBufferGetWidth(buffer),
                                           height: CVPixelBufferGetHeight(buffer))
                    let rect = fittedRect(for: frameSize, in: geometry.size)

                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .clipShape(.rect(cornerRadius: 14))

                    FaceOverlay(faces: model.previewFaces,
                                selected: model.selectedFaceIndices,
                                frameSize: frameSize,
                                rect: rect)
                        .allowsHitTesting(false)

                    // Clicking picks the nearest face — or, while choosing
                    // faces, ticks whoever was clicked. Coordinates are
                    // normalised so the choice survives a window resize.
                    Color.clear
                        .contentShape(.rect)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .onTapGesture { location in
                            let normalized = CGPoint(x: location.x / max(rect.width, 1),
                                                     y: location.y / max(rect.height, 1))
                            model.selectFace(atNormalized: normalized)
                        }
                } else {
                    placeholder
                }

                if model.isPreviewing {
                    VStack {
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Previewing…").font(.caption)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: .capsule)
                            .padding(12)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 34, weight: .thin))
            Text("Choose a video or photo to see it here")
                .font(.callout)
        }
        .foregroundStyle(.white.opacity(0.35))
    }

    /// Aspect-fit the frame inside the available space.
    private func fittedRect(for frameSize: CGSize, in available: CGSize) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        let scale = min(available.width / frameSize.width, available.height / frameSize.height)
        let size = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        return CGRect(x: (available.width - size.width) / 2,
                      y: (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

// MARK: - Face boxes

/// Draws a box per detected face, highlighting the ones that will be replaced.
///
/// Which those are is decided by `AppModel.selectedFaceIndices` rather than
/// here: the rule used to be written out twice, and matching by identity is
/// not a question the view can answer at all — it has boxes, not identities.
private struct FaceOverlay: View {
    var faces: [DetectedFace]
    var selected: Set<Int>
    var frameSize: CGSize
    var rect: CGRect

    var body: some View {
        Canvas { context, _ in
            let scaleX = rect.width / max(frameSize.width, 1)
            let scaleY = rect.height / max(frameSize.height, 1)

            for face in faces {
                let box = CGRect(x: rect.minX + face.box.x * scaleX,
                                 y: rect.minY + face.box.y * scaleY,
                                 width: face.box.width * scaleX,
                                 height: face.box.height * scaleY)
                let active = selected.contains(face.index)
                let path = Path(roundedRect: box, cornerRadius: 6)
                context.stroke(path,
                               with: .color(active ? .accentColor : .white.opacity(0.35)),
                               lineWidth: active ? 2.5 : 1.2)
            }
        }
    }
}
