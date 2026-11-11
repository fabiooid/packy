import Foundation

/// v1 packing userflow rules and the copy that those rules need.
/// Layout and chrome stay in the existing screens.
enum PackingFlow {
    static let signInPurpose = "Tutto il giorno a inscatolare"
    static let operatorField = "Nome utente"
    static let operatorHint = "es. ana"
    static let sampleMode = "Ordini di prova per test locali. Non sono dati reali dei clienti."
    static let listHeading = "Ordini"
    static let listPurpose = "Inizia un ordine, finiscilo, poi passa al successivo."
    static let startAction = "Imballa"
    static let leaveAction = "Esci senza imballare"
    static let emptyOrders = "Nessun ordine da imballare dalle fonti che hanno risposto."
    static let sourceFailed = "Impossibile raggiungere una fonte: potrebbero esserci ordini che non vedi."
    static let productListHint = "Scansiona ogni prodotto. L'elenco lo tiene in conto."
    static let cameraWaiting = "Inquadra un codice a barre."
    static let cameraSimulator = "Il simulatore non ha la fotocamera. Scegli un codice di prova, poi confermalo come faresti sul telefono."
    static let rightProduct = "Prodotto giusto. Non ancora contato."
    static let countAction = "Aggiungi"
    static let markDoneConfirm = "Confermi che la scatola corrisponde all'ordine. Non lo spedisce."
    static let wrongProductTitle = "Prodotto sbagliato. Non contato."

    static func countLabel(verified: Int, required: Int) -> String {
        "\(verified)/\(required)"
    }

    /// Leave is allowed only before any unit has been counted.
    static func canLeave(status: String, isOwner: Bool, hasRecordedCount: Bool) -> Bool {
        status == "active" && isOwner && !hasRecordedCount
    }

    /// After a count, the operator stays on this order until it is packed.
    static func sessionLocked(status: String, isOwner: Bool, hasRecordedCount: Bool) -> Bool {
        status == "active" && isOwner && hasRecordedCount
    }

    static func hasRecordedCount(verified: Int, uncertain: Int) -> Bool {
        verified > 0 || uncertain > 0
    }

    static func packableOrders(_ orders: [WorkloadOrder]) -> [WorkloadOrder] {
        orders.filter { $0.eligible && $0.packStatus != "completed" }
    }

    static func activeOwnedOrder(_ orders: [WorkloadOrder]) -> WorkloadOrder? {
        orders.first { $0.packStatus == "active" && $0.isOwner }
    }

    static func orderSourceFailed(_ sources: [SourceState]) -> Bool {
        sources.contains { $0.name != "fic" && $0.status == "unavailable" }
    }

    static func emptyListMessage(sourceFailed: Bool) -> String {
        sourceFailed ? Self.sourceFailed : emptyOrders
    }

    static func wrongProductMessage(stillNeeds: String) -> String {
        "Prodotto sbagliato. Non contato. A questo ordine manca ancora \(stillNeeds)."
    }

    /// Splits a trailing size off a product name, so the size can be shown as its own badge.
    /// "Cardamomo Sapone Mani 250ml" becomes ("Cardamomo Sapone Mani", "250 ml").
    static func splitSize(_ name: String) -> (name: String, size: String?) {
        let pattern = #"^(.*?)[\s,]*(\d+(?:[.,]\d+)?)\s?(ml|g|kg|l|oz)\.?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let base = Range(match.range(at: 1), in: name),
              let amount = Range(match.range(at: 2), in: name),
              let unit = Range(match.range(at: 3), in: name),
              !name[base].trimmingCharacters(in: .whitespaces).isEmpty
        else { return (name, nil) }
        return (name[base].trimmingCharacters(in: .whitespaces), "\(name[amount]) \(name[unit].lowercased())")
    }

    /// Units still to count across the order, including ones that must be checked again.
    static func unitsStillToDo(_ lines: [Line]) -> Int {
        lines.reduce(0) { $0 + $1.remaining + $1.uncertain }
    }

    static func unitWord(_ count: Int) -> String { count == 1 ? "pezzo" : "pezzi" }

    /// Barcoded lines still go through scan then Aggiungi. Everything else with no usable barcode is confirmed by hand.
    static func needsScan(_ line: Line) -> Bool {
        line.verification?.method == "barcode"
    }

    /// Pieces that go in the box. Shipping rows are confirmed but not counted.
    static func pieces(_ lines: [Line]) -> (counted: Int, total: Int) {
        lines.filter { !$0.shipping }.reduce((0, 0)) { ($0.0 + $1.verified, $0.1 + $1.required) }
    }

    /// "Hai letto X (code)." for a wrong read. It never suggests the right product: a guess invites a second wrong pick.
    static func wrongReadDetail(scan: Scan) -> String {
        let read = [scan.productName, scan.codice.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        return "Hai letto \(read.isEmpty ? scan.barcode : read)."
    }

    static func canManualConfirm(_ line: Line) -> Bool {
        line.canManualConfirm
    }

    /// Aggiungi in the camera header. A barcoded line needs a matching eligible scan first; a barcodeless line does not.
    static func canConfirmFromHeader(line: Line, pendingScan: Scan?) -> Bool {
        if needsScan(line) {
            return pendingScan?.outcome == "eligible" && pendingScan?.lineId == line.lineId
        }
        return canManualConfirm(line)
    }
}
