//
//  FaceFusionMacApp.swift
//  FaceFusionMac
//

import SwiftUI
import AppKit

/// Owns the app model and starts the headless modes.
///
/// `--selftest` and `--benchmark` hang off `applicationDidFinishLaunching`
/// rather than a view's `.task` because they must not depend on a window ever
/// being shown. Launching the binary straight from a shell does not always
/// produce one, and when it does not, a view-driven headless run simply sits
/// there with no output and no clue as to why.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if Benchmark.isProfileRequested { await Benchmark.profile(model: model) }
            if Benchmark.isRequested { await Benchmark.run(model: model) }
            if SelfTest.isRequested { await SelfTest.run(model: model) }
        }
    }
}

@main
struct FaceFusionMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var model: AppModel { delegate.model }

    /// Set only when the App Store has something newer; see `UpdateChecker`.
    @State private var availableUpdate: UpdateChecker.Update?
    @State private var isShowingUpdate = false

    /// `--selftest`, `--benchmark` and `--profile` drive the app headlessly and
    /// report to stdout. An alert in front of them would sit there unanswered
    /// and turn a scripted run into a hang.
    private var isHeadless: Bool {
        Benchmark.isRequested || Benchmark.isProfileRequested || SelfTest.isRequested
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 620)
                .task { await model.startEngineIfPossible() }
                // Once per launch, off the main path: the result arrives long
                // after the first frame and nothing waits on it.
                .task {
                    guard !isHeadless, let update = await UpdateChecker.check() else { return }
                    availableUpdate = update
                    isShowingUpdate = true
                }
                .alert("A new version is available",
                       isPresented: $isShowingUpdate,
                       presenting: availableUpdate) { update in
                    Button("Update") { NSWorkspace.shared.open(update.storeURL) }
                    Button("Not now", role: .cancel) { }
                } message: { update in
                    Text("Morphiqo \(update.version) is on the App Store. You have \(UpdateChecker.installedVersion).")
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open Face Image…") { model.chooseSource() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Open Video or Photo…") { model.chooseTarget() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
