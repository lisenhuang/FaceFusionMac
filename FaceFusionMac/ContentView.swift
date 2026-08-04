//
//  ContentView.swift
//  FaceFusionMac
//
//  Routes between first-run model installation and the studio.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.models.isReady {
                StudioView()
            } else {
                OnboardingView()
            }
        }
        .animation(.smooth(duration: 0.35), value: model.models.isReady)
        // Keyed on the *set* of loadable models, not on `isReady`. Nil until the
        // launch pass has finished deciding the library, so the engine is never
        // started under a pass that may still rename files and empty the compile
        // cache; and a set rather than a flag so that an optional model
        // downloaded or removed from Settings — which leaves `isReady` exactly
        // where it was — still brings the engine back on what is now on disk.
        .task(id: model.models.loadableModels) {
            await model.startEngineIfPossible()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 1180, height: 760)
}
