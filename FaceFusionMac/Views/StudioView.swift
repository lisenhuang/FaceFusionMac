//
//  StudioView.swift
//  FaceFusionMac
//
//  The main workspace: pick a face, pick a video, judge the result on a single
//  frame, then export.
//

import SwiftUI
import UniformTypeIdentifiers

struct StudioView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 0) {
            sidebar
                .frame(width: 292)
                .background(.regularMaterial)

            Divider()

            VStack(spacing: 0) {
                PreviewCanvas()
                    .padding(16)

                scrubber
                bottomBar
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await model.handleDrop(url) }
            }
            return true
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        @Bindable var model = model

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MediaWell(title: "SOURCE FACE",
                          systemImage: "person.crop.square",
                          hint: "Drop a photo\nor click to choose",
                          isFilled: model.sourceBuffer != nil,
                          caption: sourceCaption,
                          accepted: [.image],
                          onChoose: { model.chooseSource() },
                          onClear: { model.clearSource() },
                          onDrop: { url in Task { await model.setSource(url) } }) {
                    if let buffer = model.sourceBuffer,
                       let image = PixelSurface.makeCGImage(from: buffer) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }

                MediaWell(title: "TARGET VIDEO",
                          systemImage: "film",
                          hint: "Drop a video\nor click to choose",
                          isFilled: model.targetURL != nil,
                          caption: targetCaption,
                          accepted: [.movie],
                          onChoose: { model.chooseTarget() },
                          onClear: { model.clearTarget() },
                          onDrop: { url in Task { await model.setTarget(url) } }) {
                    if let buffer = model.previewFrame,
                       let image = PixelSurface.makeCGImage(from: buffer) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }

                Divider()

                settings

                Spacer(minLength: 0)

                engineBadge
            }
            .padding(18)
        }
    }

    private var sourceCaption: String? {
        guard model.sourceBuffer != nil else { return nil }
        if model.sourceFace == nil {
            return model.sourceFaceCount == 0
                ? "No face found — try a clearer, front-facing photo."
                : "Encoding…"
        }
        return model.sourceFaceCount > 1
            ? "Using the largest of \(model.sourceFaceCount) faces."
            : "Face ready."
    }

    private var targetCaption: String? {
        guard let info = model.targetInfo else { return nil }
        let duration = Duration.seconds(info.durationSeconds)
            .formatted(.time(pattern: .minuteSecond))
        return "\(Int(info.displaySize.width))×\(Int(info.displaySize.height)) · \(duration) · \(info.codecDescription)"
    }

    // MARK: - Settings

    private var settings: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 16) {
            Text("SETTINGS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Which face").font(.callout)
                    Spacer()
                }
                Picker("", selection: Binding(
                    get: { isAllSelected ? 0 : 1 },
                    set: { choice in
                        if choice == 0 { model.selectAllFaces() }
                        else { model.selectSingleFace() }
                    })) {
                    Text("Every face").tag(0)
                    Text("One face").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(isAllSelected
                     ? "Replaces every face in the frame."
                     : "Replaces one face. Click a different face in the preview to switch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Resemblance").font(.callout)
                    Spacer()
                    Text(String(format: "%.0f%%", model.identityStrength * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.identityStrength, in: 0 ... 1) { editing in
                    if !editing { Task { await model.refreshPreview() } }
                }
                Text("Higher keeps more of the source face; lower blends toward the original.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Edge softness").font(.callout)
                    Spacer()
                    Text(String(format: "%.0f%%", model.maskBlur * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.maskBlur, in: 0 ... 1) { editing in
                    if !editing { Task { await model.refreshPreview() } }
                }
            }

            Toggle(isOn: $model.enhanceFace) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enhance detail")
                    Text(model.models.isInstalledModel(.faceEnhancer)
                         ? "Sharper skin and eyes. Slower."
                         : "Needs the Face Enhancer model.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!model.models.isInstalledModel(.faceEnhancer))
            .onChange(of: model.enhanceFace) { Task { await model.refreshPreview() } }

            Toggle(isOn: $model.useHEVC) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Export as HEVC")
                    Text(model.useHEVC ? "Smaller files." : "H.264 plays anywhere.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isAllSelected: Bool {
        if case .all = model.faceSelection { return true }
        return false
    }

    private var engineBadge: some View {
        HStack(spacing: 6) {
            switch model.engine.state {
            case .ready(let summary):
                Image(systemName: "bolt.fill").foregroundStyle(.green)
                Text(summary.usingCoreML ? "Apple Neural Engine / GPU" : "CPU")
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Starting engine…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2)
            case .idle:
                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                Text("Engine idle")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        @Bindable var model = model

        return Group {
            if let info = model.targetInfo, info.durationSeconds > 0 {
                HStack(spacing: 12) {
                    Text(timecode(model.previewTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)

                    Slider(value: $model.previewTime, in: 0 ... info.durationSeconds)
                        .disabled(model.isRendering)

                    Text(timecode(info.durationSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)

                    if model.previewResult != nil {
                        Button {
                            model.showsOriginal.toggle()
                        } label: {
                            Label(model.showsOriginal ? "Showing original" : "Showing result",
                                  systemImage: model.showsOriginal ? "eye.slash" : "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Hold to compare with the untouched frame")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                switch model.phase {
                case .rendering:
                    renderingBar
                case .finished(let url):
                    finishedBar(url)
                case .failed(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message).font(.callout).lineLimit(2)
                        Spacer()
                        Button("Dismiss") { model.dismissResult() }
                    }
                default:
                    idleBar
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(height: 62)
        }
        .background(.regularMaterial)
    }

    private var idleBar: some View {
        HStack(spacing: 12) {
            if let message = model.statusMessage {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(readinessHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.export()
            } label: {
                Label("Export Video", systemImage: "square.and.arrow.up")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canRender)
        }
    }

    private var readinessHint: String {
        if model.sourceFace == nil && model.targetURL == nil {
            return "Add a face and a video to begin."
        }
        if model.sourceFace == nil { return "Add a source face." }
        if model.targetURL == nil { return "Add a target video." }
        return "Ready to export."
    }

    private var renderingBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: model.progress?.fraction ?? 0)
                HStack(spacing: 10) {
                    if let progress = model.progress {
                        Text("\(progress.framesWritten) / \(progress.totalFrames) frames")
                        if progress.framesPerSecond > 0 {
                            Text(String(format: "%.1f fps", progress.framesPerSecond))
                        }
                        if let remaining = progress.estimatedTimeRemaining {
                            Text("\(formatDuration(remaining)) left")
                        }
                    } else {
                        Text("Starting…")
                    }
                    Spacer()
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Button("Cancel", role: .cancel) { model.cancelExport() }
                .controlSize(.large)
        }
    }

    private func finishedBar(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Export complete").font(.callout.weight(.medium))
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show in Finder") { model.reveal(url) }
            Button("Play") { model.open(url) }
                .buttonStyle(.borderedProminent)
            Button {
                model.dismissResult()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    StudioView()
        .environment(AppModel())
        .frame(width: 1180, height: 760)
}
