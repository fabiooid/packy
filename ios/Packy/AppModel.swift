import Foundation
import Observation

@Observable @MainActor
final class AppModel {
    enum LoadState { case idle, loading, failed(String) }

    let api = APIClient()
    var signedIn = false
    var workload: Workload?
    /// Orders packed in the last 30 days, newest first. Empty until the first refresh.
    var packed: [PackedOrder] = []
    var loadState: LoadState = .idle
    var loginError: String?

    init() {
        if let token = Keychain.load() {
            api.token = token
            signedIn = true
        }
    }

    func login(username: String, password: String) async {
        loginError = nil
        do {
            let response: LoginResponse = try await api.send("POST", "v1/auth/login", body: ["username": username, "password": password])
            Keychain.save(response.token)
            api.token = response.token
            signedIn = true
            await refresh()
        } catch APIFailure.rejected(_, let message, _) {
            loginError = message
        } catch {
            loginError = "Server non raggiungibile. Riprova."
        }
    }

    func logout() async {
        let _: EmptyResponse? = try? await api.send("POST", "v1/auth/logout", body: [:])
        signOutLocally()
    }

    func signOutLocally() {
        Keychain.clear()
        api.token = nil
        signedIn = false
        workload = nil
    }

    /// Pulls fresh data. Called on sign in, app open, and manual refresh only.
    func refresh() async {
        loadState = .loading
        do {
            workload = try await api.send("POST", "v1/refresh", body: [:])
            // The packed list is secondary: if it fails, the orders to pack still show.
            if let list: PackedList = try? await api.send("GET", "v1/packed") { packed = list.orders }
            loadState = .idle
        } catch APIFailure.signedOut {
            signOutLocally()
        } catch {
            loadState = .failed("Controlla la connessione e riprova.")
        }
    }

    /// "Cancella" on the in-progress card: the box is emptied, counts go and the order is free again.
    func cancel(_ order: WorkloadOrder) async -> String? {
        guard let packId = order.packId else { return nil }
        do {
            let pack: Pack = try await api.send("GET", "v1/packs/\(packId)")
            let _: EmptyResponse = try await api.send("POST", "v1/packs/\(packId)/release", body: ["actionId": UUID().uuidString, "version": pack.version])
            await refresh()
            return nil
        } catch APIFailure.signedOut {
            signOutLocally()
            return nil
        } catch APIFailure.rejected(_, let message, _) {
            return message
        } catch {
            return "Server non raggiungibile. Riprova."
        }
    }

    /// The packing session that must resume after the app is closed mid-order.
    func activeOwnedOrder() -> WorkloadOrder? {
        PackingFlow.activeOwnedOrder(workload?.orders ?? [])
    }
}

struct EmptyResponse: Decodable {}
