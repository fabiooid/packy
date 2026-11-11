import Foundation
import Observation

@Observable @MainActor
final class AppModel {
    enum LoadState { case idle, loading, failed(String) }

    let api = APIClient()
    var signedIn = false
    var workload: Workload?
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
            loginError = "The server could not be reached. You are not signed in."
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
            loadState = .idle
        } catch APIFailure.signedOut {
            signOutLocally()
        } catch {
            loadState = .failed("Packy could not reach the server. This is not an empty list. Orders are unknown until it connects.")
        }
    }

    /// After a full app close, drop any unfinished order still on the server. Returns the order reference if it was cleared.
    func clearUnfinishedOrderAfterColdStart() async -> String? {
        guard let workload else { return nil }
        guard let order = workload.orders.first(where: { $0.packStatus == "active" && $0.isOwner }),
              let packId = order.packId else { return nil }
        do {
            let pack: Pack = try await api.send("GET", "v1/packs/\(packId)")
            guard pack.status == "active" else { return nil }
            let _: EmptyResponse = try await api.send(
                "POST",
                "v1/packs/\(packId)/release",
                body: ["actionId": UUID().uuidString, "version": pack.version]
            )
            await refresh()
            return order.reference
        } catch APIFailure.signedOut {
            signOutLocally()
            return nil
        } catch {
            return nil
        }
    }
}

struct EmptyResponse: Decodable {}
