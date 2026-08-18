//
//  SettingsView.swift
//  FaceFusionMac
//
//  The Settings window: what the model library costs in disk, and how to get
//  that disk back.
//
//  There was nothing here before, which meant the ~900 MB the app downloads on
//  first run could only be reclaimed by deleting the Group Container by hand in
//  Finder. Being a real `Settings` scene rather than a panel of our own is what
//  earns the standard "Morphiqo ▸ Settings…" menu item and ⌘, — and menu access
//  to important commands is precisely what App Review rejected an earlier build
//  for not having.
//
//  The screen is organised around the one distinction that makes any of this
//  worth doing: three of the five models are required and two are not. The
//  optional pair is roughly 438 MB of the 903 — nearly half the library — and
//  removing it leaves an app that still swaps faces, just without landmark
//  refinement or detail enhancement. Removing a required model stops swapping
//  until it has been downloaded again. Five undifferentiated rows would hide
//  the only choice on this screen that a user can make safely.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Bindable private var preferences = Preferences.shared

    /// What a confirmation is currently being asked about. One piece of state
    /// for all three destructive actions: they ask the same question about
    /// different sets, and three booleans would let two dialogs be true at once.
    @State private var pending: Removal?
    @State private var isRemoving = false

    /// Apple's in-app rating sheet. `ReviewPrompt` decides whether asking now
    /// can work; this is only how the action reaches it.
    @Environment(\.requestReview) private var requestReview

    private enum Removal {
        case one(ModelDescriptor)
        case optional
        case all
    }

    private var manager: ModelManager { model.models }

    var body: some View {
        Form {
            languageSection
            storageSection
            requiredSection
            optionalSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .frame(minHeight: 520)
        .environment(\.locale, preferences.language.locale)
        .alert(confirmationTitle,
               isPresented: Binding(get: { pending != nil },
                                    set: { if !$0 { pending = nil } }),
               presenting: pending) { removal in
            Button("Remove", role: .destructive) {
                Task { await remove(removal) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { removal in
            Text(confirmationMessage(for: removal))
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $preferences.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("System follows macOS. Choosing a language applies to Morphiqo and is remembered for the next launch.")
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            LabeledContent("On disk") {
                Text(formatBytes(manager.installedBytes))
                    .font(.body.monospacedDigit())
            }

            if manager.isWorking {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(manager.sessionReceived),
                                 total: Double(max(manager.sessionTotal, 1)))
                    HStack {
                        Text("\(formatBytes(manager.sessionReceived)) of \(formatBytes(manager.sessionTotal))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { manager.cancel() }
                            .controlSize(.small)
                    }
                }
            } else if manager.isPreparingLibrary {
                // Until the launch pass has finished, a model it is about to
                // adopt still looks uninstalled — so both the size above and a
                // "Download missing" offer would be wrong, and `install`
                // refuses to run anyway.
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the models already on this Mac…")
                        .foregroundStyle(.secondary)
                }
            } else if missingBytes > 0 {
                Button {
                    manager.install(catalogue)
                } label: {
                    Label("Download missing (\(formatBytes(missingBytes)))",
                          systemImage: "arrow.down.circle")
                }
                .disabled(isRemoving)
            }

            Button(role: .destructive) {
                pending = .all
            } label: {
                Label("Remove all models", systemImage: "trash")
            }
            .disabled(!canRemove || manager.installedBytes == 0)

            if let error = manager.lastError {
                Banner(kind: .error, text: error)
            }

            if model.isRendering {
                Banner(kind: .info,
                       text: "An export is running. Models cannot be removed until it finishes.")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Everything here can be downloaded again. Removing it costs the wait, not the work — no face, video or setting is touched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The two halves of the library

    private var requiredSection: some View {
        Section {
            ForEach(manager.requiredModels) { descriptor in
                row(descriptor)
            }
        } header: {
            Text("Required")
        } footer: {
            Text("Face swapping needs all three. Remove one and the app returns to its download screen until it is fetched again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var optionalSection: some View {
        Section {
            ForEach(manager.optionalModels) { descriptor in
                row(descriptor)
            }

            if installedOptionalBytes > 0 {
                Button(role: .destructive) {
                    pending = .optional
                } label: {
                    Label("Remove the optional models (\(formatBytes(installedOptionalBytes)))",
                          systemImage: "trash")
                }
                .disabled(!canRemove)
            }
        } header: {
            Text("Optional")
        } footer: {
            // The sentence this whole screen exists for: nearly half the disk,
            // and the app still works afterwards.
            Text("Almost half the library, and swapping keeps working without it. You lose steadier tracking, the sharper result, and hands crossing the face staying in front.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One model: what it does, what it costs, and a way to get rid of it.
    ///
    /// The name is the *function* — "Face Enhancer", not the weight file it is
    /// loaded from. Nothing a user reads names a model or says where it came
    /// from, and `ModelDescriptor.displayName` is what guarantees that even for
    /// a manifest entry this build does not recognise.
    private func row(_ descriptor: ModelDescriptor) -> some View {
        HStack(spacing: 12) {
            statusIcon(for: descriptor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                    .font(.body.weight(.medium))
                Text(descriptor.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isNotLoaded(descriptor) {
                    Text("Installed but not loaded: the engine could not use this file. Remove it here and download it again.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Text(status(of: descriptor))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                pending = .one(descriptor)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove || !manager.isInstalled(descriptor))
            .help("Remove this model from disk")
            .accessibilityLabel("Remove \(descriptor.displayName)")
        }
        .padding(.vertical, 2)
    }

    /// Installed, and the engine did not end up with a session for it.
    ///
    /// Only the optional models can reach this: the pipeline loads them in a
    /// loop that logs a failure and carries on, so an unloadable one leaves a
    /// complete-looking library behind a stage that quietly does nothing. A
    /// required model failing stops preparation outright, the engine never
    /// reaches `ready`, and `isUsable` falls back to the library — which is
    /// correct, because the download screen is already saying what is wrong.
    ///
    /// A manifest entry this build does not recognise has no `ModelID` and so
    /// nothing to say about it.
    private func isNotLoaded(_ descriptor: ModelDescriptor) -> Bool {
        guard manager.isInstalled(descriptor), let id = descriptor.modelID else { return false }
        return !model.isUsable(id)
    }

    @ViewBuilder
    private func statusIcon(for descriptor: ModelDescriptor) -> some View {
        switch manager.states[descriptor.id] ?? .missing {
        case .installed where isNotLoaded(descriptor):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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

    private func status(of descriptor: ModelDescriptor) -> String {
        switch manager.states[descriptor.id] ?? .missing {
        case .installed where isNotLoaded(descriptor):
            return "\(formatBytes(descriptor.bytes)) · not loaded"
        case .installed:
            return formatBytes(descriptor.bytes)
        case .missing:
            return "\(formatBytes(descriptor.bytes)) · not installed"
        case .downloading(let received, let total):
            return "\(Int(Double(received) / Double(max(total, 1)) * 100))%"
        case .verifying:
            return "Verifying…"
        case .checking:
            return "Checking…"
        case .failed:
            return "Failed"
        }
    }

    // MARK: - About

    /// What this build is, and the one thing a happy user might want to do.
    ///
    /// There is no update check here. Morphiqo is a Universal Purchase, so the
    /// store publishes one version number for the whole record and it is the
    /// iOS build's — see `CLAUDE.md`. A Mac check could only ever have compared
    /// against the iPhone's version, and the Mac App Store already handles
    /// updates itself, so the honest option was to not have one.
    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(installedVersion)
                    .font(.body.monospacedDigit())
            }

            Button {
                if let url = ReviewPrompt.rate(requestReview) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Rate Morphiqo", systemImage: "star")
            }

            // The link is the Universal Purchase record rather than a Mac-only
            // page — there is no such page, which is the same fact that leaves
            // this section without an update check. Whoever opens it gets the
            // build for the device they opened it on, so a link sent from this
            // Mac opens the iPhone app on an iPhone. `subject` is verbatim
            // because a product name is the same in every language and does not
            // belong in the string catalog.
            ShareLink(item: AppStoreLink.listing,
                      subject: Text(verbatim: "Morphiqo"),
                      message: Text("Face swapping for photos and video that runs entirely on your own device — nothing is ever uploaded.")) {
                Label("Share Morphiqo", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Ratings are how other people find Morphiqo. It takes one click and you stay in the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The marketing version, which is what the store listing calls this build.
    private var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // MARK: - Sizes and gates

    private var catalogue: [ModelDescriptor] { manager.manifest?.models ?? [] }

    private var missingBytes: Int64 { manager.downloadSize(for: catalogue) }

    private var installedOptionalBytes: Int64 {
        manager.installedBytes(of: manager.optionalModels)
    }

    /// Removal is blocked while anything else owns the files: a download is
    /// mid-verify, an export has the engine running frame after frame, or a
    /// removal already started is still waiting on the engine process to let go.
    private var canRemove: Bool {
        !manager.isWorking && !manager.isPreparingLibrary && !model.isRendering && !isRemoving
    }

    // MARK: - Confirmation

    private var confirmationTitle: String {
        switch pending {
        case .one(let descriptor): return "Remove \(descriptor.displayName)?"
        case .optional:            return "Remove the optional models?"
        case .all, .none:          return "Remove all models?"
        }
    }

    /// Every one of these says what is freed and what stops working, because
    /// those are the only two things the answer turns on.
    private func confirmationMessage(for removal: Removal) -> String {
        switch removal {
        case .one(let descriptor) where descriptor.required:
            return "This frees \(formatBytes(descriptor.bytes)). Morphiqo cannot swap a face again until it is downloaded, which needs a connection."
        case .one(let descriptor):
            return "This frees \(formatBytes(descriptor.bytes)). Swapping keeps working without it — the result is simply less refined."
        case .optional:
            return "This frees \(formatBytes(installedOptionalBytes)). Swapping keeps working; results are less sharp, tracking less steady, and hands crossing the face are painted over again."
        case .all:
            return "This frees \(formatBytes(manager.installedBytes)), the compiled graphs included. Morphiqo cannot swap a face again until they are downloaded, which needs a connection."
        }
    }

    // MARK: - Actions

    /// Every route goes through `AppModel`, which is where the engine is
    /// unloaded across XPC before a byte is deleted — the engine runs in
    /// another process and has these files mapped, so the order is not
    /// negotiable. See `AppModel.removeModels`.
    private func remove(_ removal: Removal) async {
        isRemoving = true
        defer { isRemoving = false }

        switch removal {
        case .one(let descriptor): await model.removeModels([descriptor])
        case .optional:            await model.removeModels(manager.optionalModels)
        case .all:                 await model.removeAllModels()
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
