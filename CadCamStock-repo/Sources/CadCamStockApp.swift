import SwiftUI

@main
struct CadCamStockApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var scraper = Scraper()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    private var totalRows: Int {
        max(scraper.results.flatMap { $0.materials }.count, 4)
    }

    /// Alçada de cada fila perquè tot càpiga a la pantalla sense scroll.
    private func rowHeight(_ total: CGFloat) -> CGFloat {
        let overhead: CGFloat = 126 + CGFloat(max(scraper.results.count, 2)) * 58 + (Config.trackMachines ? 170 : 0)
        let h = (total - overhead) / CGFloat(totalRows)
        return min(max(h, 64), 130)
    }

    /// Casos de Zirconi en Fase Mecanizado segons el menú (per comprovar que la taula quadra).
    private var expectedZirconiCases: Int? {
        scraper.results.first { $0.id == Config.machineCenter }?
            .materials.first { $0.id == "Zirconio" }?.mec
    }

    private var subtitle: String {
        if scraper.isLoading { return scraper.status.isEmpty ? "Actualitzant…" : scraper.status }
        if let d = scraper.lastUpdate {
            return "Actualitzat a les " + d.formatted(date: .omitted, time: .shortened)
        }
        return " "
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        if !scraper.isLoading && !scraper.status.isEmpty { errorBanner }
                        if scraper.results.isEmpty {
                            emptyState
                        } else {
                            ForEach(scraper.results) { c in
                                CenterCard(center: c, rowHeight: rowHeight(geo.size.height))
                            }
                            if Config.trackMachines {
                                MachinesCard(summary: scraper.machines,
                                             note: scraper.machinesNote,
                                             loading: scraper.isLoading,
                                             expectedCases: expectedZirconiCases)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
                .refreshable { await Task { await scraper.refresh() }.value }
            }
            webLayer
        }
        .task { await Task { await scraper.refresh() }.value }
        .onChange(of: scenePhase) { phase in
            // En tornar a l'app des del segon pla, actualitza (si l'última lectura té > 20 s)
            guard phase == .active else { return }
            if let d = scraper.lastUpdate, Date().timeIntervalSince(d) < 20 { return }
            Task { await scraper.refresh() }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("PhibodentLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CadCam Manager").font(.title.weight(.heavy))
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if scraper.isLoading {
                    ProgressView()
                } else {
                    Button { Task { await scraper.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").imageScale(.large)
                    }
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").imageScale(.large)
                }
            }
            .tint(.white)
        }
    }

    private var errorBanner: some View {
        Text(scraper.status)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(scraper.isLoading ? "Carregant dades…" : "Tira cap avall per actualitzar")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 80)
    }

    /// La web invisible (1 px); a pantalla completa només si cal fer el login a mà.
    @ViewBuilder private var webLayer: some View {
        if scraper.needsManualLogin {
            HiddenWebView(webView: scraper.webView)
                .background(Color(.systemBackground))
                .ignoresSafeArea()
        } else {
            HiddenWebView(webView: scraper.webView)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }
}

struct CenterCard: View {
    let center: CenterResult
    let rowHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(center.id.uppercased())
                .font(.footnote.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(Array(center.materials.enumerated()), id: \.element.id) { idx, m in
                if idx > 0 { Divider().padding(.leading, 16) }
                MaterialRow(material: m).frame(height: rowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct MaterialRow: View {
    let material: MaterialCount

    var body: some View {
        HStack(spacing: 8) {
            Text(material.id)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            NumberTile(title: "Programació", value: material.prog, color: Theme.prog)
            NumberTile(title: "Mecanitzat", value: material.mec, color: Theme.mec)
        }
        .padding(.horizontal, 16)
    }
}

struct NumberTile: View {
    let title: String
    let value: Int?
    let color: Color

    private var tint: Color {
        if value == 0 { return Theme.ok }
        if value == nil { return .secondary }
        return color
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(value.map(String.init) ?? "—")
                .font(.system(size: 42, weight: .heavy, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(value == 0 ? "Tot fet ✓" : title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(value == 0 ? Theme.ok : Color.secondary)
        }
        .frame(width: 96)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var user = Keychain.get("user") ?? ""
    @State private var pass = Keychain.get("pass") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Usuari", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Contrasenya", text: $pass)
            }
            .navigationTitle("Accés")
            .toolbar {
                Button("Desa") {
                    Keychain.set(user, for: "user")
                    Keychain.set(pass, for: "pass")
                    dismiss()
                }
            }
        }
    }
}

struct MachinesCard: View {
    let summary: MachineSummary?
    let note: String
    let loading: Bool
    let expectedCases: Int?

    private var totalPieces: Int { summary?.stats.reduce(0) { $0 + $1.pieces } ?? 0 }
    private var totalCases: Int { summary?.stats.reduce(0) { $0 + $1.cases } ?? 0 }

    private func color(_ m: String) -> Color {
        switch m {
        case "IMES": return Theme.imes
        case "DATRON": return Theme.datron
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("ZIRCONI · MECANITZAT")
                    .font(.footnote.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
                if summary != nil {
                    Text("\(totalPieces) peces")
                        .font(.title3.weight(.heavy))
                }
            }
            if let s = summary {
                HStack(spacing: 10) {
                    ForEach(s.stats) { st in
                        VStack(spacing: 2) {
                            Text("\(st.pieces)")
                                .font(.system(size: 40, weight: .heavy, design: .rounded))
                                .foregroundStyle(color(st.machine))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text(st.machine)
                                .font(.footnote.weight(.bold))
                            Text("\(st.cases) casos")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(color(st.machine).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                if let e = expectedCases, e != totalCases {
                    Text("Ull: he llegit \(totalCases) casos i el menú en diu \(e).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if loading {
                HStack(spacing: 8) { ProgressView(); Text("Llegint màquines…").foregroundStyle(.secondary) }
                    .padding(.vertical, 8)
            }
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Colors de l'app: el fons és exactament el del logo de Phibodent.
enum Theme {
    static let bg = Color(red: 18/255, green: 26/255, blue: 43/255)
    static let card = Color.white.opacity(0.07)
    static let prog = Color(red: 0.40, green: 0.68, blue: 1.00)
    static let mec = Color(red: 1.00, green: 0.66, blue: 0.20)
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.50)
    static let imes = Color(red: 0.62, green: 0.60, blue: 1.00)
    static let datron = Color(red: 0.30, green: 0.85, blue: 0.85)
}
