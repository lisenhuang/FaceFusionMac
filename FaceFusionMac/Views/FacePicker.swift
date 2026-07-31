//
//  FacePicker.swift
//  FaceFusionMac
//
//  The list of people in the target, with a checkbox each.
//

import SwiftUI

struct FacePicker: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 62, maximum: 78), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isScanning {
                scanning
            } else if model.people.isEmpty {
                empty
            } else {
                grid
                summary
                matchSlider
            }
        }
    }

    // MARK: - States

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView(value: model.scanProgress?.fraction ?? 0)
                Button("Stop") { model.cancelScan() }
                    .controlSize(.small)
            }
            Text(scanCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var scanCaption: String {
        guard let progress = model.scanProgress else { return "Looking…" }
        let found = progress.peopleFound
        let people = found == 1 ? "1 person" : "\(found) people"
        return "Frame \(progress.framesScanned) of \(progress.totalFrames) · \(people) so far"
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.hasScanned
                 ? "No faces found in the target."
                 : (model.targetIsImage
                    ? "Look for the faces in this photo."
                    : "Look through the video for the people in it, then tick the ones to replace."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.scanTargetForPeople()
            } label: {
                Label(model.hasScanned ? "Look again" : "Find faces",
                      systemImage: "person.crop.rectangle.stack")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.targetURL == nil)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(model.people) { person in
                FaceChip(person: person,
                         isChecked: model.checkedPeople.contains(person.id),
                         caption: caption(for: person)) {
                    model.togglePerson(person.id)
                }
            }
        }
    }

    /// When someone is on screen. Useless for a photo, and for a person who
    /// appears in a single sampled frame there is no span to state.
    private func caption(for person: FaceScanner.Person) -> String? {
        guard !model.targetIsImage, person.lastSeen > person.firstSeen + 0.5 else { return nil }
        return "\(timecode(person.firstSeen))–\(timecode(person.lastSeen))"
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(selectionSummary)
                    .font(.caption2)
                    .foregroundStyle(model.checkedPeople.isEmpty
                                     ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(model.checkedPeople.count == model.people.count ? "None" : "All") {
                    if model.checkedPeople.count == model.people.count {
                        model.uncheckEveryPerson()
                    } else {
                        model.checkEveryPerson()
                    }
                }
                Button("Look again") { model.scanTargetForPeople() }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .buttonStyle(.link)

            Text("Missing someone? Click their face in the preview to add them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectionSummary: String {
        let checked = model.checkedPeople.count
        guard checked > 0 else { return "No one selected — nothing will be replaced." }
        return "Replacing \(checked) of \(model.people.count)."
    }

    private var matchSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Match strictness").font(.caption)
                Spacer()
            }
            // Inverted: the engine works in distance, where larger is looser,
            // but "drag right for stricter" is the only direction a slider
            // labelled strictness can go.
            Slider(value: Binding(get: { 1.1 - model.matchDistance },
                                  set: { model.matchDistance = 1.1 - $0 }),
                   in: 0.3 ... 0.9) { editing in
                if !editing { Task { await model.applyMatchDistance() } }
            }
            Text("Lower if someone is missed when they turn away; raise if the wrong person gets replaced.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - One face

private struct FaceChip: View {
    var person: FaceScanner.Person
    var isChecked: Bool
    var caption: String?
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let thumbnail = person.thumbnail {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 20, weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 62, height: 62)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                          lineWidth: isChecked ? 2.5 : 1)
                    }
                    .opacity(isChecked ? 1 : 0.55)

                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isChecked ? AnyShapeStyle(.tint) : AnyShapeStyle(.black.opacity(0.35)))
                        .padding(3)
                }

                if let caption {
                    Text(caption)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isChecked ? "Will be replaced" : "Will be left alone")
    }
}
