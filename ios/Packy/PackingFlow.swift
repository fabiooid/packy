import Foundation

/// v1 packing userflow rules and the copy that those rules need.
/// Layout and chrome stay in the existing screens.
enum PackingFlow {
    static let signInPurpose = "Check that the box matches the order, then mark it packed."
    static let operatorField = "Operator"
    static let operatorHint = "Your name."
    static let sampleMode = "Sample orders for local testing. Not live customer data."
    static let listHeading = "Orders"
    static let listPurpose = "Start one order, finish it, then take the next."
    static let startAction = "Pack"
    static let leaveAction = "Leave without packing"
    static let emptyOrders = "No orders to pack from the sources that answered."
    static let sourceFailed = "Could not reach this source, so there may be orders you cannot see."
    static let productListHint = "Scan each product. The list will track it."
    static let cameraWaiting = "Point the camera at a barcode."
    static let cameraSimulator = "This simulator has no camera. Choose a sample code, then confirm it the same way you would on a phone."
    static let rightProduct = "Right product. Not counted yet."
    static let countAction = "Count this bottle"
    static let markDoneConfirm = "You are saying the box matches this order. This does not ship it."
    static let typeNotBottle = "This code identifies the product type, not a single bottle."
    static let wrongProductTitle = "Wrong product. Not counted."

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
        "Wrong product. Not counted. This order still needs \(stillNeeds)."
    }
}
