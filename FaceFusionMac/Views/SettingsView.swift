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

    /// What the last Check for Updates concluded, and whether its alert is up.
    /// Held separately from the launch check in `FaceFusionMacApp`, which shows
    /// only the one outcome worth interrupting somebody for.
    @State private var updateOutcome: UpdateChecker.Outcome?
    @State private var isCheckingForUpdate = false
    @State private var isShowingUpdateResult = false

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
        // Every outcome gets an alert, including the boring one. A button the
        // user pressed that answers by doing nothing visible reads as broken.
        .alert(updateAlertTitle,
               isPresented: $isShowingUpdateResult,
               presenting: updateOutcome) { outcome in
            if case .available(let update) = outcome {
                Button("Update") { NSWorkspace.shared.open(update.storeURL) }
                Button("Not now", role: .cancel) { }
            } else {
                Button("OK", role: .cancel) { }
            }
        } message: { outcome in
            updateAlertMessage(for: outcome)
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

    /// The version this build is, and a way to find out whether it is the one
    /// the store is selling.
    ///
    /// The app already asks this once per launch and stays quiet unless the
    /// answer is "yes, there is something newer" — which is right for an
    /// unprompted check and useless to somebody who wants to know *now*.
    ///
    /// On this platform the honest answer is currently "could not check", and
    /// that is deliberate: there is no Mac App Store listing to compare
    /// against, and `UpdateChecker` refuses to answer with the iPhone app's
    /// version number. Saying so beats the alternative, which is a button that
    /// reports "up to date" without ever having learned anything.
    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(UpdateChecker.installedVersion)
                    .font(.body.monospacedDigit())
            }

            HStack(spacing: 10) {
                Button("Check for Updates") {
                    Task { await checkForUpdate() }
                }
                .disabled(isCheckingForUpdate)

                if isCheckingForUpdate {
                    ProgressView().controlSize(.small)
                    Text("Checking the App Store…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        } header: {
            Text("About")
        } footer: {
            Text("Checking asks the App Store for its version number and nothing else — no identifier, no machine details, and nothing about the media you have worked on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func checkForUpdate() async {
        guard !isCheckingForUpdate else { return }
        isCheckingForUpdate = true
        let outcome = await UpdateChecker.fetch()
        isCheckingForUpdate = false
        updateOutcome = outcome
        isShowingUpdateResult = true
    }

    /// `LocalizedStringKey` rather than the `String` the confirmation titles
    /// above use, and the difference is not cosmetic: this window follows the
    /// language picker through `environment(\.locale:)`, which SwiftUI applies
    /// to `LocalizedStringKey` and not to a `String` that was already resolved
    /// before `Text` saw it.
    private var updateAlertTitle: LocalizedStringKey {
        switch updateOutcome {
        case .available:
            return "A new version is available"
        case .current:
            return "Morphiqo is up to date"
        // `.none` cannot reach the screen — the alert is only raised with an
        // outcome in hand — but a title is needed to type-check the property,
        // and the cautious one is the right default.
        case .unavailable, .none:
            return "Could not check for updates"
        }
    }

    /// Both numbers in every case, because "which version am I on" and "which
    /// version is current" are the two questions the button is pressed to
    /// answer, and only one of them is on the row above.
    @ViewBuilder
    private func updateAlertMessage(for outcome: UpdateChecker.Outcome) -> some View {
        switch outcome {
        case .available(let update):
            Text("You have \(UpdateChecker.installedVersion). Version \(update.version) is on the App Store.")
        case .current(let latest):
            Text("You have \(UpdateChecker.installedVersion), and the App Store has \(latest).")
        case .unavailable:
            Text("You have \(UpdateChecker.installedVersion). The App Store did not answer, so there is nothing to compare it against — check your connection and try again.")
        }
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
