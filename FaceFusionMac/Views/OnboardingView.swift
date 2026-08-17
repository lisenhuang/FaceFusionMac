//
//  OnboardingView.swift
//  FaceFusionMac
//
//  First run: explain what is about to be downloaded, then download it.
//
//  This is the only moment the app needs a network connection in order to do
//  anything, so it says so plainly rather than leaving the user to wonder. The
//  App Store version lookup in `UpdateChecker` also uses the network, but it
//  fails silently and nothing waits on it.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var includeOptional = true

    private var manager: ModelManager { model.models }

    private var selectedModels: [ModelDescriptor] {
        includeOptional ? (manager.manifest?.models ?? []) : manager.requiredModels
    }

    private var downloadSize: Int64 { manager.downloadSize(for: selectedModels) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                if let error = manager.lastError {
                    Banner(kind: .error, text: error)
                }

                modelList

                optionsAndAction

                disclosure
            }
            .frame(maxWidth: 660)
            .padding(.horizontal, 40)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity)
        }
        .background(.background)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.12))
                    .frame(width: 78, height: 78)
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .padding(.bottom, 4)

            Text("Set up Morphiqo")
                .font(.system(size: 26, weight: .semibold))

            Text("The app needs its AI models before it can run. This is a one‑time download — afterwards face swapping works entirely on this Mac, with no internet connection.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            ForEach(manager.manifest?.models ?? []) { descriptor in
                ModelRow(descriptor: descriptor,
                         state: manager.states[descriptor.id] ?? .missing,
                         included: descriptor.required || includeOptional)
                if descriptor.id != manager.manifest?.models.last?.id {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private var optionsAndAction: some View {
        VStack(spacing: 18) {
            Toggle(isOn: $includeOptional) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include quality extras")
                    Text("Sharper results and steadier tracking. You can add these later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(manager.isWorking)

            if manager.isWorking {
                VStack(spacing: 10) {
                    ProgressView(value: Double(manager.sessionReceived),
                                 total: Double(max(manager.sessionTotal, 1)))
                    HStack {
                        Text("\(formatBytes(manager.sessionReceived)) of \(formatBytes(manager.sessionTotal))")
                        Spacer()
                        Button("Cancel", role: .cancel) { manager.cancel() }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if manager.isPreparingLibrary {
                // The launch pass can still be hashing a model it is about to
                // adopt, and until it is done "Download 903 MB" is an offer to
                // re-fetch weights that are already on this Mac. `install`
                // refuses to start while the pass is running anyway, so leaving
                // the button up would only make it look broken.
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Checking the models already on this Mac…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    manager.install(selectedModels)
                } label: {
                    Text(downloadSize > 0
                         ? "Download \(formatBytes(downloadSize))"
                         : "Continue")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selectedModels.isEmpty)
            }
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Every file is verified against a checksum before use, and anything that does not match is discarded.")
            } icon: {
                Image(systemName: "checkmark.shield")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
    }
}

// MARK: - Row

private struct ModelRow: View {
    let descriptor: ModelDescriptor
    let state: ModelInstallState
    let included: Bool

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(descriptor.displayName)
                        .font(.callout.weight(.medium))
                    if !descriptor.required {
                        Text("Optional")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text(descriptor.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(included ? 1 : 0.45)
    }

    @ViewBuilder private var statusIcon: some View {
        switch state {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .downloading, .verifying, .checking:
            ProgressView().controlSize(.small)
        case .missing:
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .downloading(let received, let total):
            Text("\(Int(Double(received) / Double(max(total, 1)) * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .verifying:
            Text("Verifying…").font(.caption).foregroundStyle(.secondary)
        case .checking:
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        case .installed:
            Text("Installed").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Text("Failed").font(.caption).foregroundStyle(.orange)
        case .missing:
            Text(formatBytes(descriptor.bytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Helpers

func formatBytes(_ count: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useMB, .useGB]
    return formatter.string(fromByteCount: count)
}

struct Banner: View {
    enum Kind { case error, info }
    var kind: Kind
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(kind == .error ? .orange : .secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background((kind == .error ? Color.orange : Color.secondary).opacity(0.1),
                    in: .rect(cornerRadius: 10))
    }
}

#Preview {
    OnboardingView()
        .environment(AppModel())
        .frame(width: 760, height: 720)
}
