//
//  FaceFusionMacApp.swift
//  FaceFusionMac
//

import SwiftUI

@main
struct FaceFusionMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 620)
                .task {
                    if SelfTest.isRequested {
                        await SelfTest.run(model: model)
                    }
                    await model.startEngineIfPossible()
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open Face Image…") { model.chooseSource() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Open Video…") { model.chooseTarget() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
