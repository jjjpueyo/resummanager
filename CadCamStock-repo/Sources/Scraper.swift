import SwiftUI
import WebKit

struct MaterialCount: Identifiable, Codable {
    let id: String          // "Titanio"
    let prog: Int?          // nil = no apareix en aquest centre
    let mec: Int?
}
struct CenterResult: Identifiable, Codable {
    let id: String          // "Ourense"
    let materials: [MaterialCount]
}
struct MachineStat: Codable, Identifiable {
    var machine: String
    var pieces: Int      // suma de "Nº Piezas"
    var cases: Int       // nombre de fitxers (files)
    var id: String { machine }
}
struct MachineSummary: Codable {
    var stats: [MachineStat]
    var date: Date
    var pageCounts: [Int]?     // fitxers llegits a cada pàgina (per diagnosticar)
}
struct ProgrammerStat: Codable, Identifiable {
    var initials: String
    var counts: [String: Int]  // clau de l'Scan -> fitxers programats
    var id: String { initials }
    var total: Int { counts.values.reduce(0, +) }
}
struct ProgrammerSummary: Codable {
    var stats: [ProgrammerStat]
    var date: Date
}
private struct GridRow { var machine: String; var pieces: Int; var prog: String }
private struct GridPage {
    var found: Bool
    var sig: String
    var rows: [GridRow]
    var hasPiezas: Bool
    var debug: String
}
private struct ScanResult {
    var rows: [GridRow]
    var pageCounts: [Int]
    var hasPiezas: Bool
    var debug: String
}
private struct Cache: Codable {
    var date: Date
    var results: [CenterResult]
    var machines: MachineSummary?
    var programmers: ProgrammerSummary?
}

struct ScrapeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class Scraper: NSObject, ObservableObject {
    @Published var results: [CenterResult] = []
    @Published var status = ""
    @Published var isLoading = false
    @Published var lastUpdate: Date?
    @Published var machines: MachineSummary?
    @Published var machinesNote = ""
    @Published var programmers: ProgrammerSummary?
    @Published var programmersNote = ""
    @Published var needsManualLogin = false   // mostra la web perquè facis login tu

    let webView: WKWebView
    private var activeGrid = ""          // taula que s'està llegint ara (varia segons la pàgina)

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // guarda les galetes de sessió
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: cfg)
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        // Mostra al moment l'última lectura mentre es calcula la nova
        if let d = UserDefaults.standard.data(forKey: "cache"),
           let c = try? JSONDecoder().decode(Cache.self, from: d) {
            results = c.results
            lastUpdate = c.date
            machines = c.machines
            programmers = c.programmers
        }
    }

    // MARK: - Flux principal
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            status = "Connectant…"
            // Marca la pàgina actual com a "vella": no llegirem res fins que carregui la nova.
            _ = try? await js("window.__stale = 1")
            webView.load(URLRequest(url: Config.cadcamURL))
            try await ensureLoggedIn()

            // Comencem pel centre on ja som (cap recàrrega extra) i després l'altre.
            let here = await currentCenter()
            let ordered = Config.centers.filter { $0.name == here } + Config.centers.filter { $0.name != here }

            var got: [String: CenterResult] = [:]
            for c in ordered {
                status = "Llegint \(c.name)…"
                try await switchCenter(to: c.name)
                let raw = try await readCounts()
                let mats = c.materials.map {
                    MaterialCount(id: $0, prog: raw["\($0)Prog"] ?? nil, mec: raw["\($0)Prod"] ?? nil)
                }
                // Si cap enllaç no existeix, la pàgina no s'ha carregat bé: error, no zeros falsos.
                if mats.allSatisfy({ $0.prog == nil && $0.mec == nil }) {
                    throw ScrapeError(message: "No s'han pogut llegir dades de \(c.name)")
                }
                got[c.name] = CenterResult(id: c.name, materials: mats)
            }
            let out = Config.centers.compactMap { got[$0.name] }
            results = out
            lastUpdate = Date()
            saveCache()
            status = ""

            // Taules de Fase Mecanitzat: màquines de Zirconi + programadors (en segon pla, els números de dalt ja es veuen)
            if Config.trackMachines || Config.trackProgrammers {
                await scanAll()
            }
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: - Login
    // El login té reCAPTCHA. Primer provem d'omplir-lo i prémer el botó automàticament;
    // si no entra en ~15 s, mostrem la web perquè facis el login a mà (un cop).
    private func ensureLoggedIn() async throws {
        var submittedAt: Int? = nil, lastPortal = -100, portalDone = false, portalTries = 0
        defer { needsManualLogin = false }
        for i in 0..<600 {                                  // ~2 min
            let s = (try? await js(Self.stateJS)) as? String ?? "wait"
            switch s {
            case "app": return
            case "login":
                if submittedAt == nil {
                    if let u = Keychain.get("user"), let p = Keychain.get("pass") {
                        status = "Enviant el login…"
                        _ = try? await js("""
                        (() => {
                          const set = (sel, v) => { const e = document.querySelector(sel);
                            e.value = v; e.dispatchEvent(new Event('input', {bubbles:true}));
                            e.dispatchEvent(new Event('change', {bubbles:true})); };
                          set(\(q(Config.userSelector)), \(q(u)));
                          set(\(q(Config.passSelector)), \(q(p)));
                          document.querySelector(\(q(Config.buttonSelector))).click();
                        })()
                        """)
                        submittedAt = i
                    } else {
                        needsManualLogin = true             // sense credencials: login manual
                    }
                } else if i - submittedAt! > 75 {
                    needsManualLogin = true                 // el reCAPTCHA no ha deixat: login manual
                }
                if needsManualLogin { status = "Fes login a la web que apareix" }
            case "other" where submittedAt != nil:
                // Després del login surt el portal d'icones: entrem a CADCAM MANAGER (enllaç /CCManager).
                if i - lastPortal > 50 || (!portalDone && i - lastPortal > 10) {
                    lastPortal = i
                    status = "Entrant a CadCam Manager…"
                    if !portalDone {
                        let r = (try? await js(Self.portalJS)) as? String ?? "none"
                        if r.hasPrefix("href:"), let u = URL(string: String(r.dropFirst(5))) {
                            portalDone = true
                            webView.load(URLRequest(url: u))
                        } else if r == "clicked" {
                            portalDone = true
                        } else {
                            portalTries += 1                       // el portal potser encara no ha pintat les icones
                            if portalTries >= 3 { portalDone = true; webView.load(URLRequest(url: Config.cadcamURL)) }
                        }
                    } else {
                        // Ja hem passat pel portal: ara sí, anem a la pàgina de fases
                        webView.load(URLRequest(url: Config.cadcamURL))
                    }
                }
            default: break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ScrapeError(message: "Temps d'espera esgotat. Última pàgina: \(webView.url?.host ?? "cap")\(webView.url?.path ?? "")")
    }

    // MARK: - Canvi de centre
    private func currentCenter() async -> String? {
        try? await js("document.querySelector('#\(Config.comboId) input.rcbInput')?.value") as? String
    }

    private func switchCenter(to name: String) async throws {
        if await currentCenter() == name { return }
        // Marca: desapareix quan la pàgina es recarrega (postback), així no llegim dades velles.
        _ = try await js("window.__marker = 1; $find('\(Config.comboId)').findItemByText(\(q(name))).select();")
        for _ in 0..<200 {                                  // ~30 s
            try await Task.sleep(nanoseconds: 150_000_000)
            let marker = try? await js("window.__marker === 1 ? 'old' : 'new'") as? String
            let state = try? await js(Self.stateJS) as? String
            if marker == "new", state == "app", await currentCenter() == name { return }
        }
        throw ScrapeError(message: "No s'ha pogut canviar a \(name)")
    }

    // MARK: - Lectura
    private func readCounts() async throws -> [String: Int?] {
        let ids = Config.centers.flatMap { $0.materials }.flatMap { ["\($0)Prog", "\($0)Prod"] }
        let json = try await js("""
        (() => {
          const ids = \(q(ids)); const out = {};
          ids.forEach(id => {
            const a = document.getElementById('\(Config.menuPrefix)' + id);
            if (!a) { out[id] = null; return; }
            const m = a.textContent.match(/\\((\\d+)\\)/);
            out[id] = m ? parseInt(m[1]) : 0;   // sense parèntesis = 0
          });
          return JSON.stringify(out);
        })()
        """) as? String ?? "{}"
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
        return obj.mapValues { $0 as? Int }
    }

    // MARK: - Taules de Fase Mecanitzat (màquines de Zirconi + programadors)
    private func saveCache() {
        guard let d = lastUpdate,
              let enc = try? JSONEncoder().encode(Cache(date: d, results: results, machines: machines, programmers: programmers)) else { return }
        UserDefaults.standard.set(enc, forKey: "cache")
    }

    private func expectedFiles(_ scan: Config.Scan) -> Int? {
        results.first { $0.id == scan.center }?.materials.first { $0.id == scan.material }?.mec
    }

    private func scanAll() async {
        machinesNote = ""
        programmersNote = ""
        let here = await currentCenter()
        var currentC = here ?? ""
        let ordered = Config.scans.filter { $0.center == here } + Config.scans.filter { $0.center != here }
        var rowsByKey: [String: [GridRow]] = [:]
        var notes: [String] = []
        var zrPages: [Int] = []

        for scan in ordered {
            status = "Llegint \(scan.label)…"
            do {
                if scan.center != currentC {
                    try await goToMainPage()            // el selector de centre és a la pàgina d'entrada
                    try await switchCenter(to: scan.center)
                    currentC = scan.center
                }
                activeGrid = scan.grid
                let r = try await scanGrid(scan.url, expectRows: (expectedFiles(scan) ?? 1) > 0)
                rowsByKey[scan.key] = r.rows
                if scan.key == Config.zirconiKey {
                    zrPages = r.pageCounts
                    if r.rows.isEmpty && !r.debug.isEmpty {
                        machinesNote = "No trobo la taula de Zirconi. [" + r.debug + "]"
                    }
                    if !r.hasPiezas && !r.rows.isEmpty {
                        machinesNote = "No trobo la columna «Nº Piezas». " + String(r.debug.prefix(300))
                    }
                }
                if let e = expectedFiles(scan), e != r.rows.count {
                    var m = "\(scan.label): he llegit \(r.rows.count) fitxers i el menú en diu \(e)."
                    if !r.pageCounts.isEmpty { m += " Per pàgines: " + r.pageCounts.map(String.init).joined(separator: " + ") }
                    if r.rows.isEmpty && !r.debug.isEmpty { m += " [" + r.debug + "]" }
                    notes.append(m)
                }
            } catch {
                notes.append("\(scan.label): \(error.localizedDescription)")
                if scan.key == Config.zirconiKey { machinesNote = error.localizedDescription }
            }
        }

        // Zirconi: peces per màquina
        if Config.trackMachines, let zr = rowsByKey[Config.zirconiKey] {
            var map: [String: MachineStat] = [:]
            for r in zr {
                var st = map[r.machine] ?? MachineStat(machine: r.machine, pieces: 0, cases: 0)
                st.pieces += r.pieces
                st.cases += 1
                map[r.machine] = st
            }
            var out = Config.machineNames.map { map[$0] ?? MachineStat(machine: $0, pieces: 0, cases: 0) }
            out += map.values.filter { !Config.machineNames.contains($0.machine) }.sorted { $0.machine < $1.machine }
            machines = MachineSummary(stats: out, date: Date(), pageCounts: zrPages)
        }

        // Programadors: fitxers per inicials i per material/centre
        if Config.trackProgrammers && !rowsByKey.isEmpty {
            var byProg: [String: [String: Int]] = [:]
            for (key, rows) in rowsByKey {
                for r in rows where !r.prog.isEmpty {
                    byProg[r.prog, default: [:]][key, default: 0] += 1
                }
            }
            let stats = byProg.map { ProgrammerStat(initials: $0.key, counts: $0.value) }
                .sorted { ($0.total, $1.initials) > ($1.total, $0.initials) }
            programmers = ProgrammerSummary(stats: stats, date: Date())
        }

        programmersNote = notes.joined(separator: "\n")
        saveCache()
        status = ""
    }

    private func goToMainPage() async throws {
        _ = try? await js("window.__stale = 1")
        webView.load(URLRequest(url: Config.cadcamURL))
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 150_000_000)
            let st = (try? await js(Self.stateJS)) as? String
            if st == "app" { return }
        }
        throw ScrapeError(message: "No he pogut tornar a la pàgina principal")
    }

    /// Carrega una pàgina de Fase Mecanizado i en llegeix totes les pàgines de la taula (de 20 en 20).
    private func scanGrid(_ url: URL, expectRows: Bool) async throws -> ScanResult {
        _ = try? await js("window.__stale = 1")
        webView.load(URLRequest(url: url))
        var page = try await waitForGrid(expectRows: expectRows)
        if !page.found {
            let dbg = (try? await js(diagJS)) as? String ?? ""
            return ScanResult(rows: [], pageCounts: [], hasPiezas: false, debug: dbg)
        }

        let first = page
        var all = page.rows
        var counts = [page.rows.count]
        var n = 2
        while n <= 80 {
            let r = (try? await js(clickPageJS(n))) as? String
            if r != "ok" { break }                                   // no hi ha pàgina n: hem acabat
            page = try await waitForNewPage(after: page.sig)
            all += page.rows
            counts.append(page.rows.count)
            n += 1
        }
        return ScanResult(rows: all, pageCounts: counts, hasPiezas: first.hasPiezas, debug: first.debug)
    }

    private func waitForGrid(expectRows: Bool) async throws -> GridPage {
        let patience = expectRows ? 130 : 20          // ~20 s si el menú diu que hi ha fitxers, ~3 s si no
        var nogrid = 0
        var clicks = 0
        for _ in 0..<200 {                                           // ~30 s
            try await Task.sleep(nanoseconds: 150_000_000)
            let st = (try? await js(gridStateJS)) as? String ?? "wait"
            if st == "grid", let p = await readGridPage(), p.found, !p.rows.isEmpty { return p }
            if st == "nogrid" {
                nogrid += 1
                // Pot ser que la pestanya activa no sigui "Disponibles": la toquem com faries tu.
                if expectRows && nogrid == 8 && clicks < 2 {
                    let r = (try? await js(clickTabJS)) as? String
                    if r == "ok" { clicks += 1; nogrid = 0 }
                }
                if nogrid > patience { return GridPage(found: false, sig: "", rows: [], hasPiezas: false, debug: "") }   // taula buida o no trobada
            } else { nogrid = 0 }
        }
        throw ScrapeError(message: "No he pogut llegir la taula")
    }

    private func waitForNewPage(after sig: String) async throws -> GridPage {
        for _ in 0..<150 {                                           // ~22 s
            try await Task.sleep(nanoseconds: 150_000_000)
            if let p = await readGridPage(), p.found, !p.rows.isEmpty, p.sig != sig { return p }
        }
        throw ScrapeError(message: "No he pogut canviar de pàgina a la taula")
    }

    private func readGridPage() async -> GridPage? {
        guard let json = (try? await js(gridReadJS)) as? String,
              let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let sig = obj["sig"] as? String,
              let raw = obj["rows"] as? [[Any]] else { return nil }
        let rows: [GridRow] = raw.compactMap { r -> GridRow? in
            guard r.count == 3, let m = r[0] as? String, let p = r[1] as? Int, let g = r[2] as? String else { return nil }
            return GridRow(machine: m, pieces: p, prog: g)
        }
        return GridPage(found: obj["found"] as? Bool ?? false, sig: sig, rows: rows,
                        hasPiezas: obj["hasPiezas"] as? Bool ?? false, debug: obj["debug"] as? String ?? "")
    }

    /// Nom del control tal com surt als enllaços de pàgina: ContentPlaceHolder1$PhgDisponibles$GvwGrid
    private var gridPostbackName: String {
        activeGrid.replacingOccurrences(of: "_", with: "$") + "$GvwGrid"
    }

    private var gridStateJS: String { """
    (() => {
      if (window.__stale === 1) return 'wait';
      if (document.readyState !== 'complete') return 'wait';
      const G = '\(activeGrid)_GvwGrid_';
      const has = [...document.querySelectorAll('[id^="' + G + '"]')].some(e => /_(TipoMaquina|ProgFirma)_[0-9]+$/.test(e.id));
      if (has) return 'grid';
      if (document.getElementById('\(Config.comboId)')) return 'nogrid';
      return 'wait';
    })()
    """ }

    /// Llegeix NOMÉS les files reals de la taula (ids ..._GvwGrid_TipoMaquina_0, ..._GvwGrid_ProgFirma_0, …).
    private var gridReadJS: String { """
    (() => {
      const G = '\(activeGrid)_GvwGrid_';
      const rx = new RegExp('^' + G + '(TipoMaquina|ProgFirma)_[0-9]+$');
      const num = t => { const n = parseInt((t || '').replace(/[^0-9]/g, '')); return isNaN(n) ? null : n; };

      const trs = [];
      document.querySelectorAll('[id^="' + G + '"]').forEach(e => {
        if (rx.test(e.id)) { const tr = e.closest('tr'); if (tr && trs.indexOf(tr) < 0) trs.push(tr); }
      });
      if (!trs.length) return JSON.stringify({found: false, sig: '', rows: [], hasPiezas: false, debug: ''});

      const table = trs[0].closest('table');
      let idx = -1;
      const head = [...table.rows].find(r => trs.indexOf(r) < 0 && [...r.children].some(c => /piezas/i.test(c.textContent)));
      if (head) idx = [...head.children].findIndex(c => /piezas/i.test(c.textContent));

      let ok = false;
      const rows = trs.map(tr => {
        const get = name => {
          const el = tr.querySelector('[id^="' + G + name + '_"]');
          return el ? (el.textContent || '').trim().toUpperCase() : '';
        };
        let n = null;
        const el = tr.querySelector('[id*="pieza" i]');
        if (el) n = num(el.textContent);
        if (n === null && idx >= 0 && tr.children[idx]) n = num(tr.children[idx].textContent);
        if (n !== null) ok = true;
        return [get('TipoMaquina'), n === null ? 0 : n, get('ProgFirma')];
      });

      const txt = tr => tr.textContent.replace(/\\s+/g, ' ');
      const sig = rows.length + '|' + txt(trs[0]) + '|' + txt(trs[trs.length - 1]);
      const ids = [...trs[0].querySelectorAll('[id]')].map(e => e.id.split('_').slice(-2).join('_')).join(',');
      const cells = [...trs[0].children].map(c => (c.textContent || '').trim().slice(0, 10)).join('/');
      return JSON.stringify({found: true, sig, rows, hasPiezas: ok, debug: 'ids: ' + ids + ' | cel·les: ' + cells + ' | idx=' + idx});
    })()
    """ }

    /// Toca la pestanya (Pendientes / Disponibles / Todos) que toca llegir.
    private var clickTabJS: String { """
    (() => {
      const want = '\(Config.tabName)'.toLowerCase();
      const cands = [...document.querySelectorAll('a,button,li,span,div,input,label,td')].filter(e => {
        const t = ((e.tagName === 'INPUT' ? e.value : e.textContent) || '').trim().toLowerCase();
        return t.length < 30 && (t === want || t.indexOf(want + ' ') === 0 || t.indexOf(want + '(') === 0) && e.children.length <= 2;
      });
      if (!cands.length) return 'none';
      const el = cands.find(e => e.tagName === 'A') || cands[cands.length - 1];
      el.click();
      return 'ok';
    })()
    """ }

    /// Què veu l'app quan no troba la taula (per diagnosticar-ho).
    private var diagJS: String { """
    (() => {
      const counts = {};
      document.querySelectorAll('[id*="_GvwGrid_"]').forEach(e => {
        if (/_(TipoMaquina|ProgFirma)_[0-9]+$/.test(e.id)) {
          const g = e.id.split('_GvwGrid')[0].replace('ContentPlaceHolder1_', '');
          counts[g] = (counts[g] || 0) + 1;
        }
      });
      const rowInfo = Object.keys(counts).map(k => k + '=' + counts[k]).join(', ') || 'cap fila en cap taula';
      const grids = [...new Set([...document.querySelectorAll('[id*="_GvwGrid"]')].map(e => e.id.split('_GvwGrid')[0].replace('ContentPlaceHolder1_', '')))];
      return 'pàgina ' + location.pathname.split('/').slice(-2).join('/') + ' · llegeixo «\(activeGrid)» · taules: ' +
             (grids.slice(0, 6).join(', ') || 'cap') + ' · files per taula: ' + rowInfo;
    })()
    """ }

    private func clickPageJS(_ n: Int) -> String { """
    (() => {
      const H = '\(gridPostbackName)';
      const a = [...document.querySelectorAll('a')].find(x => {
        const h = x.getAttribute('href') || '';
        return h.indexOf(H) > -1 && h.indexOf("Page$\(n)'") > -1;
      });
      if (!a) return 'none';
      a.click();
      return 'ok';
    })()
    """ }

    // MARK: - Utilitats
    private static let portalJS = """
    (() => {
      let a = document.querySelector('a[href="/CCManager"], a[href*="CCManager" i]');
      if (!a) {
        const els = [...document.querySelectorAll('a,div,span,button,li,td')]
          .filter(e => /cadcam\\s*manager/i.test(e.textContent || '') && (e.textContent || '').length < 60);
        if (!els.length) return 'none';
        const el = els[els.length - 1];
        a = el.closest('a') || el.querySelector('a');
        if (!a) { el.click(); return 'clicked'; }
      }
      if (a.href && !/^javascript/i.test(a.href)) return 'href:' + a.href;
      a.click();
      return 'clicked';
    })()
    """

    private static let stateJS = """
    (() => {
      if (window.__stale === 1) return 'wait';
      if (document.readyState !== 'complete') return 'wait';
      if (window.$find && $find('\(Config.comboId)')) return 'app';
      if (document.querySelector('input[type=password]')) return 'login';
      return 'other';
    })()
    """

    private func js(_ code: String) async throws -> Any? {
        try await webView.evaluateJavaScript(code)
    }

    /// Converteix un valor Swift en literal JavaScript segur.
    private func q(_ v: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [v])
        let s = String(data: data ?? Data("[null]".utf8), encoding: .utf8) ?? "[null]"
        return String(s.dropFirst().dropLast())
    }
}

// WebView invisible però dins la jerarquia (iOS el throttleja si no hi és)
struct HiddenWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// Si la web obre una pestanya nova, la carreguem dins la mateixa vista.
extension Scraper: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

// iOS pot matar el procés de la web quan l'app és en segon pla: la recarreguem.
extension Scraper: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
