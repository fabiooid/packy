import XCTest
@testable import Packy

final class PackingFlowTests: XCTestCase {
    func testCountLabelUsesCountedOverRequired() {
        XCTAssertEqual(PackingFlow.countLabel(verified: 0, required: 3), "0/3")
        XCTAssertEqual(PackingFlow.countLabel(verified: 2, required: 3), "2/3")
        XCTAssertEqual(PackingFlow.countLabel(verified: 3, required: 3), "3/3")
    }

    func testLeaveOnlyWhenNothingHasBeenCounted() {
        XCTAssertTrue(PackingFlow.canLeave(status: "active", isOwner: true, hasRecordedCount: false))
        XCTAssertFalse(PackingFlow.canLeave(status: "active", isOwner: true, hasRecordedCount: true))
        XCTAssertFalse(PackingFlow.canLeave(status: "completed", isOwner: true, hasRecordedCount: false))
        XCTAssertFalse(PackingFlow.canLeave(status: "active", isOwner: false, hasRecordedCount: false))
    }

    func testSessionStaysLockedAfterACountUntilPacked() {
        XCTAssertTrue(PackingFlow.sessionLocked(status: "active", isOwner: true, hasRecordedCount: true))
        XCTAssertFalse(PackingFlow.sessionLocked(status: "active", isOwner: true, hasRecordedCount: false))
        XCTAssertFalse(PackingFlow.sessionLocked(status: "completed", isOwner: true, hasRecordedCount: true))
    }

    func testRecognitionIsNotACount() {
        XCTAssertFalse(PackingFlow.hasRecordedCount(verified: 0, uncertain: 0))
        XCTAssertTrue(PackingFlow.hasRecordedCount(verified: 1, uncertain: 0))
    }

    func testOrderListShowsOpenOrdersAndHidesPackedOrIneligible() {
        let orders = [
            order(id: "open", reference: "#FIX-1001", eligible: true, packStatus: nil),
            order(id: "packed", reference: "#FIX-1002", eligible: true, packStatus: "completed"),
            order(id: "unpaid", reference: "#FIX-1006", eligible: false, packStatus: nil),
            order(id: "active", reference: "#FIX-1003", eligible: true, packStatus: "active", isOwner: true),
        ]
        let packable = PackingFlow.packableOrders(orders)
        XCTAssertEqual(packable.map(\.orderId), ["open", "active"])
        XCTAssertEqual(PackingFlow.activeOwnedOrder(orders)?.orderId, "active")
    }

    func testEmptyListCopyDependsOnWhetherASourceFailed() {
        XCTAssertEqual(PackingFlow.emptyListMessage(sourceFailed: false), "Nessun ordine da imballare dalle fonti che hanno risposto.")
        XCTAssertEqual(PackingFlow.emptyListMessage(sourceFailed: true), "Impossibile raggiungere una fonte: potrebbero esserci ordini che non vedi.")
        let failed = SourceState(name: "fixture", status: "unavailable", errorCode: "fixture_unavailable", lastSuccessAt: nil)
        let catalog = SourceState(name: "fic", status: "unavailable", errorCode: "x", lastSuccessAt: nil)
        XCTAssertTrue(PackingFlow.orderSourceFailed([failed]))
        XCTAssertFalse(PackingFlow.orderSourceFailed([catalog]))
    }

    func testWrongProductCopyNamesWhatTheOrderStillNeeds() {
        XCTAssertEqual(
            PackingFlow.wrongProductMessage(stillNeeds: "Cardamomo Sapone Mani 250ml (MS001)"),
            "Prodotto sbagliato. Non contato. A questo ordine manca ancora Cardamomo Sapone Mani 250ml (MS001)."
        )
    }

    func testLookalikeCodesStayDistinct() {
        XCTAssertNotEqual("MS001", "MS002")
        XCTAssertEqual(PackingFlow.rightProduct, "Prodotto giusto. Non ancora contato.")
        XCTAssertEqual(PackingFlow.countAction, "Aggiungi")
        XCTAssertEqual(PackingFlow.markDoneConfirm, "Confermi che la scatola corrisponde all'ordine. Non lo spedisce.")
    }

    func testSizeIsSplitOffSoLookalikesStandOut() {
        XCTAssertEqual(PackingFlow.splitSize("Cardamomo Sapone Mani 250ml").name, "Cardamomo Sapone Mani")
        XCTAssertEqual(PackingFlow.splitSize("Cardamomo Sapone Mani 250ml").size, "250 ml")
        XCTAssertEqual(PackingFlow.splitSize("Cardamomo Sapone Mani 500 ML").size, "500 ml")
        XCTAssertEqual(PackingFlow.splitSize("Candela 200g").size, "200 g")
        XCTAssertNil(PackingFlow.splitSize("Travel Kit").size)
        XCTAssertEqual(PackingFlow.splitSize("Travel Kit").name, "Travel Kit")
        XCTAssertNil(PackingFlow.splitSize("250ml").size, "A bare size has no name to split from")
    }

    private func order(id: String, reference: String, eligible: Bool, packStatus: String?, isOwner: Bool = false) -> WorkloadOrder {
        WorkloadOrder(
            source: "fixture",
            orderId: id,
            reference: reference,
            recipient: nil,
            eligible: eligible,
            ineligibleReason: eligible ? nil : "Not eligible",
            units: 1,
            packId: packStatus == nil ? nil : "pack-\(id)",
            packStatus: packStatus,
            ownerName: isOwner ? "Ana" : nil,
            isOwner: isOwner,
            verified: 0,
            changedAfterCompletion: false,
            blockedLines: 0,
            freshness: Freshness(state: "current", pulledAt: 0, message: nil)
        )
    }
}
