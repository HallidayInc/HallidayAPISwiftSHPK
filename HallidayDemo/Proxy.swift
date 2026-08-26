import Foundation

// The chain data the non-EVM signers need lives behind provider keys, so it comes from
// server/ rather than from the app.
enum Proxy {
    static func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        guard var components = URLComponents(string: Config.serverURL + path) else {
            throw SendError.rpc(path, "SERVER_URL is not set")
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw SendError.rpc(path, "bad URL") }
        return try await result(URLRequest(url: url), path)
    }

    static func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: Config.serverURL + path) else {
            throw SendError.rpc(path, "SERVER_URL is not set")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await result(request, path)
    }

    static func solana(_ method: String, _ params: [Any]) async throws -> Any {
        let body = try await post("/solana/rpc", ["method": method, "params": params])
        if let error = body["error"] as? [String: Any] {
            throw SendError.rpc(method, String(describing: error["message"] ?? error))
        }
        return body["result"] ?? NSNull()
    }

    private static func result(_ request: URLRequest, _ path: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SendError.rpc(path, String(data: data, encoding: .utf8) ?? "no response")
        }
        if let message = body["error"] as? String { throw SendError.rpc(path, message) }
        return body
    }
}
