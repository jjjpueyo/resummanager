import SwiftUI

@main
struct CadCamStockApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var scraper = Scraper()
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if !scraper.status.isEmpty {
                    Text(scraper.status).foregroundStyle(scraper.isLoading ? Color.secondary : Color.red)
                }
                ForEach(scraper.results) { center in
                    Section(center.id) {
                        ForEach(center.materials) { m in
                            HStack {
                                Text(m.id).font(.headline)
                                Spacer()
                                counter("Prog.", m.prog)
                                counter("Mec.", m.mec)
                            }
                        }
                    }
                }
                if let d = scraper.lastUpdate {
                    Text("Actualitzat: \(d.formatted(date: .omitted, time: .standard))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .overlay {
                // La mateixa web: invisible (1 px) normalment, a pantalla completa si cal login manual.
                if scraper.needsManualLogin {
                    HiddenWebView(webView: scraper.webView).background(Color(.systemBackground))
                } else {
                    HiddenWebView(webView: scraper.webView).frame(width: 1, height: 1).opacity(0.01)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .navigationTitle("Stock CAD/CAM")
            .toolbar { Button { showSettings = true } label: { Image(systemName: "gearshape") } }
            .refreshable { await scraper.refresh() }
            .task { await scraper.refresh() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func counter(_ label: String, _ v: Int?) -> some View {
        VStack {
            Text(v.map(String.init) ?? "—").font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(width: 60)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var user = Keychain.get("user") ?? ""
    @State private var pass = Keychain.get("pass") ?? ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Usuari", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Contrasenya", text: $pass)
            }
            .navigationTitle("Accés")
            .toolbar {
                Button("Desa") {
                    Keychain.set(user, for: "user"); Keychain.set(pass, for: "pass"); dismiss()
                }
            }
        }
    }
}
