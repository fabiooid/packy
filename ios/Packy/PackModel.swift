import Foundation
import Observation
import AudioToolbox
import UIKit

@Observable @MainActor
final class PackModel {
    enum Card {
        case idle
        case checking(String)
        case offer(Scan)
        case recorded(String)
        case rejected(Scan)
        case notRecorded(String)
        /// No answer from the server. Retrying reuses the action id, so it cannot count twice.
        case unknownResult(scan: Scan, actionId: String)
        case failure(String)
    }

    private let api: APIClient
    private let onSignedOut: () -> Void
    var pack: Pack
    var card: Card = .idle
    var busy = false
    /// The product the packer chose to scan. The camera only runs while one is chosen.
    var selectedLineId: String?
    /// True after the order was cleared, so leaving the screen does not clear it twice.
    var didRelease = false
    private var queuedRead: (String, String?)?

    init(pack: Pack, api: APIClient, onSignedOut: @escaping () -> Void) {
        self.pack = pack
        self.api = api
        self.onSignedOut = onSignedOut
    }

    func handleRead(_ barcode: String, symbology: String?) {
        guard pack.canScan, let id = selectedLineId, let line = pack.lines.first(where: { $0.lineId == id }), PackingFlow.needsScan(line) else { return }
        if busy {
            queuedRead = (barcode, symbology)
            return
        }
        Task { await submit(barcode, symbology) }
    }

    private func submit(_ barcode: String, _ symbology: String?) async {
        busy = true
        card = .checking(barcode)
        do {
            let response: ScanResponse = try await api.send("POST", "v1/packs/\(pack.id)/scans", body: ["barcode": barcode, "symbology": symbology ?? "", "lineId": selectedLineId ?? ""])
            pack = response.pack
            if response.scan.outcome == "eligible" {
                card = .offer(response.scan)
                Feedback.accepted()
            } else {
                card = .rejected(response.scan)
                Feedback.rejected()
            }
        } catch {
            handle(error, fallback: "Questa scansione non ha raggiunto il server. Non è stato controllato né registrato nulla. Scansiona di nuovo.")
        }
        busy = false
        if let next = queuedRead {
            queuedRead = nil
            await submit(next.0, next.1)
        }
    }

    func confirm(_ scan: Scan, actionId: String = UUID().uuidString) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            pack = try await post("confirm", extra: ["scanId": scan.id], actionId: actionId)
            let counted = scan.unitNumber ?? 1
            let required = scan.required ?? counted
            card = .recorded("Contato. \(PackingFlow.countLabel(verified: counted, required: required))")
            if let selected = selectedLineId, pack.lines.first(where: { $0.lineId == selected })?.state == "done" {
                selectedLineId = nil
            }
            Feedback.recorded()
        } catch APIFailure.unreachable {
            card = .unknownResult(scan: scan, actionId: actionId)
            Feedback.rejected()
        } catch {
            handle(error, fallback: "Non è stato registrato nulla.")
        }
    }

    func confirmManual(_ line: Line, actionId: String = UUID().uuidString) async {
        guard !busy, PackingFlow.canManualConfirm(line) else { return }
        busy = true
        defer { busy = false }
        do {
            pack = try await post("confirm", extra: ["lineId": line.lineId], actionId: actionId)
            let updated = pack.lines.first(where: { $0.lineId == line.lineId })
            let counted = updated?.verified ?? line.verified
            let required = updated?.required ?? line.required
            card = .recorded("Contato. \(PackingFlow.countLabel(verified: counted, required: required))")
            if let selected = selectedLineId, pack.lines.first(where: { $0.lineId == selected })?.state == "done" {
                selectedLineId = nil
            }
            Feedback.recorded()
        } catch {
            handle(error, fallback: "Non è stato registrato nulla.")
        }
    }

    func perform(_ path: String, extra: [String: Any] = [:]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            pack = try await post(path, extra: extra)
            card = .idle
        } catch {
            handle(error, fallback: "La richiesta non ha raggiunto il server. Non è cambiato nulla. Riprova.")
        }
    }

    func emptyBox() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let _: EmptyResponse = try await post("release")
            didRelease = true
            return true
        } catch {
            handle(error, fallback: "La richiesta non ha raggiunto il server. Non è cambiato nulla. Riprova.")
            return false
        }
    }

    /// The completing tap pulls first, so the order is checked against the source at that moment.
    func completeAfterRefresh() async {
        guard await refresh() else { return }
        guard pack.canComplete else {
            card = .notRecorded("Non registrato. L'ultimo controllo ha trovato qualcosa da risolvere.")
            return
        }
        await perform("complete")
    }

    @discardableResult
    func refresh() async -> Bool {
        do {
            let _: Workload = try await api.send("POST", "v1/refresh", body: [:])
            pack = try await api.send("GET", "v1/packs/\(pack.id)")
            return true
        } catch {
            handle(error, fallback: "Aggiornamento non riuscito. I dati mostrati sono l'ultima copia salvata.")
            return false
        }
    }

    private func post<T: Decodable>(_ path: String, extra: [String: Any] = [:], actionId: String = UUID().uuidString) async throws -> T {
        var body = extra
        body["actionId"] = actionId
        body["version"] = pack.version
        return try await api.send("POST", "v1/packs/\(pack.id)/\(path)", body: body)
    }

    private func handle(_ error: Error, fallback: String) {
        switch error {
        case APIFailure.signedOut:
            onSignedOut()
        case APIFailure.rejected(_, let message, let latest):
            if let latest { pack = latest }
            card = .notRecorded(message)
            Feedback.rejected()
        default:
            card = .failure(fallback)
            Feedback.rejected()
        }
    }
}

/// Haptics plus sound, so a packer hears a wrong scan without looking at the phone.
/// System sounds follow the ring/silent switch.
enum Feedback {
    static func accepted() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }

    static func recorded() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(1057)
    }

    static func rejected() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        AudioServicesPlayAlertSound(1053)
    }
}
