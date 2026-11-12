import Foundation

struct LoginResponse: Decodable {
    let token: String
}

struct Freshness: Decodable {
    let state: String
    let pulledAt: Int
    let message: String?
}

struct SourceState: Decodable, Identifiable {
    let name: String
    let status: String
    let errorCode: String?
    let lastSuccessAt: Int?
    var id: String { name }

    var displayName: String {
        // Source names come from the server's connector list. The app knows no platform.
        switch name {
        case "products": "Elenco prodotti"
        case "fixture": "Ordini di prova"
        default: name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

struct WorkloadOrder: Decodable, Identifiable {
    let source: String
    let orderId: String
    let reference: String
    let recipient: String?
    let eligible: Bool
    let ineligibleReason: String?
    let units: Int
    let packId: String?
    let packStatus: String?
    let ownerName: String?
    let isOwner: Bool
    let verified: Int
    let changedAfterCompletion: Bool
    let blockedLines: Int
    let freshness: Freshness
    var id: String { source + orderId }
}

/// A finished order for the "Preparati" tab. Read-only.
struct PackedOrder: Decodable, Identifiable {
    let completedAt: Double
    let source: String
    let reference: String
    let recipient: String?
    let completedByName: String
    let units: Int
    /// Pieces marked out of stock when it was packed. 0 or nil means complete.
    var shortUnits: Int?
    var id: String { "\(source)|\(reference)|\(completedAt)" }
    var date: Date { Date(timeIntervalSince1970: completedAt / 1000) }
}

struct PackedList: Decodable {
    let total: Int
    let orders: [PackedOrder]
}

struct Workload: Decodable {
    let fixture: Bool
    let sources: [SourceState]
    let orders: [WorkloadOrder]
}

struct Identity: Decodable {
    let status: String
    let codice: String?
    let productName: String?
    let reason: String?
    let sourceTitle: String
}

struct Verification: Decodable {
    let method: String
    let reason: String?
}

struct PackedUnit: Decodable, Identifiable {
    let id: String
    let status: String
    let confirmedAt: Int
    let confirmedBy: String
}

struct Line: Decodable, Identifiable {
    let lineId: String
    let kind: String
    let kindReason: String?
    let required: Int
    let verified: Int
    let uncertain: Int
    let remaining: Int
    let state: String
    let identity: Identity
    let verification: Verification?
    let units: [PackedUnit]
    let canManualConfirm: Bool
    /// Shipping row: confirmed by hand (label on the box), never counted as a piece. Optional so older servers still decode.
    let isShipping: Bool?
    /// Pieces marked out of stock. Optional (var) so older servers and test fixtures still work.
    var short: Int?
    var canMarkShort: Bool?
    /// Not in the product list: shown as "Custom" with its title from the order, confirmed by hand.
    var isCustom: Bool?
    var custom: Bool { isCustom ?? false }
    var shipping: Bool { isShipping ?? false }
    var shortCount: Int { short ?? 0 }
    var id: String { lineId }
}

struct NonPhysicalRow: Decodable, Identifiable {
    let title: String
    let reason: String
    var id: String { title + reason }
}

struct Discrepancy: Decodable, Identifiable {
    let id: String
    let kind: String
    let barcode: String?
    let title: String
    let detail: String
    let readCount: Int
    let resolutions: [String]
}

struct Change: Decodable, Identifiable {
    let lineId: String
    let kind: String
    let message: String
    var id: String { lineId + kind }
}

struct Blocker: Decodable, Identifiable {
    let code: String
    let message: String
    let lineId: String?
    var id: String { code + message }
}

struct Pack: Decodable {
    let id: String
    let source: String
    let orderId: String
    let reference: String
    let recipient: String?
    let status: String
    let version: Int
    let isOwner: Bool
    let ownerName: String
    let fixture: Bool
    let eligible: Bool
    let ineligibleReason: String?
    let freshness: Freshness
    let lines: [Line]
    let nonPhysical: [NonPhysicalRow]
    let discrepancies: [Discrepancy]
    let changes: [Change]
    let blockers: [Blocker]
    let canComplete: Bool
    let completedAt: Int?
    let completedByName: String?
    let changedAfterCompletion: Bool
    let limitsNote: String
    let hasRecordedCount: Bool
    let canLeave: Bool
    /// Some pieces were marked out of stock: the box ships without them.
    var partial: Bool?
    var canScan: Bool { status == "active" && isOwner && eligible && changes.isEmpty }
}

struct Scan: Decodable {
    let id: String
    let outcome: String
    let barcode: String
    let codice: String?
    let productName: String?
    let message: String
    let unitNumber: Int?
    let required: Int?
    let recheck: Bool
    let discrepancyId: String?
    let lineId: String?
}

struct ScanResponse: Decodable {
    let scan: Scan
    let pack: Pack
}
