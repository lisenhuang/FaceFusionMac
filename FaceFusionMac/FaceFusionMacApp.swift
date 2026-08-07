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
    let purchases: StoreManager
    let model: AppModel

    override init() {
        let purchases = StoreManager.shared
        self.purchases = purchases
        self.model = AppModel(purchases: purchases)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if Benchmark.isProfileRequested { await Benchmark.profile(model: model) }
            if Benchmark.isRequested { await Benchmark.run(model: model) }
            if SelfTest.isRequested { await SelfTest.run(model: model) }
        }
    }

    /// Closing the window quits the app.
    ///
    /// App Review rejected the previous behaviour: the app kept running after
    /// its only window was closed, with no menu command and no Dock action that
    /// brought the window back. For a single-window app Apple accepts either a
    /// reopen command or quitting on close, and quitting is the right one here —
    /// the XPC engine holds roughly 900 MB of loaded models for as long as the
    /// app lives, which is a lot to keep resident for a process with nothing on
    /// screen.
    ///
    /// Stated explicitly rather than left to the `Window` scene, which happens
    /// to terminate today. This is the behaviour a reviewer tests, so it should
    /// not rest on an emergent default that a future SwiftUI release could
    /// quietly change.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A headless run has no window to close and must not be killed by this.
        !Benchmark.isRequested && !Benchmark.isProfileRequested && !SelfTest.isRequested
    }
}

@main
struct FaceFusionMacApp: App {
    /// Identifies the single window scene, for `openWindow(id:)` and for the
    /// Window-menu item SwiftUI derives from it.
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private var model: AppModel { delegate.model }
    private var purchases: StoreManager { delegate.purchases }
    @State private var preferences = Preferences.shared

    /// Set only when the App Store has something newer; see `UpdateChecker`.
    @State private var availableUpdate: UpdateChecker.Update?
    @State private var isShowingUpdate = false

    /// `--selftest`, `--benchmark` and `--profile` drive the app headlessly and
    /// report to stdout. An alert in front of them would sit there unanswered
    /// and turn a scripted run into a hang.
    private var isHeadless: Bool {
        Benchmark.isRequested || Benchmark.isProfileRequested || SelfTest.isRequested
    }

    /// Tracks the one update lookup per launch, so reopening the window after
    /// closing it does not ask the App Store again — or prompt again.
    @State private var hasCheckedForUpdate = false

    var body: some Scene {
        // `Window`, not `WindowGroup`. There is one model, one engine and one
        // document at a time, so a second window would be two views fighting
        // over one pipeline.
        //
        // It is also half of the fix for the App Review rejection. A
        // `WindowGroup` can only be reopened through File ▸ New Window, which
        // this app removes below — so closing the window left a running app
        // with no way back to it. A single `Window` plus
        // `applicationShouldTerminateAfterLastWindowClosed` above means closing
        // the window ends the app instead of stranding it.
        Window("Morphiqo", id: Self.mainWindowID) {
            ContentView()
                .environment(model)
                .environment(purchases)
                .environment(\.locale, preferences.language.locale)
                .frame(minWidth: 940, minHeight: 620)
                // No engine start here. `ContentView` owns it, keyed on the set
                // of models that are actually installed, and a second
                // unconditional starter alongside it only races the first into
                // a duplicate `prepare` on the launches where the library was
                // already decided before the window appeared.
                //
                // Once per launch, off the main path: the result arrives long
                // after the first frame and nothing waits on it.
                .task {
                    guard !isHeadless, !hasCheckedForUpdate else { return }
                    hasCheckedForUpdate = true
                    guard let update = await UpdateChecker.check() else { return }
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
            // No File ▸ New Window: a `Window` scene has exactly one window, so
            // the command would have nothing to make. The Window menu's
            // "Morphiqo" item is what reopens it.
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open Face Image…") { model.chooseSource() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Open Video or Photo…") { model.chooseTarget() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        // A `Settings` scene rather than a window of our own: it is what puts
        // "Settings…" in the app menu under ⌘, without a line of menu code, and
        // menu access to important commands is exactly what App Review rejected
        // an earlier build for lacking. It is also the only place the ~900 MB
        // model library can be seen or reclaimed — before this, deleting the
        // Group Container in Finder was the user's only recourse.
        //
        // A second scene does not undo the single-window decision above: this
        // one is opened by the system, has no File ▸ New counterpart, and
        // `applicationShouldTerminateAfterLastWindowClosed` still ends the app
        // once the last of them is closed.
        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, preferences.language.locale)
        }
    }
}
