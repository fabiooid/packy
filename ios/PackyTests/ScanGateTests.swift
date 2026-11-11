import XCTest
@testable import Packy

final class ScanGateTests: XCTestCase {
    private let code = "0806812399109"
    private let start = Date(timeIntervalSince1970: 1000)

    func testCodeHeldInViewReportsOnce() {
        var gate = ScanGate()
        XCTAssertTrue(gate.appeared(code, at: start))
        XCTAssertFalse(gate.appeared(code, at: start.addingTimeInterval(5)))
    }

    func testFlickerDoesNotReportAgain() {
        var gate = ScanGate(rearmInterval: 1.2)
        XCTAssertTrue(gate.appeared(code, at: start))
        gate.left(code, at: start.addingTimeInterval(1))
        XCTAssertFalse(gate.appeared(code, at: start.addingTimeInterval(1.5)))
    }

    func testCodeRearmsAfterLeavingView() {
        var gate = ScanGate(rearmInterval: 1.2)
        XCTAssertTrue(gate.appeared(code, at: start))
        gate.left(code, at: start.addingTimeInterval(1))
        XCTAssertTrue(gate.appeared(code, at: start.addingTimeInterval(2.5)))
    }

    func testDifferentCodeIsIndependent() {
        var gate = ScanGate()
        XCTAssertTrue(gate.appeared(code, at: start))
        XCTAssertTrue(gate.appeared("8050038450997", at: start))
    }
}
