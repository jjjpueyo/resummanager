import SwiftUI
import WebKit

struct MaterialCount: Identifiable {
    let id: String          // "Titanio"
    let prog: Int?          // nil = no apareix en aquest centre
    let mec: Int?
}
struct CenterResult: Identifiable {
    let id: String          // "Ourense"
    let materials: [MaterialCount]
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
    @Published var needsManualLogin = false   // mostra la web perquè facis login tu

    let webView: WKWebView

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // guarda les galetes de sessió
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: cfg)
        super.init()
    }

    // MARK: - Flux principal
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            status = "Connectant…"
            webView.load(URLRequest(url: Config.cadcamURL))
            try await ensureLoggedIn()

            var out: [CenterResult] = []
            for c in Config.centers {
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
                out.append(CenterResult(id: c.name, materials: mats))
            }
            results = out
            lastUpdate = Date()
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: - Login
    // El login té reCAPTCHA. Primer provem d'omplir-lo i prémer el botó automàticament;
    // si no entra en ~15 s, mostrem la web perquè facis el login a mà (un cop).
    private func ensureLoggedIn() async throws {
        var submittedAt: Int? = nil, navigated = false
        defer { needsManualLogin = false }
        for i in 0..<240 {                                  // ~2 min
            let s = (try? await js(Self.stateJS)) as? String ?? "wait"
            switch s {
            case "app": return
            case "login":
                if submittedAt == nil {
                    if let u = Keychain.get("user"), let p = Keychain.get("pass") {
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
                } else if i - submittedAt! > 30 {
                    needsManualLogin = true                 // el reCAPTCHA no ha deixat: login manual
                }
                if needsManualLogin { status = "Fes login a la web que apareix" }
            case "other" where submittedAt != nil && !navigated:
                webView.load(URLRequest(url: Config.cadcamURL))
                navigated = true
            default: break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ScrapeError(message: "Temps d'espera esgotat (login o xarxa/VPN)")
    }

    // MARK: - Canvi de centre
    private func currentCenter() async -> String? {
        try? await js("document.querySelector('#\(Config.comboId) input.rcbInput')?.value") as? String
    }

    private func switchCenter(to name: String) async throws {
        if await currentCenter() == name { return }
        // Marca: desapareix quan la pàgina es recarrega (postback), així no llegim dades velles.
        _ = try await js("window.__marker = 1; $find('\(Config.comboId)').findItemByText(\(q(name))).select();")
        for _ in 0..<60 {                                   // ~30 s
            try await Task.sleep(nanoseconds: 500_000_000)
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

    // MARK: - Utilitats
    private static let stateJS = """
    (() => {
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
