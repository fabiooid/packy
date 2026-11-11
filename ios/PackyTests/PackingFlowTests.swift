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

    func testBarcodelessLinesUseManualConfirmInsteadOfScan() {
        let promo = line(method: "manual", canManualConfirm: true)
        let soap = line(method: "barcode", canManualConfirm: false)
        XCTAssertFalse(PackingFlow.needsScan(promo))
        XCTAssertTrue(PackingFlow.canManualConfirm(promo))
        XCTAssertTrue(PackingFlow.needsScan(soap))
        XCTAssertFalse(PackingFlow.canManualConfirm(soap))
        XCTAssertEqual(PackingFlow.countAction, "Aggiungi")
    }

    func testHeaderAddOnBarcodedLineNeedsAMatchingScan() {
        let soap = line(id: "f1-a", method: "barcode", canManualConfirm: false)
        XCTAssertFalse(PackingFlow.canConfirmFromHeader(line: soap, pendingScan: nil))
        XCTAssertTrue(PackingFlow.canConfirmFromHeader(line: soap, pendingScan: scan(outcome: "eligible", lineId: "f1-a")))
        XCTAssertFalse(PackingFlow.canConfirmFromHeader(line: soap, pendingScan: scan(outcome: "eligible", lineId: "f1-b")))
        XCTAssertFalse(PackingFlow.canConfirmFromHeader(line: soap, pendingScan: scan(outcome: "wrong_product", lineId: "f1-a")))
    }

    func testHeaderAddOnBarcodelessLineDoesNotNeedAScan() {
        let promo = line(id: "f3-promo", method: "manual", canManualConfirm: true)
        XCTAssertTrue(PackingFlow.canConfirmFromHeader(line: promo, pendingScan: nil))
        XCTAssertEqual(PackingFlow.countAction, "Aggiungi")
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

    private func scan(outcome: String, lineId: String) -> Scan {
        Scan(
            id: "scan-\(lineId)",
            outcome: outcome,
            barcode: "8050038450997",
            codice: "MS001",
            productName: "Sapone",
            message: "",
            unitNumber: 1,
            required: 1,
            recheck: false,
            discrepancyId: nil,
            lineId: lineId
        )
    }

    func testSearchMatchesCustomerOrOrderNumber() {
        XCTAssertTrue(PackingFlow.matches("", recipient: nil, reference: "#MS1668"))
        XCTAssertTrue(PackingFlow.matches("marta", recipient: "Marta Bianchi", reference: "#MS1668"))
        XCTAssertTrue(PackingFlow.matches("#1668", recipient: "Marta Bianchi", reference: "#MS1668"))
        XCTAssertTrue(PackingFlow.matches("niccolo", recipient: "Niccolò Rè", reference: "#MS1"), "ignores accents")
        XCTAssertFalse(PackingFlow.matches("luca", recipient: "Marta Bianchi", reference: "#MS1668"))
    }

    func testPackedOrdersGroupByDayNewestFirst() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        func order(_ hoursAgo: Double, _ ref: String) -> PackedOrder {
            PackedOrder(completedAt: (now.timeIntervalSince1970 - hoursAgo * 3600) * 1000, source: "s", reference: ref, recipient: nil, completedByName: "Ana", units: 1)
        }
        let groups = PackingFlow.packedGroups([order(30, "c"), order(1, "a"), order(2, "b"), order(60, "d")], now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.label).prefix(2), ["Oggi", "Ieri"])
        XCTAssertEqual(groups[0].orders.map(\.reference), ["a", "b"])
        XCTAssertEqual(groups[1].orders.map(\.reference), ["c"])
        XCTAssertEqual(groups.count, 3)
    }

    func testShippingIsConfirmedButNeverAPiece() {
        let soap = line(id: "a", method: "barcode", canManualConfirm: false, required: 3, verified: 2)
        let ship = line(id: "s", method: "manual", canManualConfirm: true, verified: 1, shipping: true)
        let pieces = PackingFlow.pieces([soap, ship])
        XCTAssertEqual(pieces.total, 3)
        XCTAssertEqual(pieces.counted, 2)
    }

    func testWrongReadNamesOnlyWhatWasRead() {
        let scan = Scan(id: "s", outcome: "wrong_product", barcode: "8050038450980", codice: "MS002", productName: "Sapone 500ml",
                        message: "", unitNumber: nil, required: nil, recheck: false, discrepancyId: nil, lineId: nil)
        XCTAssertEqual(PackingFlow.wrongReadDetail(scan: scan), "Hai letto Sapone 500ml (MS002).")
        let unnamed = Scan(id: "s", outcome: "wrong_product", barcode: "123", codice: nil, productName: nil,
                           message: "", unitNumber: nil, required: nil, recheck: false, discrepancyId: nil, lineId: nil)
        XCTAssertEqual(PackingFlow.wrongReadDetail(scan: unnamed), "Hai letto 123.")
    }

    private func line(id: String = "x", method: String, canManualConfirm: Bool, required: Int = 1, verified: Int = 0, shipping: Bool = false) -> Line {
        Line(
            lineId: id,
            kind: "physical",
            kindReason: nil,
            required: required,
            verified: verified,
            uncertain: 0,
            remaining: max(0, required - verified),
            state: "todo",
            identity: Identity(
                status: method == "barcode" ? "resolved" : "unresolved",
                codice: method == "barcode" ? "MS001" : nil,
                ficName: method == "barcode" ? "Sapone" : nil,
                reason: nil,
                sourceTitle: "Materiale promozionale"
            ),
            verification: Verification(method: method, reason: nil),
            units: [],
            canManualConfirm: canManualConfirm,
            isShipping: shipping
        )
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
