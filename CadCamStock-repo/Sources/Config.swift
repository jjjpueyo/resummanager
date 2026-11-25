import Foundation

// Tots els valors d'aquest fitxer ja estan confirmats amb la teva web.
enum Config {
    // Pàgina d'entrada. Fem servir Titanio perquè existeix tant a España com a Ourense.
    static let cadcamURL = URL(string: "https://srv-ccmanager.phibo.com:27015/Fases/PhiboGrids/Titanio/Programacion.aspx")!

    // Selectors del login
    static let userSelector = "#Username"
    static let passSelector = "#Password"
    static let buttonSelector = "#SubmitForm"

    static let comboId = "ctl00_CboCentroProductivo"
    static let menuPrefix = "cpl_menu_sup_derecha_menuFases_"

    // ---- Taules de "Fase Mecanizado" (pestanya Disponibles) ----
    static let tabName = "Disponibles"      // pestanya que es llegeix (Pendientes / Disponibles / Todos)
    static let machineNames = ["IMES", "DATRON"]
    static let trackMachines = true         // Zirconi: peces per IMES / DATRON
    static let trackProgrammers = true      // Fitxers per programador (columna "Prog")
    static let machineCenter = "Ourense"
    static let zirconiKey = "Zr"

    /// Una pestanya addicional que també es llegeix (només per comptar programadors).
    struct Tab { let name: String; let grid: String }

    /// Una pàgina de Fase Mecanizado que l'app llegeix sencera (totes les pàgines de la taula).
    struct Scan {
        let key: String       // clau interna
        let grid: String      // nom de la taula de la pestanya "Disponibles" en aquesta pàgina
        let short: String     // capçalera de la columna
        let label: String     // text de progrés
        let center: String
        let material: String  // coincideix amb el nom del material del menú
        let url: URL
        var extraTabs: [Tab] = []   // altres pestanyes a llegir (a més de Disponibles)
    }
    private static let base = "https://srv-ccmanager.phibo.com:27015/Fases/PhiboGrids/"
    static let scans: [Scan] = [
        Scan(key: "TiES", grid: "ContentPlaceHolder1_PhgCFDisponibles", short: "Ti ES", label: "Titanio España", center: "España", material: "Titanio", url: URL(string: base + "Titanio/Produccion.aspx")!, extraTabs: [Tab(name: "Pendientes", grid: "ContentPlaceHolder1_PhgCFPendientes")]),
        Scan(key: "TiOU", grid: "ContentPlaceHolder1_PhgCFDisponibles", short: "Ti OU", label: "Titanio Ourense", center: "Ourense", material: "Titanio", url: URL(string: base + "Titanio/Produccion.aspx")!, extraTabs: [Tab(name: "Pendientes", grid: "ContentPlaceHolder1_PhgCFPendientes")]),
        Scan(key: "Zr", grid: "ContentPlaceHolder1_PhgDisponibles", short: "Zr", label: "Zirconio Ourense", center: "Ourense", material: "Zirconio", url: URL(string: base + "Zirconio/ZrFaseProd.aspx")!),
        Scan(key: "PMMA", grid: "ContentPlaceHolder1_PhgCFDisponibles", short: "PMMA", label: "PMMA Ourense", center: "Ourense", material: "PMMA", url: URL(string: base + "PMMA/PMMAFaseMec.aspx")!),
    ]

    struct Center { let name: String; let materials: [String] }
    static let centers = [
        Center(name: "España", materials: ["Titanio"]),
        Center(name: "Ourense", materials: ["Zirconio", "Titanio", "PMMA"]),
    ]
}
