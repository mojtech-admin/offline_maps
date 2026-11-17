import SwiftUI

// MARK: - Search

struct SearchView: View {
    @ObservedObject var engine: NavigationEngine
    var onShow: (Place) -> Void
    var onNavigate: (Place) -> Void
    var onSetHere: (Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Place] = []

    var body: some View {
        NavigationStack {
            List(results) { place in
                HStack(spacing: 12) {
                    Image(systemName: place.symbol).frame(width: 26).foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name).font(.body)
                        Text([place.detail, place.state].filter { !$0.isEmpty }.joined(separator: ", "))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Go") { onNavigate(place); dismiss() }.buttonStyle(.borderedProminent)
                    Menu {
                        Button("Show on map") { onShow(place); dismiss() }
                        Button("I am here") { onSetHere(place); dismiss() }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                }
            }
            .overlay {
                if results.isEmpty {
                    Text(query.count < 2 ? "Type a city, street, address or place" : "No matches in your downloaded maps")
                        .foregroundColor(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search offline maps")
            .autocorrectionDisabled()
            .onChange(of: query) { _, text in
                guard text.count >= 2 else { results = []; return }
                // nearest-state-first is not needed: results are few, just merge every index
                results = engine.indexes.flatMap { $0.search(text, limit: 20) }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

// MARK: - Map downloads

struct MapsView: View {
    @ObservedObject var store: PackStore
    var showsClose = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(StateInfo.all) { state in
                        HStack {
                            Text(state.name)
                            Spacer()
                            if let p = store.progress[state.id] {
                                ProgressView(value: p).frame(width: 120)
                                Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                            } else if store.installed.contains(state.id) {
                                Label("On this iPhone", systemImage: "checkmark.circle.fill")
                                    .labelStyle(.titleAndIcon).foregroundColor(.green).font(.caption)
                                Button(role: .destructive) { store.delete(state.id) } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.borderless)
                            } else {
                                Button("Download") { store.download(state.id) }.buttonStyle(.bordered)
                            }
                        }
                    }
                } header: {
                    Text("State maps")
                } footer: {
                    Text("Download maps on Wi-Fi before you travel. Each state is a few hundred megabytes. Once a map is on the phone, OffRoute works with no connection at all.")
                }
                if let error = store.lastError {
                    Section { Text(error).foregroundColor(.red) }
                }
                Section {
                    Text("Map data © OpenStreetMap contributors, available under the Open Database License.")
                        .font(.caption)
                }
            }
            .navigationTitle("Maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsClose {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var engine: NavigationEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text(String(format: "Camera height above the road: %.2f m (%.0f in)",
                                    engine.mountHeight, engine.mountHeight * 39.37))
                        Slider(value: Binding(get: { engine.mountHeight }, set: { engine.mountHeight = $0 }),
                               in: 0.8...2.6, step: 0.05)
                    }
                    VStack(alignment: .leading) {
                        Text(String(format: "Dashboard hides the bottom %.0f%% of the picture", engine.roadBandBottom * 100))
                        Slider(value: Binding(get: { engine.roadBandBottom }, set: { engine.roadBandBottom = $0 }),
                               in: 0...0.45, step: 0.05)
                    }
                    HStack {
                        Text(String(format: "Learned speed correction: ×%.2f", engine.speedScale))
                        Spacer()
                        Button("Reset") { engine.resetSpeedCalibration() }
                    }
                } header: {
                    Text("Camera mount")
                } footer: {
                    Text("Mount the phone sideways (landscape) with the rear camera looking at the road through the windscreen. Speed is measured from how fast the road surface moves through the picture, so the height matters. The correction factor tunes itself each time you make a turn.")
                }
                Section("Guidance") {
                    Toggle("Spoken directions", isOn: Binding(get: { engine.voiceEnabled }, set: { engine.voiceEnabled = $0 }))
                }
                Section("About") {
                    Text("OffRoute estimates where you are from the phone's motion sensors and camera. It does not use GPS or any network. The estimate drifts and can be wrong: always follow road signs and traffic laws, and never operate the phone while driving.")
                        .font(.footnote)
                    Text("Map data © OpenStreetMap contributors (ODbL).").font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - First-run safety notice

struct SafetyNotice: View {
    var onAccept: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundColor(.yellow)
            Text("Before you drive").font(.title2.bold())
            Text("OffRoute works without GPS or internet by estimating your position from motion sensors and the camera. That estimate can drift or be wrong. Treat directions and speed readings as a guide only, obey road signs, and set up your route while parked.")
                .multilineTextAlignment(.center).font(.callout)
            Text("Mount the phone sideways with the rear camera facing the road. Camera pictures are processed on the phone and are never saved or sent anywhere.")
                .multilineTextAlignment(.center).font(.footnote).foregroundColor(.secondary)
            Button("I understand", action: onAccept).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 560)
    }
}
