import Foundation

public struct TrevoHTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String, headers: [String: String], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct TrevoHTTPResponse: Sendable {
    public var statusCode: Int
    /// Header names in lowercase.
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

/// Sends the SDK's two requests: the config fetch and event delivery. Replace it to route through
/// your own networking stack.
public protocol TrevoTransport: Sendable {
    func send(_ request: TrevoHTTPRequest) async throws -> TrevoHTTPResponse
}

public struct URLSessionTransport: TrevoTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        // The resource timeout covers the body too: headers can arrive and the body then stall.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // The SDK sends its own If-None-Match; a URL cache would answer a 304 with a stale 200.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: TrevoHTTPRequest) async throws -> TrevoHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw TrevoError("\(request.url.host ?? "server") sent a non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return TrevoHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
