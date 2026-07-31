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
        .task(id: model.models.isReady) {
            await model.startEngineIfPossible()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 1180, height: 760)
}
