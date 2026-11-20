import Foundation

public struct TrevoHTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// Refuse a response body longer than this, before reading it all where possible. The SDK sets
    /// it on remote paywall page downloads; a custom transport should honor it too.
    public var maxResponseBytes: Int?

    public init(
        url: URL, method: String, headers: [String: String], body: Data? = nil, maxResponseBytes: Int? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.maxResponseBytes = maxResponseBytes
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

/// Sends the SDK's requests: the config fetch, event delivery, and remote paywall page downloads,
/// which are public GETs with no API key to the host config names. Replace it to route through
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
        let data: Data
        let response: URLResponse
        if let limit = request.maxResponseBytes {
            (data, response) = try await boundedData(for: urlRequest, limit: limit)
        } else {
            (data, response) = try await session.data(for: urlRequest)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TrevoError("\(request.url.host ?? "server") sent a non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return TrevoHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    private func boundedData(for request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        do {
            let data = try await Self.collect(
                bytes, declaredLength: response.expectedContentLength, limit: limit)
            return (data, response)
        } catch {
            bytes.task.cancel()
            throw error
        }
    }

    // Counts the bytes after decompression, so a small compressed body can't expand past the limit.
    static func collect<Bytes: AsyncSequence>(
        _ bytes: Bytes, declaredLength: Int64, limit: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        if declaredLength > Int64(limit) { throw ResponseTooLong(limit: limit) }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(declaredLength))))
        for try await byte in bytes {
            if data.count == limit { throw ResponseTooLong(limit: limit) }
            data.append(byte)
        }
        return data
    }
}

/// The response passed `maxResponseBytes`.
struct ResponseTooLong: Error, CustomStringConvertible {
    let limit: Int

    var description: String { "The response is longer than \(limit) bytes" }
}
