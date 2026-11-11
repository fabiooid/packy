import Foundation

/// Decides which camera sightings become reads. A code is reported once when it appears, and not again
/// until it has left view for `rearmInterval`. This reduces accidental repeats but cannot tell two
/// identical bottles apart. Only the operator's tap asserts a physical unit.
struct ScanGate {
    let rearmInterval: TimeInterval
    private var visible: Set<String> = []
    private var lastLeft: [String: Date] = [:]

    init(rearmInterval: TimeInterval = 1.2) {
        self.rearmInterval = rearmInterval
    }

    mutating func appeared(_ code: String, at now: Date = Date()) -> Bool {
        guard visible.insert(code).inserted else { return false }
        if let left = lastLeft[code], now.timeIntervalSince(left) < rearmInterval { return false }
        return true
    }

    mutating func left(_ code: String, at now: Date = Date()) {
        visible.remove(code)
        lastLeft[code] = now
    }
}
