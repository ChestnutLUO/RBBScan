import Foundation

/// Metadata of one confirmed sighting, sent as the `meta` form field of `POST /api/scans`.
public struct ScanUpload: Codable, Sendable, Equatable {
    public let scanID: UUID
    public let code: String
    public let confidence: Float
    public let readCount: Int
    public let uncertainPositions: [Int]
    public let device: String
    public let capturedAt: Date

    public init(scanID: UUID = UUID(), code: String, confidence: Float, readCount: Int,
                uncertainPositions: [Int], device: String, capturedAt: Date = Date()) {
        self.scanID = scanID
        self.code = code
        self.confidence = confidence
        self.readCount = readCount
        self.uncertainPositions = uncertainPositions
        self.device = device
        self.capturedAt = capturedAt
    }

    public init(_ confirmed: ConfirmedCode, device: String, capturedAt: Date = Date()) {
        self.init(code: confirmed.code, confidence: confirmed.confidence, readCount: confirmed.readCount,
                  uncertainPositions: confirmed.uncertainPositions, device: device, capturedAt: capturedAt)
    }

    enum CodingKeys: String, CodingKey {
        case scanID = "scan_id", code, confidence, readCount = "read_count"
        case uncertainPositions = "uncertain_positions", device, capturedAt = "captured_at"
    }
}

public struct ScanResponse: Decodable, Sendable, Equatable {
    public let isNew: Bool
    public let alreadyRecorded: Bool
    public let seenCount: Int
    public let uniqueTotal: Int
    public let targetTotal: Int

    public init(isNew: Bool, alreadyRecorded: Bool, seenCount: Int, uniqueTotal: Int, targetTotal: Int) {
        self.isNew = isNew
        self.alreadyRecorded = alreadyRecorded
        self.seenCount = seenCount
        self.uniqueTotal = uniqueTotal
        self.targetTotal = targetTotal
    }

    enum CodingKeys: String, CodingKey {
        case isNew = "is_new", alreadyRecorded = "already_recorded", seenCount = "seen_count"
        case uniqueTotal = "unique_total", targetTotal = "target_total"
    }
}

public struct ServerStats: Decodable, Sendable, Equatable {
    public let uniqueTotal: Int
    public let verified: Int
    public let needsReview: Int
    public let totalSightings: Int
    public let targetTotal: Int

    enum CodingKeys: String, CodingKey {
        case uniqueTotal = "unique_total", verified, needsReview = "needs_review"
        case totalSightings = "total_sightings", targetTotal = "target_total"
    }
}

/// Status the scanner reports about once a second for the second-device dashboard.
public struct HeartbeatStatus: Encodable, Sendable, Equatable {
    public struct Tracked: Encodable, Sendable, Equatable {
        public let bestRead: String
        public let readCount: Int
        public let confirmed: Bool

        enum CodingKeys: String, CodingKey {
            case bestRead = "best_read", readCount = "read_count", confirmed
        }
    }

    public let device: String
    public let cameraRunning: Bool
    public let paused: Bool
    public let torch: Bool
    public let tracking: [Tracked]
    public let pendingUploads: Int
    /// 0...1, or -1 when unknown.
    public let battery: Float
    public let localUnique: Int

    public init(device: String, cameraRunning: Bool, paused: Bool, torch: Bool, tracking: [TrackSnapshot],
                pendingUploads: Int, battery: Float, localUnique: Int) {
        self.device = device
        self.cameraRunning = cameraRunning
        self.paused = paused
        self.torch = torch
        self.tracking = tracking.prefix(20).map {
            Tracked(bestRead: String($0.bestRead.prefix(32)), readCount: $0.readCount, confirmed: $0.confirmed)
        }
        self.pendingUploads = pendingUploads
        self.battery = battery.isFinite ? min(max(battery, -1), 1) : -1
        self.localUnique = localUnique
    }

    enum CodingKeys: String, CodingKey {
        case device, cameraRunning = "camera_running", paused, torch, tracking
        case pendingUploads = "pending_uploads", battery, localUnique = "local_unique"
    }
}

public enum ScanClientError: Error, LocalizedError, Equatable {
    case invalidResponse
    /// The server rejected the request; retrying the same payload will not help.
    case rejected(status: Int, body: String)
    /// A transient server failure worth retrying.
    case server(status: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server sent an unreadable response."
        case .rejected(let status, let body): return "The server rejected the request (\(status)): \(body)"
        case .server(let status): return "Server error \(status)."
        }
    }
}

/// HTTP client for the Mac mini server. Network failures surface as `URLError`.
public struct ScanClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func upload(_ scan: ScanUpload, images: ScanImages?) async throws -> ScanResponse {
        var form = MultipartForm()
        form.addField(name: "meta", value: try Self.encoder.encode(scan))
        if let images {
            form.addFile(name: "label", filename: "label.jpg", contentType: "image/jpeg", data: images.label)
            form.addFile(name: "card", filename: "card.jpg", contentType: "image/jpeg", data: images.card)
            form.addFile(name: "frame", filename: "frame.jpg", contentType: "image/jpeg", data: images.frame)
        }
        return try await send(form, to: "api/scans", timeout: 20)
    }

    @discardableResult
    public func heartbeat(_ status: HeartbeatStatus, preview: Data?) async throws -> ServerStats {
        var form = MultipartForm()
        form.addField(name: "status", value: try Self.encoder.encode(status))
        if let preview {
            form.addFile(name: "preview", filename: "preview.jpg", contentType: "image/jpeg", data: preview)
        }
        return try await send(form, to: "api/heartbeat", timeout: 3)
    }

    public func stats() async throws -> ServerStats {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/stats"))
        request.timeoutInterval = 5
        return try await perform(request)
    }

    /// Canonical key → seen count of every passcode the server already has.
    public func knownKeys() async throws -> [String: Int] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/keys"))
        request.timeoutInterval = 10
        return try await perform(request)
    }

    private func send<Response: Decodable>(_ form: MultipartForm, to path: String, timeout: TimeInterval) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ScanClientError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw ScanClientError.invalidResponse
            }
        case 400..<500 where http.statusCode != 408 && http.statusCode != 429:
            throw ScanClientError.rejected(status: http.statusCode, body: String(decoding: data.prefix(500), as: UTF8.self))
        default:
            throw ScanClientError.server(status: http.statusCode)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
}

/// Minimal multipart/form-data body builder.
struct MultipartForm {
    let boundary = "RBBScan-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(value)
        body.append(Data("\r\n".utf8))
    }

    mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}
