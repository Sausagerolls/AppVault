import Foundation

// MARK: - Models (mirror the Go server JSON)

public struct PartInfo: Codable, Hashable {
    public var size: Int64
    public var sha256: String
    public init(size: Int64, sha256: String) { self.size = size; self.sha256 = sha256 }
}

public struct ItemMeta: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var kind: String
    public var bundleId: String?
    public var version: String?
    public var build: String?
    public var appCategory: String?
    public var category: String
    public var originalPath: String
    public var fingerprint: String
    public var installedSize: Int64
    public var dataPaths: [String]?
    public var parts: [String: PartInfo]?
    public var hasIcon: Bool
    public var notes: String?
    public var uploadedAt: Date?

    public init(name: String, kind: String, bundleId: String?, version: String?, build: String?,
                appCategory: String?, category: String, originalPath: String, fingerprint: String,
                installedSize: Int64, dataPaths: [String]?) {
        self.id = ""
        self.name = name; self.kind = kind; self.bundleId = bundleId; self.version = version
        self.build = build; self.appCategory = appCategory; self.category = category
        self.originalPath = originalPath; self.fingerprint = fingerprint
        self.installedSize = installedSize; self.dataPaths = dataPaths
        self.parts = nil; self.hasIcon = false; self.notes = nil; self.uploadedAt = nil
    }

    public var storedBytes: Int64 { (parts ?? [:]).values.reduce(0) { $0 + $1.size } }
    public var hasData: Bool { parts?["data"] != nil }
}

public struct CategoryInfo: Codable, Identifiable, Hashable {
    public var name: String
    public var itemCount: Int
    public var bytes: Int64
    public var id: String { name }
}

public struct ServerStats: Codable {
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var libraryBytes: Int64
    public var itemCount: Int
    public var version: String
}

public struct UploadView: Codable {
    public var id: String
    public var meta: ItemMeta
    public var replaces: String?
    public var offsets: [String: Int64]
}

// MARK: - Errors

public enum APIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case offsetMismatch(Int64)
    case partial(Int64, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Server address and token are not set. Open Settings."
        case .http(let code, let msg):
            switch code {
            case 401: return "Server rejected the token (401). Check Settings."
            case 507: return "Not enough free space on the server."
            default: return "Server error \(code): \(msg)"
            }
        case .offsetMismatch(let o): return "Server expected offset \(o)."
        case .partial(let o, let m): return "Transfer interrupted at \(o): \(m)"
        case .invalidResponse: return "Invalid response from server."
        }
    }
}

// MARK: - Client

public final class APIClient {
    public let baseURL: URL
    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 60 * 60 * 24
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
        }
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func check(_ data: Data, _ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError.http(http.statusCode, msg ?? String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    private func send<T: Decodable>(_ r: URLRequest, body: Data? = nil, as: T.Type) async throws -> T {
        var r = r
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: r)
        try check(data, resp)
        return try decoder.decode(T.self, from: data)
    }

    private func sendNoContent(_ r: URLRequest, body: Data? = nil) async throws {
        var r = r
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: r)
        try check(data, resp)
    }

    private func json(_ v: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: v) }

    // General
    public func health() async throws -> Bool {
        var r = URLRequest(url: baseURL.appendingPathComponent("api/health"))
        r.timeoutInterval = 5
        let (data, resp) = try await session.data(for: r)
        try check(data, resp)
        return true
    }

    public func stats() async throws -> ServerStats {
        try await send(request("api/stats"), as: ServerStats.self)
    }

    // Categories
    public func categories() async throws -> [CategoryInfo] {
        try await send(request("api/categories"), as: [CategoryInfo].self)
    }

    public func createCategory(_ name: String) async throws {
        try await sendNoContent(request("api/categories", method: "POST"), body: json(["name": name]))
    }

    public func renameCategory(_ old: String, to new: String) async throws {
        try await sendNoContent(request("api/categories/\(old)", method: "PATCH"), body: json(["name": new]))
    }

    public func deleteCategory(_ name: String) async throws {
        try await sendNoContent(request("api/categories/\(name)", method: "DELETE"))
    }

    // Items
    public func items() async throws -> [ItemMeta] {
        try await send(request("api/items"), as: [ItemMeta].self)
    }

    public func item(_ id: String) async throws -> ItemMeta {
        try await send(request("api/items/\(id)"), as: ItemMeta.self)
    }

    public func setCategory(_ id: String, _ category: String) async throws -> ItemMeta {
        try await send(request("api/items/\(id)", method: "PATCH"), body: json(["category": category]), as: ItemMeta.self)
    }

    public func deleteItem(_ id: String) async throws {
        try await sendNoContent(request("api/items/\(id)", method: "DELETE"))
    }

    public func icon(_ id: String) async throws -> Data {
        let (data, resp) = try await session.data(for: request("api/items/\(id)/icon"))
        try check(data, resp)
        return data
    }

    /// Downloads bytes [from, from+length) of a stored part to a temporary file.
    public func downloadRange(_ id: String, part: String, from: Int64, length: Int64, etag: String) async throws -> URL {
        var r = request("api/items/\(id)/parts/\(part)")
        r.setValue("bytes=\(from)-\(from + length - 1)", forHTTPHeaderField: "Range")
        r.setValue("\"\(etag)\"", forHTTPHeaderField: "If-Range")
        let (url, resp) = try await session.download(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard http.statusCode == 206 || (http.statusCode == 200 && from == 0) else {
            try? FileManager.default.removeItem(at: url)
            if http.statusCode == 200 { throw APIError.http(200, "Archive changed on server during download") }
            throw APIError.http(http.statusCode, "download failed")
        }
        return url
    }

    // Uploads
    public func uploads() async throws -> [UploadView] {
        try await send(request("api/uploads"), as: [UploadView].self)
    }

    public func upload(_ id: String) async throws -> UploadView {
        try await send(request("api/uploads/\(id)"), as: UploadView.self)
    }

    public func createUpload(meta: ItemMeta, replaces: String?, expectedBytes: Int64) async throws -> UploadView {
        struct Body: Encodable { let meta: ItemMeta; let replaces: String?; let expectedBytes: Int64 }
        let body = try encoder.encode(Body(meta: meta, replaces: replaces, expectedBytes: expectedBytes))
        return try await send(request("api/uploads", method: "POST"), body: body, as: UploadView.self)
    }

    public func abortUpload(_ id: String) async throws {
        try await sendNoContent(request("api/uploads/\(id)", method: "DELETE"))
    }

    public func putIcon(_ id: String, png: Data) async throws {
        var r = request("api/uploads/\(id)/icon", method: "PUT")
        r.setValue("image/png", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: r, from: png)
        try check(data, resp)
    }

    /// Sends one chunk. Returns the server's new offset.
    public func appendChunk(_ id: String, part: String, offset: Int64, data chunk: Data) async throws -> Int64 {
        var r = request("api/uploads/\(id)/parts/\(part)", method: "PATCH",
                        query: [URLQueryItem(name: "offset", value: String(offset))])
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: r, from: chunk)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let serverOffset = (obj["offset"] as? NSNumber)?.int64Value
        switch http.statusCode {
        case 200:
            guard let o = serverOffset else { throw APIError.invalidResponse }
            return o
        case 409:
            throw APIError.offsetMismatch(serverOffset ?? 0)
        case 422:
            throw APIError.partial(serverOffset ?? offset, obj["error"] as? String ?? "")
        default:
            throw APIError.http(http.statusCode, obj["error"] as? String ?? "")
        }
    }

    public func completeUpload(_ id: String, parts: [String: PartInfo]) async throws -> ItemMeta {
        struct Body: Encodable { let parts: [String: PartInfo] }
        let body = try encoder.encode(Body(parts: parts))
        return try await send(request("api/uploads/\(id)/complete", method: "POST"), body: body, as: ItemMeta.self)
    }
}
