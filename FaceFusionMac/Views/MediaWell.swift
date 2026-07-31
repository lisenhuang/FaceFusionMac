//
//  MediaWell.swift
//  FaceFusionMac
//
//  The drop targets for the source face and the target video.
//

import SwiftUI
import UniformTypeIdentifiers

struct MediaWell<Thumbnail: View>: View {
    var title: String
    var systemImage: String
    var hint: String
    var isFilled: Bool
    var caption: String?
    var accepted: [UTType]
    var onChoose: () -> Void
    var onClear: () -> Void
    var onDrop: (URL) -> Void
    @ViewBuilder var thumbnail: () -> Thumbnail

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isFilled {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            }

            Button(action: onChoose) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(.quaternary.opacity(isTargeted ? 0.6 : 0.28))

                    if isFilled {
                        thumbnail()
                            .clipShape(.rect(cornerRadius: 11))
                    } else {
                        VStack(spacing: 7) {
                            Image(systemName: systemImage)
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(8)
                    }

                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                      style: StrokeStyle(lineWidth: isTargeted ? 2 : 1,
                                                         dash: isFilled ? [] : [5, 4]))
                }
                .frame(height: 116)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in onDrop(url) }
                }
                return true
            }

            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
