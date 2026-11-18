import Foundation

// Tots els valors d'aquest fitxer ja estan confirmats amb la teva web.
enum Config {
    // Pàgina d'entrada. Fem servir Titanio perquè existeix tant a España com a Ourense
    // (la de Zirconio podria no carregar quan el centre actual és España).
    static let cadcamURL = URL(string: "https://srv-ccmanager.phibo.com:27015/Fases/PhiboGrids/Titanio/Programacion.aspx")!

    // Selectors del login (tots confirmats)
    static let userSelector = "#Username"                 // confirmat
    static let passSelector = "#Password"                 // confirmat
    static let buttonSelector = "#SubmitForm"            // botó "Log in" (confirmat)

    // Ja confirmats
    static let comboId = "ctl00_CboCentroProductivo"
    static let menuPrefix = "cpl_menu_sup_derecha_menuFases_"

    struct Center { let name: String; let materials: [String] }
    static let centers = [
        Center(name: "España", materials: ["Titanio"]),
        Center(name: "Ourense", materials: ["Zirconio", "Titanio", "PMMA"]),
    ]
}
