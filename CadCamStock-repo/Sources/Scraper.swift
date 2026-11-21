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
    var cases: Int       // nombre de files (casos)
    var id: String { machine }
}
struct MachineSummary: Codable {
    var stats: [MachineStat]
    var date: Date
}
private struct GridPage {
    var sig: String
    var rows: [(String, Int)]
    var pages: [Int]
    var hasPiezas: Bool
    var debug: String
}
private struct Cache: Codable { var date: Date; var results: [CenterResult]; var machines: MachineSummary? }

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
    @Published var needsManualLogin = false   // mostra la web perquè facis login tu

    let webView: WKWebView

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

            // Zirconi per màquina (en segon pla: els números de dalt ja es veuen)
            if Config.trackMachines {
                status = "Llegint màquines de Zirconi…"
                machinesNote = ""
                do {
                    let stats = try await readMachines()
                    machines = MachineSummary(stats: stats, date: Date())
                    saveCache()
                } catch {
                    machinesNote = error.localizedDescription
                }
                status = ""
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

    // MARK: - Zirconi per màquina
    private func saveCache() {
        guard let d = lastUpdate,
              let enc = try? JSONEncoder().encode(Cache(date: d, results: results, machines: machines)) else { return }
        UserDefaults.standard.set(enc, forKey: "cache")
    }

    private func readMachines() async throws -> [MachineStat] {
        if await currentCenter() != Config.machineCenter { try await switchCenter(to: Config.machineCenter) }
        _ = try? await js("window.__stale = 1")
        webView.load(URLRequest(url: Config.machinesURL))

        var page = try await waitForGrid()
        if page.rows.isEmpty { return Config.machineNames.map { MachineStat(machine: $0, pieces: 0, cases: 0) } }
        guard page.hasPiezas else { throw ScrapeError(message: "No trobo la columna «Nº Piezas». " + String(page.debug.prefix(400))) }

        var all = page.rows
        // Va passant a la pàgina següent fins que no n'hi ha més (de 20 en 20: funciona amb 1, 3 o 15 pàgines).
        var n = 2
        while n <= 80 {
            let r = (try? await js(clickPageJS(n))) as? String
            if r != "ok" { break }                               // no hi ha pàgina n: hem acabat
            status = "Llegint màquines (pàgina \(n))…"
            page = try await waitForNewPage(after: page.sig)
            all += page.rows
            n += 1
        }

        var map: [String: MachineStat] = [:]
        for (m, p) in all {
            var st = map[m] ?? MachineStat(machine: m, pieces: 0, cases: 0)
            st.pieces += p
            st.cases += 1
            map[m] = st
        }
        var out = Config.machineNames.map { map[$0] ?? MachineStat(machine: $0, pieces: 0, cases: 0) }
        out += map.values.filter { !Config.machineNames.contains($0.machine) }.sorted { $0.machine < $1.machine }
        return out
    }

    private func waitForGrid() async throws -> GridPage {
        var nogrid = 0
        for _ in 0..<200 {                                       // ~30 s
            try await Task.sleep(nanoseconds: 150_000_000)
            let st = (try? await js(gridStateJS)) as? String ?? "wait"
            if st == "grid", let p = await readGridPage(), !p.rows.isEmpty { return p }
            if st == "nogrid" {
                nogrid += 1
                if nogrid > 25 { return GridPage(sig: "", rows: [], pages: [], hasPiezas: true, debug: "") }   // taula buida
            } else { nogrid = 0 }
        }
        throw ScrapeError(message: "No he pogut llegir la taula de màquines")
    }

    private func waitForNewPage(after sig: String) async throws -> GridPage {
        for _ in 0..<150 {                                       // ~22 s
            try await Task.sleep(nanoseconds: 150_000_000)
            if let p = await readGridPage(), !p.rows.isEmpty, p.sig != sig { return p }
        }
        throw ScrapeError(message: "No he pogut canviar de pàgina a la taula")
    }

    private func readGridPage() async -> GridPage? {
        guard let json = (try? await js(gridReadJS)) as? String,
              let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let sig = obj["sig"] as? String,
              let raw = obj["rows"] as? [[Any]] else { return nil }
        let rows: [(String, Int)] = raw.compactMap { r -> (String, Int)? in
            guard r.count == 2, let m = r[0] as? String, let p = r[1] as? Int else { return nil }
            return (m, p)
        }
        return GridPage(sig: sig, rows: rows, pages: obj["pages"] as? [Int] ?? [], hasPiezas: obj["hasPiezas"] as? Bool ?? false, debug: obj["debug"] as? String ?? "")
    }

    private var gridStateJS: String { """
    (() => {
      if (window.__stale === 1) return 'wait';
      if (document.readyState !== 'complete') return 'wait';
      if (document.querySelector('[id^="\(Config.machineGrid)"][id*="TipoMaquina_"]')) return 'grid';
      if (document.getElementById('\(Config.menuPrefix)ZirconioProd')) return 'nogrid';
      return 'wait';
    })()
    """ }

    private var gridReadJS: String { """
    (() => {
      const spans = [...document.querySelectorAll('[id^="\(Config.machineGrid)"][id*="TipoMaquina_"]')];
      if (!spans.length) return JSON.stringify({sig: '', rows: [], pages: [], hasPiezas: true, debug: ''});
      const table = spans[0].closest('table');
      const num = t => { const n = parseInt((t || '').replace(/[^0-9]/g, '')); return isNaN(n) ? null : n; };

      // Columna "Nº Piezas": (1) capçalera dins la mateixa taula, (2) capçalera en qualsevol lloc de la pàgina
      let idx = -1;
      const head = [...table.rows].find(r => !r.querySelector('[id*="TipoMaquina_"]') &&
                                             [...r.children].some(c => /piezas/i.test(c.textContent)));
      if (head) idx = [...head.children].findIndex(c => /piezas/i.test(c.textContent));
      if (idx < 0) {
        const hc = [...document.querySelectorAll('th,td')]
          .find(c => !c.querySelector('td,th') && /^\\s*n?[º°o.]?\\s*piezas\\s*$/i.test(c.textContent));
        if (hc) idx = [...hc.parentElement.children].indexOf(hc);
      }

      let ok = false;
      const rows = spans.map(sp => {
        const tr = sp.closest('tr');
        let n = null;
        // (3) element de la mateixa fila amb "pieza" a l'id (el més directe)
        const el = tr.querySelector('[id*="pieza" i]');
        if (el) n = num(el.textContent);
        if (n === null && idx >= 0 && tr.children[idx]) n = num(tr.children[idx].textContent);
        if (n !== null) ok = true;
        return [sp.textContent.trim().toUpperCase(), n === null ? 0 : n];
      });

      const pages = [...new Set([...table.querySelectorAll('a')]
        .map(a => (a.getAttribute('href') || '').match(/Page[$]([0-9]+)/))
        .filter(m => m).map(m => parseInt(m[1])))].sort((a, b) => a - b);
      const first = spans[0].closest('tr').textContent.replace(/\\s+/g, ' ');
      const last = spans[spans.length - 1].closest('tr').textContent.replace(/\\s+/g, ' ');

      const tr0 = spans[0].closest('tr');
      const ids = [...tr0.querySelectorAll('[id]')].map(e => e.id.split('_').slice(-2).join('_')).join(',');
      const cells = [...tr0.children].map(c => (c.textContent || '').trim().slice(0, 10)).join('/');
      const debug = 'ids: ' + ids + ' | cel·les: ' + cells + ' | idx=' + idx;

      return JSON.stringify({sig: rows.length + '|' + first + '|' + last, rows, pages, hasPiezas: ok, debug});
    })()
    """ }

    private func clickPageJS(_ n: Int) -> String { """
    (() => {
      const sp = document.querySelector('[id^="\(Config.machineGrid)"][id*="TipoMaquina_"]');
      const scope = sp ? sp.closest('table') : document;
      const a = [...scope.querySelectorAll('a')].find(x => (x.getAttribute('href') || '').indexOf("Page$\(n)'") > -1);
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
