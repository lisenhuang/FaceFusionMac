//
//  StudioView.swift
//  FaceFusionMac
//
//  The main workspace: pick a face, pick a video, judge the result on a single
//  frame, then export.
//

import SwiftUI
import StoreKit
import UniformTypeIdentifiers

struct StudioView: View {
    @Environment(AppModel.self) private var model
    @Environment(StoreManager.self) private var purchases
    /// Apple's in-app rating sheet. Presented in this process — it is not a
    /// link to the App Store and must never become one.
    @Environment(\.requestReview) private var requestReview
    @State private var showsPaywall = false

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
        .sheet(isPresented: $showsPaywall) {
            PaywallView()
        }
        .onChange(of: purchases.isPro) { _, isPro in
            if isPro { Task { await model.refreshPreview() } }
        }
        // Keyed on the phase so it runs once per finished export, and — more
        // usefully — so it is cancelled the moment the phase moves on.
        // Dismissing the finished bar within the settle delay withdraws the
        // question rather than asking it over an empty bar.
        //
        // `ReviewPrompt` owns every rule about whether this actually asks. All
        // this knows is where a successful export lands.
        .task(id: model.phase) {
            guard case .finished = model.phase else { return }
            await ReviewPrompt.requestIfEarned(requestReview)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        @Bindable var model = model

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !purchases.isPro {
                    Button { showsPaywall = true } label: {
                        Label("Unlock Pro", systemImage: "crown.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                // The strip belongs to the well above it, so the two share a
                // tighter stack of their own rather than sitting 20pt apart as
                // siblings of the target well.
                VStack(alignment: .leading, spacing: 8) {
                    MediaWell(title: "SOURCE FACE",
                              systemImage: "person.crop.square",
                              hint: "Drop a photo\nor click to choose",
                              isFilled: model.sourceBuffer != nil,
                              caption: sourceCaption,
                              accepted: [.image],
                              onChoose: { model.chooseSource() },
                              onClear: { model.clearSource() },
                              onDrop: { url in Task { await model.useSource(url) } }) {
                        if let buffer = model.sourceBuffer,
                           let image = PixelSurface.makeCGImage(from: buffer) {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                    }

                    if model.sourceFaces.count > 1 {
                        sourceFaceStrip
                    }
                }

                MediaWell(title: "TARGET",
                          systemImage: "photo.on.rectangle.angled",
                          hint: "Drop a video or photo\nor click to choose",
                          isFilled: model.targetURL != nil,
                          caption: targetCaption,
                          accepted: [.movie, .image],
                          onChoose: { model.chooseTarget() },
                          onClear: { model.clearTarget() },
                          onDrop: { url in Task { await model.useTarget(url) } }) {
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

    /// One chip per face found in the portrait, left to right as they appear in
    /// it. Clicking one re-encodes the source around that face; the ring marks
    /// the identity the engine currently holds.
    private var sourceFaceStrip: some View {
        // Indicators shown: the strip can hold more chips than a 292pt sidebar
        // is wide, and a scroller that gives no sign of it reads as a photo
        // that simply lost the rest of its faces.
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(model.sourceFaces, id: \.index) { face in
                    sourceFaceChip(face)
                }
            }
        }
        // Re-encoding the source mid-export would recondition every frame
        // after the barrier on a different person, and a click cannot reach a
        // pipeline whose sessions are gone. Both states are dimmed rather than
        // only inert: `.disabled` on a plain button wrapping a bitmap changes
        // nothing a user can see.
        .disabled(model.isRendering || !model.isEngineReady)
        .opacity(model.isRendering || !model.isEngineReady ? 0.45 : 1)
    }

    private func sourceFaceChip(_ face: DetectedFace) -> some View {
        let isChosen = face.index == model.sourceFace?.index
        let thumbnail = model.sourceFaceThumbnails.indices.contains(face.index)
            ? model.sourceFaceThumbnails[face.index]
            : nil

        return Button {
            Task { await model.chooseSourceFace(face.index) }
        } label: {
            Group {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // Sized against the chip: an unsized symbol in a 40pt
                    // circle is a speck with a lot of empty space around it.
                    Image(systemName: "person.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            .overlay {
                // The unchosen ring is faint rather than absent: in a
                // pointer-driven window a bare thumbnail does not read as
                // something you can click.
                Circle().strokeBorder(isChosen ? Color.accentColor
                                                : Color.secondary.opacity(0.35),
                                      lineWidth: isChosen ? 2 : 1)
            }
            // The whole circle is the target, not just the pixels the symbol
            // happens to cover.
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Use this face"))
        .accessibilityLabel(Text("Face \(face.index + 1)"))
        .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }

    private var sourceCaption: String? {
        guard model.sourceBuffer != nil else { return nil }
        if model.sourceFace == nil {
            return model.sourceFaceCount == 0
                ? "No face found — try a clearer, front-facing photo."
                : "Encoding…"
        }
        return model.sourceFaceCount > 1
            ? "\(model.sourceFaceCount) faces found — click the one to use."
            : "Face ready."
    }

    private var targetCaption: String? {
        guard let target = model.target else { return nil }
        let size = "\(Int(target.displaySize.width))×\(Int(target.displaySize.height))"
        switch target {
        case .video(let info):
            let duration = Duration.seconds(info.durationSeconds)
                .formatted(.time(pattern: .minuteSecond))
            return "\(size) · \(duration) · \(info.codecDescription)"
        case .image(_, let format):
            return "\(size) · \(format.isEmpty ? "Photo" : format)"
        }
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
                Picker("", selection: Binding(get: { model.faceMode },
                                              set: { model.setFaceMode($0) })) {
                    Text("Every").tag(AppModel.FaceMode.everyFace)
                    Text("One").tag(AppModel.FaceMode.oneFace)
                    Text("Choose").tag(AppModel.FaceMode.chosen)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(faceModeHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.faceMode == .chosen {
                    FacePicker()
                        .padding(.top, 4)
                }
            }

            // After "Which face" — who gets replaced, then how well.
            //
            // No resolved-factor label beside it, unlike the iOS build. There
            // the picker sits above a preview shrunk to a phone screen, where
            // raising the setting can visibly do nothing and the label is what
            // says the ceiling simply was not reached. Here the preview is
            // full resolution in a window the user can size, so the difference
            // shows for itself — and the number would have to come from the
            // engine anyway, since `FaceSwapper` lives in the XPC service and
            // the app cannot resolve the boost without duplicating the warp
            // templates that `GeometryTests` exists to pin down.
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Close-up detail").font(.callout)
                    Spacer()
                }
                Picker("", selection: $model.closeUpDetail) {
                    Text("Standard").tag(CloseUpDetail.standard)
                    Text("High").tag(CloseUpDetail.high)
                    Text("Maximum").tag(CloseUpDetail.maximum)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(closeUpDetailHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: model.closeUpDetail) { Task { await model.refreshPreview() } }

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

            Toggle(isOn: $model.maskOcclusion) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep hands and hair")
                    Text(model.models.isInstalledModel(.faceOccluder)
                         ? "Objects crossing the face stay in front. Slower."
                         : "Needs the Occlusion Mask model.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!model.models.isInstalledModel(.faceOccluder))
            .onChange(of: model.maskOcclusion) { Task { await model.refreshPreview() } }

            // Codec choice is meaningless for a photo; the save panel offers
            // PNG or JPEG there instead.
            if !model.targetIsImage {
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
    }

    /// What the chosen level costs and buys, in that order — the cost is the
    /// part a user cannot discover without exporting twice.
    ///
    /// Each repeats "small faces cost nothing" rather than saying it once
    /// above, because the ceiling is the least intuitive thing about the
    /// control: the slowest option is free on a wide shot, and that is worth
    /// saying at the moment someone is choosing between them.
    /// `LocalizedStringKey` rather than `String`, which is the difference
    /// between this caption being translated and not. `Text` localises a key;
    /// handed a `String` it renders it verbatim, and the neighbouring
    /// `faceModeHint` returns one — its text sits in the catalog, translated,
    /// and reaches the screen in English regardless. Worth a look separately;
    /// not worth copying here.
    private var closeUpDetailHint: LocalizedStringKey {
        switch model.closeUpDetail {
        case .standard:
            return "Fastest to export. A face that fills the frame can look soft."
        case .high:
            return "Slower to export, sharper on close-ups. Small faces cost nothing."
        case .maximum:
            return "Slowest to export, sharpest on close-ups. Small faces cost nothing."
        }
    }

    private var faceModeHint: String {
        switch model.faceMode {
        case .everyFace:
            return "Replaces every face in the frame."
        case .oneFace:
            return "Replaces one face. Click a different face in the preview to switch."
        case .chosen:
            return model.targetIsImage
                ? "Replaces only the faces you tick."
                : "Replaces only the people you tick, wherever they appear in the video."
        }
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
                // The library pass runs before the engine is allowed to start,
                // so on a launch that has models to adopt this badge is idle for
                // a few seconds. Saying why beats saying "idle" at someone
                // waiting for the app to come up.
                if model.models.isPreparingLibrary {
                    ProgressView().controlSize(.small)
                    Text("Checking models…")
                } else {
                    Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                    Text("Engine idle")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        @Bindable var model = model

        let timeline = model.targetInfo.flatMap { $0.durationSeconds > 0 ? $0 : nil }
        let canCompare = model.previewResult != nil

        // A photo has no timeline, but it still earns the before/after toggle —
        // which is why that button does not live inside the slider row.
        return Group {
            if timeline != nil || canCompare {
                HStack(spacing: 12) {
                    if let timeline {
                        Text(timecode(model.previewTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)

                        Slider(value: $model.previewTime, in: 0 ... timeline.durationSeconds)
                            .disabled(model.isRendering)

                        Text(timecode(timeline.durationSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .leading)
                    } else {
                        Spacer()
                    }

                    if canCompare {
                        Button {
                            model.showsOriginal.toggle()
                        } label: {
                            Label(model.showsOriginal ? "Showing original" : "Showing result",
                                  systemImage: model.showsOriginal ? "eye.slash" : "eye")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Compare with the untouched frame")
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
                if purchases.isPro {
                    model.export()
                } else {
                    showsPaywall = true
                }
            } label: {
                Label(model.targetIsImage ? "Export Photo" : "Export Video",
                      systemImage: "square.and.arrow.up")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canRender)
        }
    }

    private var readinessHint: String {
        if model.sourceFace == nil && model.targetURL == nil {
            return "Add a face and a video or photo to begin."
        }
        if model.sourceFace == nil { return "Add a source face." }
        if model.targetURL == nil { return "Add a target video or photo." }
        if model.faceMode == .chosen && model.checkedPeople.isEmpty {
            return model.people.isEmpty
                ? "Find the faces in the target, then tick the ones to replace."
                : "Tick at least one face to replace."
        }
        return "Ready to export."
    }

    private var renderingBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if model.targetIsImage {
                    // One frame: a percentage would go 0 to 100 with nothing
                    // in between.
                    ProgressView().progressViewStyle(.linear)
                    Text("Rendering the photo…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
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
            }
            Button("Cancel", role: .cancel) { model.cancelExport() }
                .controlSize(.large)
                .disabled(model.targetIsImage)
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
            Button(model.targetIsImage ? "Open" : "Play") { model.open(url) }
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
        .environment(StoreManager.shared)
        .frame(width: 1180, height: 760)
}
