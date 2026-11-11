import Foundation

enum APIFailure: Error {
    /// The server answered and refused. Nothing was recorded.
    case rejected(code: String, message: String, pack: Pack?)
    case signedOut
    /// No answer. The action may or may not have reached the server.
    case unreachable
}

final class APIClient {
    static let baseURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "PackyAPIURL") as? String ?? ""
        return URL(string: raw) ?? URL(string: "http://localhost:8787")!
    }()

    var token: String?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let code: String; let message: String }
        let error: Detail
        let pack: Pack?
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIFailure.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return try JSONDecoder().decode(T.self, from: data) }
        let detail = try? JSONDecoder().decode(ErrorBody.self, from: data)
        if status == 401, detail?.error.code == "unauthenticated" { throw APIFailure.signedOut }
        throw APIFailure.rejected(code: detail?.error.code ?? "server_error",
                                  message: detail?.error.message ?? "The server refused this. Nothing was recorded.",
                                  pack: detail?.pack)
    }
}
