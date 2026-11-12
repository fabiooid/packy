import Foundation

/// v1 packing userflow rules and the copy that those rules need.
/// Layout and chrome stay in the existing screens.
enum PackingFlow {
    static let signInPurpose = "Imballa senza errori"
    static let operatorField = "Nome utente"
    static let operatorHint = "es. ana"
    static let sampleMode = "Ordini di prova per test locali. Non sono dati reali dei clienti."
    static let sampleModeShort = "Ordini di prova · non sono dati reali"
    static let serverUnreachable = "Server non raggiungibile"
    static let listHeading = "Ordini"
    static let listPurpose = "Inizia un ordine, finiscilo, poi passa al successivo."
    static let startAction = "Imballa"
    static let leaveAction = "Esci senza imballare"
    static let emptyOrders = "Nessun ordine da imballare."
    static let sourceFailed = "Una fonte non risponde. Potrebbero mancare ordini."
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

    /// Search matches the customer or the order number, ignoring case, accents and a leading "#".
    static func matches(_ query: String, recipient: String?, reference: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !q.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return (recipient ?? "").range(of: q, options: options) != nil || reference.range(of: q, options: options) != nil
    }

    /// Packed orders grouped by day, newest first: "Oggi", "Ieri", then the date.
    static func packedGroups(_ orders: [PackedOrder], now: Date = .now, calendar: Calendar = .current) -> [(label: String, orders: [PackedOrder])] {
        let sorted = orders.sorted { $0.completedAt > $1.completedAt }
        var groups: [(label: String, orders: [PackedOrder])] = []
        for order in sorted {
            let label: String
            if calendar.isDate(order.date, inSameDayAs: now) {
                label = "Oggi"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(order.date, inSameDayAs: yesterday) {
                label = "Ieri"
            } else {
                label = order.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "it_IT"))).capitalized
            }
            if groups.last?.label == label { groups[groups.count - 1].orders.append(order) } else { groups.append((label, [order])) }
        }
        return groups
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


    /// Pieces marked out of stock across the order.
    static func shortTotal(_ lines: [Line]) -> Int {
        lines.reduce(0) { $0 + $1.shortCount }
    }

    /// What a line with out-of-stock pieces says. A product with nothing in the box reads as fully sold out.
    static func shortStatus(_ line: Line) -> String {
        line.verified + line.uncertain == 0 && line.shortCount >= line.required
            ? "Esaurito"
            : shortLabel(line.shortCount)
    }

    /// Short form for one-line rows: "Esaurito" or "9 esauriti".
    static func shortBadge(_ line: Line) -> String {
        line.verified + line.uncertain == 0 && line.shortCount >= line.required ? "Esaurito" : shortLabel(line.shortCount)
    }

    /// The menu action says what will happen: the missing ones, or the whole product when none is in the box.
    static func markShortAction(_ line: Line) -> String {
        line.verified + line.uncertain == 0 ? "Segna esaurito" : (line.remaining == 1 ? "Segna 1 esaurito" : "Segna \(line.remaining) esauriti")
    }

    static func markShortQuestion(_ line: Line) -> String {
        let name = line.identity.ficName ?? line.identity.sourceTitle
        let counted = line.verified + line.uncertain
        return counted == 0
            ? "\(name) è esaurito?"
            : "\(name): mancano \(line.remaining)?"
    }

    static func shortLabel(_ count: Int) -> String {
        count == 1 ? "1 esaurito" : "\(count) esauriti"
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
