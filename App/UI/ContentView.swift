import SwiftUI

struct ContentView: View {
    @StateObject private var store = PackStore()
    @StateObject private var engine = NavigationEngine()
    @AppStorage("acceptedSafety") private var accepted = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if !accepted {
                SafetyNotice { accepted = true; engine.startSensors() }
            } else if store.installed.isEmpty {
                MapsView(store: store, showsClose: false)
            } else {
                DriveView(engine: engine, store: store)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { engine.load(installed: store.installed) }
        .onChange(of: store.installed) { _, installed in engine.load(installed: installed) }
        .onChange(of: phase) { _, newPhase in
            // Sensors and camera only run while the app is on screen.
            if newPhase == .active, accepted {
                engine.startSensors()
            } else if newPhase == .background {
                engine.stopSensors()
            }
        }
    }
}
