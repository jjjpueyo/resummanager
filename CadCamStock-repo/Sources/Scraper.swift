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
    var expected: Int?        // fitxers que diu el menú per a aquest material
    var mainCount: Int        // files de la pestanya principal (Disponibles): és la que ha de quadrar amb el menú
    var pageNote: String      // si no s'ha pogut passar de pàgina, per què
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
    private var got: [String: CenterResult] = [:]   // números per centre, llegits dels menús
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

            got = [:]
            status = "Llegint dades…"
            let here = await currentCenter() ?? ""
            // Els números del centre actual surten de la pàgina d'entrada: es veuen al moment.
            guard await captureCounts() != nil else {
                throw ScrapeError(message: "No s'han pogut llegir dades de \(here)")
            }
            lastUpdate = Date()
            saveCache()
            status = ""

            if Config.trackMachines || Config.trackProgrammers {
                // Taules de Fase Mecanitzat: també ens donen els números de l'altre centre (el menú hi és a totes les pàgines).
                await scanAll(here: here)
            } else {
                for c in Config.centers where c.name != here {
                    try await switchCenter(to: c.name)
                    _ = await captureCounts()
                }
            }
            lastUpdate = Date()
            saveCache()
            status = ""
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

    /// Llegeix els números del menú de la pàgina actual i els guarda per al centre que mostra el selector.
    private func captureCounts() async -> [String: Int?]? {
        guard let center = await currentCenter(),
              let c = Config.centers.first(where: { $0.name == center }),
              let raw = try? await readCounts() else { return nil }
        let mats = c.materials.map {
            MaterialCount(id: $0, prog: raw["\($0)Prog"] ?? nil, mec: raw["\($0)Prod"] ?? nil)
        }
        // Si cap enllaç no existeix, la pàgina no s'ha carregat bé: res (millor que uns zeros falsos).
        if mats.allSatisfy({ $0.prog == nil && $0.mec == nil }) { return nil }
        got[center] = CenterResult(id: center, materials: mats)
        publishPartial()
        return raw
    }

    private func publishPartial() {
        var out: [CenterResult] = []
        for c in Config.centers {
            if let r = got[c.name] { out.append(r) }
            else if let old = results.first(where: { $0.id == c.name }) { out.append(old) }
        }
        results = out
    }

    private func scanAll(here: String) async {
        machinesNote = ""
        programmersNote = ""
        var rowsByKey: [String: [GridRow]] = [:]
        var notes: [String] = []
        var zrPages: [Int] = []

        // Ordre pensat per estalviar recàrregues: Titanio és a les dues bandes, així que després de llegir-lo
        // en un centre canviem de centre SOBRE LA MATEIXA PÀGINA (true = carregar pàgina, false = ja hi som).
        let plan: [(String, Bool)] = (here == "España")
            ? [("TiES", true), ("TiOU", false), ("Zr", true), ("PMMA", true)]
            : [("Zr", true), ("PMMA", true), ("TiOU", true), ("TiES", false)]

        for (key, load) in plan {
            guard let sc = Config.scans.first(where: { $0.key == key }) else { continue }
            status = "Llegint \(sc.label)…"
            do {
                if !load { try await switchCenter(to: sc.center) }
                activeGrid = sc.grid
                let r = try await scanGrid(sc, load: load)
                rowsByKey[sc.key] = r.rows
                if sc.key == Config.zirconiKey {
                    zrPages = r.pageCounts
                    if r.mainCount == 0 && !r.debug.isEmpty {
                        machinesNote = "No trobo la taula de Zirconi. [" + r.debug + "]"
                    }
                    if !r.hasPiezas && !r.rows.isEmpty {
                        machinesNote = "No trobo la columna «Nº Piezas». " + String(r.debug.prefix(300))
                    }
                }
                if !r.pageNote.isEmpty { notes.append("\(sc.label): " + r.pageNote) }
                if let e = r.expected, e != r.mainCount {
                    var m = "\(sc.label): he llegit \(r.mainCount) fitxers i el menú en diu \(e)."
                    if !r.pageCounts.isEmpty { m += " Per pàgines: " + r.pageCounts.map(String.init).joined(separator: " + ") }
                    if r.mainCount == 0 && !r.debug.isEmpty { m += " [" + r.debug + "]" }
                    notes.append(m)
                }
            } catch {
                notes.append("\(sc.label): \(error.localizedDescription)")
                if sc.key == Config.zirconiKey { machinesNote = error.localizedDescription }
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
    }

    /// Espera que la pàgina hagi carregat (el selector de centre ja hi és).
    private func waitApp() async throws {
        for _ in 0..<300 {                                           // ~30 s
            try await Task.sleep(nanoseconds: 100_000_000)
            let st = (try? await js(Self.stateJS)) as? String
            if st == "app" { return }
        }
        throw ScrapeError(message: "La pàgina no ha carregat")
    }

    /// Llegeix una taula de Fase Mecanizado (totes les pàgines de 20 en 20). Si load és false, la pàgina ja és carregada.
    private func scanGrid(_ sc: Config.Scan, load: Bool) async throws -> ScanResult {
        if load {
            _ = try? await js("window.__stale = 1")
            webView.load(URLRequest(url: sc.url))
        }
        try await waitApp()
        // Els números del menú d'aquesta pàgina (frescos) ens diuen quants fitxers hi ha d'haver.
        let raw = await captureCounts()
        let expected: Int? = raw?["\(sc.material)Prod"] ?? nil

        var all: [GridRow] = []
        var counts: [Int] = []
        var hasPiezas = false
        var debug = ""
        var notes: [String] = []

        // Pestanya principal (Disponibles): és la que ha de quadrar amb el menú.
        let page = try await waitForGrid(expectRows: (expected ?? 1) > 0, tab: Config.tabName)
        if page.found {
            hasPiezas = page.hasPiezas
            debug = page.debug
            all = page.rows
            counts = [page.rows.count]
            let rest = await readRemainingPages(from: page, tab: Config.tabName)
            all += rest.rows
            counts += rest.counts
            if !rest.note.isEmpty { notes.append(rest.note) }
        } else {
            debug = (try? await js(diagJS)) as? String ?? ""
        }
        let mainCount = all.count

        // Pestanyes addicionals (Pendientes): per comptar programadors i màquines.
        for tab in sc.extraTabs {
            activeGrid = tab.grid
            guard let p0 = try? await waitForGrid(expectRows: false, tab: tab.name, quick: true), p0.found else { continue }
            all += p0.rows
            let rest = await readRemainingPages(from: p0, tab: tab.name)
            all += rest.rows
            if !rest.note.isEmpty { notes.append(rest.note) }
        }
        activeGrid = sc.grid
        return ScanResult(rows: all, pageCounts: counts, hasPiezas: hasPiezas, debug: debug,
                          expected: expected, mainCount: mainCount, pageNote: notes.joined(separator: " "))
    }

    /// Passa a la pàgina 2, 3… de la taula actual fins que no n'hi ha més. Si una pàgina no es pot carregar,
    /// no perdem el que ja hem llegit: tornem les files i una nota.
    private func readRemainingPages(from first: GridPage, tab: String) async -> (rows: [GridRow], counts: [Int], note: String) {
        var rows: [GridRow] = []
        var counts: [Int] = []
        var page = first
        var n = 2
        while n <= 80 {
            let target = (try? await js(pageInfoJS(n))) as? String ?? ""
            if target.isEmpty { break }                               // no hi ha pàgina n: hem acabat
            guard let next = await changePage(to: n, target: target, from: page.sig, tab: tab) else {
                let d = (try? await js(pagerDiagJS)) as? String ?? ""
                return (rows, counts, "\(tab): no he pogut passar a la pàgina \(n) [\(d)]")
            }
            page = next
            rows += next.rows
            counts.append(next.rows.count)
            n += 1
        }
        return (rows, counts, "")
    }

    private func waitChange(_ sig: String, polls: Int) async -> GridPage? {
        for _ in 0..<polls {
            _ = try? await Task.sleep(nanoseconds: 100_000_000)
            if let p = await readGridPage(), p.found, !p.rows.isEmpty, p.sig != sig { return p }
        }
        return nil
    }

    /// Canvia de pàgina de tres maneres, de més simple a més insistent.
    private func changePage(to n: Int, target: String, from sig: String, tab: String) async -> GridPage? {
        // 1) clic a l'enllaç de la pàgina
        _ = try? await js(clickPageJS(n))
        if let p = await waitChange(sig, polls: 80) { return p }
        // 2) crida directa al postback d'ASP.NET
        _ = try? await js(postbackPageJS(n, target: target))
        if let p = await waitChange(sig, polls: 80) { return p }
        // 3) tornem a tocar la pestanya i repetim el clic
        _ = try? await js(clickTabJS(0, tab: tab))
        _ = try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = try? await js(clickPageJS(n))
        return await waitChange(sig, polls: 100)
    }

    private func waitForGrid(expectRows: Bool, tab: String, quick: Bool = false) async throws -> GridPage {
        let patience = quick ? 70 : (expectRows ? 200 : 30)   // ~20 s si el menú diu que hi ha fitxers; ~7 s en una pestanya extra; ~3 s si no n'hi ha
        var nogrid = 0
        var attempt = 0
        var sinceClick = 0
        for _ in 0..<300 {                                           // ~30 s
            try await Task.sleep(nanoseconds: 100_000_000)
            let st = (try? await js(gridStateJS)) as? String ?? "wait"
            if st == "grid", let p = await readGridPage(), p.found, !p.rows.isEmpty { return p }
            if st == "nogrid" {
                nogrid += 1
                sinceClick += 1
                // Les files no surten fins que es toca la pestanya "Disponibles": ho fem com tu, provant les dues maneres.
                if (expectRows || quick) && attempt < 4 && (nogrid == 3 || sinceClick >= 25) {
                    while attempt < 4 {
                        let r = (try? await js(clickTabJS(attempt, tab: tab))) as? String ?? "none"
                        attempt += 1
                        if r == "ok" { break }
                    }
                    sinceClick = 0
                }
                if nogrid > patience { return GridPage(found: false, sig: "", rows: [], hasPiezas: false, debug: "") }   // taula buida o no trobada
            } else { nogrid = 0 }
        }
        throw ScrapeError(message: "No he pogut llegir la taula")
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

    /// Toca una pestanya (Disponibles / Pendientes…). Primer pels ids, després pel text.
    private func clickTabJS(_ attempt: Int, tab: String) -> String {
        let ids = tab == Config.tabName
            ? ["ContentPlaceHolder1_tabDisponibles", "ContentPlaceHolder1_tab"]
            : ["ContentPlaceHolder1_tab" + tab]
        return """
        (() => {
          const fire = el => ['mousedown', 'mouseup', 'click'].forEach(t =>
            el.dispatchEvent(new MouseEvent(t, {bubbles: true, cancelable: true, view: window})));
          const ids = \(q(ids));
          const n = \(attempt);
          if (n < ids.length) {
            const el = document.getElementById(ids[n]);
            if (el) { fire(el); return 'ok'; }
            return 'none';
          }
          const want = '\(tab)'.toLowerCase();
          const cands = [...document.querySelectorAll('a,button,li,span,div,input,label,td')].filter(e => {
            const t = ((e.tagName === 'INPUT' ? e.value : e.textContent) || '').trim().toLowerCase();
            return t.length < 30 && (t === want || t.indexOf(want + ' ') === 0 || t.indexOf(want + '(') === 0) && e.children.length <= 2;
          });
          if (!cands.length) return 'none';
          const el = n === ids.length ? (cands.find(e => e.tagName === 'A') || cands[cands.length - 1]) : cands[0];
          fire(el);
          return 'ok';
        })()
        """
    }

    /// Què veu l'app quan no troba la taula (per diagnosticar-ho).
    private var diagJS: String { """
    (() => {
      const P = 'ContentPlaceHolder1_';
      const grids = [...new Set([...document.querySelectorAll('[id*="_GvwGrid"]')].map(e => e.id.split('_GvwGrid')[0].replace(P, '')))];
      const info = grids.slice(0, 4).map(g => {
        const full = P + g;
        const t = document.getElementById(full + '_GvwGrid');
        const ids = [...document.querySelectorAll('[id^="' + full + '_GvwGrid_"]')]
          .map(e => e.id.replace(full + '_GvwGrid_', '')).filter(x => /_[0-9]+$/.test(x)).slice(0, 3);
        const txt = t ? (t.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 40) : '';
        return g.replace('Phg', '') + '[tr=' + (t ? t.rows.length : '—') + ' ids=' + (ids.join(',') || 'cap') + ' «' + txt + '»]';
      });
      return 'pàgina ' + location.pathname.split('/').slice(-2).join('/') + ' · llegeixo ' + '\(activeGrid)'.replace(P, '') + ' · ' + info.join(' ');
    })()
    """ }

    /// Si existeix l'enllaç a la pàgina n, torna l'objectiu del postback (o 'x'); si no, text buit.
    private func pageInfoJS(_ n: Int) -> String { """
    (() => {
      const H = '\(gridPostbackName)';
      const a = [...document.querySelectorAll('a')].find(x => {
        const h = x.getAttribute('href') || '';
        return h.indexOf(H) > -1 && h.indexOf("Page$\(n)'") > -1;
      });
      if (!a) return '';
      const m = (a.getAttribute('href') || '').match(/__doPostBack\\('([^']*)'/);
      return m ? m[1] : 'x';
    })()
    """ }

    private func postbackPageJS(_ n: Int, target: String) -> String {
        let t = target == "x" ? "ctl00$" + gridPostbackName : target
        return """
        (() => {
          window.setTimeout(function () { __doPostBack(\(q(t)), 'Page$\(n)'); }, 0);
          return 'ok';
        })()
        """
    }

    /// Què veu l'app del paginador quan no pot passar de pàgina (per diagnosticar-ho).
    private var pagerDiagJS: String { """
    (() => {
      const H = '\(gridPostbackName)';
      const links = [...document.querySelectorAll('a')].filter(x => {
        const h = x.getAttribute('href') || '';
        return h.indexOf(H) > -1 && h.indexOf('Page$') > -1;
      }).map(x => (x.textContent || '').trim());
      const n = document.querySelectorAll('[id^="\(activeGrid)_GvwGrid_"]').length;
      return 'enllaços de pàgina: ' + (links.slice(0, 8).join(',') || 'cap') + ' · elements de fila: ' + n + ' · ' + document.readyState;
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
