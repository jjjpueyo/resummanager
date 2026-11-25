import SwiftUI

@main
struct CadCamStockApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

// MARK: - Colors (el fons és exactament el del logo de Phibodent)
enum Theme {
    static let bg = Color(red: 18/255, green: 26/255, blue: 43/255)
    static let card = Color.white.opacity(0.07)
    static let stroke = Color.white.opacity(0.08)
    static let prog = Color(red: 0.40, green: 0.68, blue: 1.00)
    static let mec = Color(red: 1.00, green: 0.66, blue: 0.20)
    static let ok = Color(red: 0.30, green: 0.85, blue: 0.50)
    static let imes = Color(red: 0.62, green: 0.60, blue: 1.00)
    static let datron = Color(red: 0.30, green: 0.85, blue: 0.85)
}

/// Fons de targeta amb vora fina, comú a tota l'app.
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}
private extension View {
    func card() -> some View { modifier(CardBackground()) }
}

// MARK: - Pantalla principal (2 pestanyes)
struct ContentView: View {
    @StateObject private var scraper = Scraper()
    @State private var showSettings = false
    @State private var wentToBackground = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            TabView {
                StockPage(scraper: scraper, showSettings: $showSettings)
                    .tabItem { Label("Stock", systemImage: "square.grid.2x2.fill") }
                TeamPage(scraper: scraper, showSettings: $showSettings)
                    .tabItem { Label("Programadors", systemImage: "person.2.fill") }
            }
            .tint(Theme.prog)
            .toolbarBackground(Theme.bg, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            webLayer
        }
        .task { await Task { await scraper.refresh() }.value }
        .onChange(of: scenePhase) { phase in
            if phase == .background { wentToBackground = true; return }
            guard phase == .active else { return }
            if wentToBackground {
                // Tornem de segon pla: aturem qualsevol lectura vella i en comencem una de neta.
                wentToBackground = false
                Task { await scraper.resumeFromBackground() }
            } else {
                if let d = scraper.lastUpdate, Date().timeIntervalSince(d) < 20 { return }
                Task { await scraper.refresh() }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .preferredColorScheme(.dark)
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

// MARK: - Capçalera: logo + títol com un sol bloc
struct HeaderView: View {
    @ObservedObject var scraper: Scraper
    @Binding var showSettings: Bool

    private var subtitle: String {
        if scraper.isLoading { return scraper.status.isEmpty ? "Actualitzant…" : scraper.status }
        if let d = scraper.lastUpdate {
            return "Actualitzat a les " + d.formatted(date: .omitted, time: .shortened)
        }
        return "Sense dades"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Image("PhibodentLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 30)
                    HStack(spacing: 8) {
                        Capsule().fill(Theme.prog).frame(width: 3, height: 15)
                        Text("CADCAM MANAGER")
                            .font(.system(size: 14, weight: .bold))
                            .tracking(3)
                            .foregroundStyle(Color.white.opacity(0.92))
                    }
                }
                Spacer()
                HStack(spacing: 18) {
                    if scraper.isLoading {
                        ProgressView()
                    } else {
                        Button { Task { await scraper.refresh() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.top, 4)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(scraper.isLoading ? Theme.mec : Theme.ok)
                    .frame(width: 7, height: 7)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Rectangle()
                .fill(LinearGradient(colors: [Theme.prog.opacity(0.7), Color.white.opacity(0.05)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
    }
}

private struct ErrorBanner: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Pestanya STOCK
struct StockPage: View {
    @ObservedObject var scraper: Scraper
    @Binding var showSettings: Bool

    private var totalRows: Int { max(scraper.results.flatMap { $0.materials }.count, 4) }

    /// Alçada de cada fila perquè tot càpiga a la pantalla sense scroll.
    private func rowHeight(_ total: CGFloat) -> CGFloat {
        let overhead: CGFloat = 132 + CGFloat(max(scraper.results.count, 2)) * 58 + (Config.trackMachines ? 170 : 0)
        let h = (total - overhead) / CGFloat(totalRows)
        return min(max(h, 62), 130)
    }

    /// Fitxers de Zirconi en Fase Mecanizado segons el menú (per comprovar que la taula quadra).
    private var expectedZirconiFiles: Int? {
        scraper.results.first { $0.id == Config.machineCenter }?
            .materials.first { $0.id == "Zirconio" }?.mec
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 14) {
                    HeaderView(scraper: scraper, showSettings: $showSettings)
                    if !scraper.isLoading && !scraper.status.isEmpty { ErrorBanner(text: scraper.status) }
                    if scraper.results.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text(scraper.isLoading ? "Carregant dades…" : "Tira cap avall per actualitzar")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 80)
                    } else {
                        ForEach(scraper.results) { c in
                            CenterCard(center: c, rowHeight: rowHeight(geo.size.height))
                        }
                        if Config.trackMachines {
                            MachinesCard(summary: scraper.machines,
                                         note: scraper.machinesNote,
                                         loading: scraper.isLoading,
                                         expectedFiles: expectedZirconiFiles)
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
        .background(Theme.bg.ignoresSafeArea())
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
                if idx > 0 { Divider().overlay(Theme.stroke).padding(.leading, 16) }
                MaterialRow(material: m).frame(height: rowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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

/// Zirconi en Fase Mecanizado: només PECES per màquina.
struct MachinesCard: View {
    let summary: MachineSummary?
    let note: String
    let loading: Bool
    let expectedFiles: Int?

    private var totalFiles: Int { summary?.stats.reduce(0) { $0 + $1.cases } ?? 0 }

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
                    Text("\(totalFiles) fitxers")
                        .font(.title3.weight(.heavy))
                }
            }
            if let s = summary {
                HStack(spacing: 10) {
                    ForEach(s.stats) { st in
                        VStack(spacing: 2) {
                            Text("\(st.cases)")
                                .font(.system(size: 40, weight: .heavy, design: .rounded))
                                .foregroundStyle(color(st.machine))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                            Text(st.machine.isEmpty ? "SENSE MÀQUINA" : st.machine)
                                .font(.footnote.weight(.bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text("fitxers")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(color(st.machine).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                if let e = expectedFiles, e != totalFiles {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ull: he llegit \(totalFiles) fitxers i el menú en diu \(e).")
                        if let pc = s.pageCounts, !pc.isEmpty {
                            Text("Per pàgines: " + pc.map(String.init).joined(separator: " + "))
                        }
                    }
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
        .card()
    }
}

// MARK: - Pestanya PROGRAMADORS
struct TeamPage: View {
    @ObservedObject var scraper: Scraper
    @Binding var showSettings: Bool

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 14) {
                    HeaderView(scraper: scraper, showSettings: $showSettings)
                    if !scraper.isLoading && !scraper.status.isEmpty { ErrorBanner(text: scraper.status) }
                    ProgrammersCard(summary: scraper.programmers,
                                    note: scraper.programmersNote,
                                    loading: scraper.isLoading)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .refreshable { await Task { await scraper.refresh() }.value }
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}

/// Fitxers en Fase Mecanitzat per programador (inicials de la columna "Prog"), per material i centre.
struct ProgrammersCard: View {
    let summary: ProgrammerSummary?
    let note: String
    let loading: Bool

    private let scans = Config.scans
    private let nameW: CGFloat = 64
    private let totalW: CGFloat = 50

    private func value(_ p: ProgrammerStat, _ key: String) -> Int { p.counts[key] ?? 0 }
    private func columnTotal(_ s: ProgrammerSummary, _ key: String) -> Int {
        s.stats.reduce(0) { $0 + ($1.counts[key] ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROGRAMADORS · FITXERS EN MECANITZAT")
                .font(.footnote.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            if let s = summary, !s.stats.isEmpty {
                HStack(spacing: 0) {
                    Text("").frame(width: nameW, alignment: .leading)
                    ForEach(scans, id: \.key) { c in
                        Text(c.short)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    Text("Total")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: totalW)
                }
                ForEach(s.stats) { p in
                    Divider().overlay(Theme.stroke)
                    HStack(spacing: 0) {
                        HStack {
                            Text(p.initials)
                                .font(.system(size: 13, weight: .heavy, design: .rounded))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Theme.prog.opacity(0.18), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        .frame(width: nameW, alignment: .leading)
                        ForEach(scans, id: \.key) { c in
                            let v = value(p, c.key)
                            Text(v == 0 ? "–" : "\(v)")
                                .font(.system(.title3, design: .rounded).weight(.bold))
                                .foregroundStyle(v == 0 ? Color.secondary.opacity(0.45) : Color.white)
                                .frame(maxWidth: .infinity)
                        }
                        Text("\(p.total)")
                            .font(.system(.title3, design: .rounded).weight(.heavy))
                            .foregroundStyle(Theme.prog)
                            .frame(width: totalW)
                    }
                    .frame(height: 44)
                }
                Divider().overlay(Theme.stroke)
                HStack(spacing: 0) {
                    Text("TOTAL")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: nameW, alignment: .leading)
                    ForEach(scans, id: \.key) { c in
                        Text("\(columnTotal(s, c.key))")
                            .font(.system(.body, design: .rounded).weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    Text("\(s.stats.reduce(0) { $0 + $1.total })")
                        .font(.system(.body, design: .rounded).weight(.heavy))
                        .foregroundStyle(Theme.prog)
                        .frame(width: totalW)
                }
                .padding(.top, 2)
            } else if loading {
                HStack(spacing: 8) { ProgressView(); Text("Llegint programadors…").foregroundStyle(.secondary) }
                    .padding(.vertical, 20)
            } else {
                Text("Encara no hi ha dades. Tira cap avall per actualitzar.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }

            if !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Accés
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
