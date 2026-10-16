import Foundation
import PasscodeCore

protocol ScanUploading: Sendable {
    func upload(_ scan: ScanUpload, images: ScanImages?) async throws -> ScanResponse
}

extension ScanClient: ScanUploading {}

/// Confirmed scans persisted on disk until the server has them, so nothing is lost when
/// Tailscale drops or the app is killed. Each scan is a directory named
/// `<milliseconds>_<scan id>` holding `meta.json` and its JPEGs; `meta.json` is written last,
/// so a directory without it is an interrupted write and is ignored.
///
/// `deliverNext` must be driven by a single loop; concurrent calls could send a scan twice
/// (the server would still de-duplicate it by scan id).
actor UploadQueue {
    enum Outcome: Sendable {
        case delivered(ScanUpload, ScanResponse)
        /// The server refused the scan (e.g. validation); it is kept in `rejected/` for inspection.
        case rejected(ScanUpload?, String)
    }

    private static let imageKinds = ["label", "card", "frame"]
    private let pendingDirectory: URL
    private let rejectedDirectory: URL
    private let fileManager = FileManager.default

    init(directory: URL) throws {
        pendingDirectory = directory.appendingPathComponent("pending", isDirectory: true)
        rejectedDirectory = directory.appendingPathComponent("rejected", isDirectory: true)
        try fileManager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rejectedDirectory, withIntermediateDirectories: true)
    }

    var pendingCount: Int {
        pendingItems().count
    }

    func enqueue(_ scan: ScanUpload, images: ScanImages?) throws {
        let millis = Int64(scan.capturedAt.timeIntervalSince1970 * 1000)
        let item = pendingDirectory.appendingPathComponent(String(format: "%015lld_%@", millis, scan.scanID.uuidString), isDirectory: true)
        try fileManager.createDirectory(at: item, withIntermediateDirectories: true)
        if let images {
            try images.label.write(to: item.appendingPathComponent("label.jpg"), options: .atomic)
            try images.card.write(to: item.appendingPathComponent("card.jpg"), options: .atomic)
            try images.frame.write(to: item.appendingPathComponent("frame.jpg"), options: .atomic)
        }
        try JSONEncoder.scanQueue.encode(scan).write(to: item.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// Uploads the oldest pending scan. Returns `nil` when nothing is pending; throws on
    /// network or server failures so the caller can back off and retry the same scan.
    func deliverNext(using uploader: any ScanUploading) async throws -> Outcome? {
        guard let item = pendingItems().first else { return nil }
        let scan: ScanUpload
        do {
            scan = try JSONDecoder.scanQueue.decode(ScanUpload.self, from: Data(contentsOf: item.appendingPathComponent("meta.json")))
        } catch {
            moveToRejected(item)
            return .rejected(nil, "unreadable queued scan: \(error.localizedDescription)")
        }
        let images = loadImages(from: item)
        do {
            let response = try await uploader.upload(scan, images: images)
            try? fileManager.removeItem(at: item)
            return .delivered(scan, response)
        } catch let ScanClientError.rejected(status, body) {
            moveToRejected(item)
            return .rejected(scan, "HTTP \(status): \(body)")
        }
    }

    private func pendingItems() -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadImages(from item: URL) -> ScanImages? {
        let data = Self.imageKinds.map { try? Data(contentsOf: item.appendingPathComponent("\($0).jpg")) }
        guard let label = data[0], let card = data[1], let frame = data[2] else { return nil }
        return ScanImages(label: label, card: card, frame: frame)
    }

    private func moveToRejected(_ item: URL) {
        let destination = rejectedDirectory.appendingPathComponent(item.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: item, to: destination)
        } catch {
            try? fileManager.removeItem(at: item)
        }
    }
}

extension JSONEncoder {
    static let scanQueue: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let scanQueue: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
