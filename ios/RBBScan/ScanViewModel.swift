import Foundation
import Observation
import PasscodeCore
import UIKit

@MainActor
@Observable
final class ScanViewModel {
    struct RecentScan: Identifiable, Equatable {
        let id: UUID
        let code: String
        let isNew: Bool
        var seenCount: Int
        let uncertainPositions: [Int]
    }

    private static let serverURLKey = "serverURL"

    // Counter: the server's total once known (it is the source of truth), else the local one.
    private(set) var serverUnique: Int?
    private(set) var targetTotal = 1050
    private(set) var localUnique = 0
    var displayedUnique: Int { serverUnique ?? localUnique }

    private(set) var recent: [RecentScan] = []
    private(set) var latest: RecentScan?
    private(set) var pendingUploads = 0
    private(set) var serverReachable = false
    private(set) var lastError: String?
    private(set) var cameraRunning = false
    private(set) var frame = FrameProcessor.FrameUpdate(boxes: [], confirmedBoxes: [], imageSize: .zero, tracks: [])

    var torchOn = false {
        didSet { camera.setTorch(torchOn) }
    }

    var paused = false {
        didSet { processor?.setPaused(paused) }
    }

    var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: Self.serverURLKey) }
    }

    let camera = CameraController()
    private var processor: FrameProcessor?
    private var registry = PasscodeRegistry()
    private let feedback = FeedbackPlayer()
    private let queue: UploadQueue?
    private var backgroundTasks: [Task<Void, Never>] = []
    private let deviceName = UIDevice.current.name

    init() {
        serverURLString = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? ""
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            queue = try UploadQueue(directory: support.appendingPathComponent("UploadQueue", isDirectory: true))
        } catch {
            queue = nil
            lastError = "Cannot store scans offline: \(error.localizedDescription)"
        }
        processor = FrameProcessor(
            onDetection: { [weak self] detection in
                Task { @MainActor in self?.handle(detection) }
            },
            onFrame: { [weak self] update in
                Task { @MainActor in self?.frame = update }
            }
        )
    }

    var client: ScanClient? {
        ScanViewModel.validatedURL(serverURLString).map { ScanClient(baseURL: $0) }
    }

    static func validatedURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    func start() async {
        guard !cameraRunning, let processor else { return }
        guard await CameraController.requestAccess() else {
            lastError = "Camera access is off. Enable it in Settings › RBB Scan."
            return
        }
        do {
            try await camera.start(delegate: processor)
        } catch {
            lastError = error.localizedDescription
            return
        }
        cameraRunning = true
        if torchOn { camera.setTorch(true) }
        UIApplication.shared.isIdleTimerDisabled = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        backgroundTasks = [
            Task { [weak self] in await self?.syncWithServer() },
            Task { [weak self] in await self?.runUploads() },
            Task { [weak self] in await self?.runHeartbeats() },
        ]
        await refreshPendingCount()
    }

    func stop() {
        backgroundTasks.forEach { $0.cancel() }
        backgroundTasks = []
        camera.stop()
        cameraRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Loads the passcodes the server already has, so re-scanning an old card beeps as a duplicate.
    func syncWithServer() async {
        guard let client else { return }
        do {
            registry.merge(serverKeys: try await client.knownKeys())
            localUnique = registry.uniqueCount
            let stats = try await client.stats()
            apply(uniqueTotal: stats.uniqueTotal, targetTotal: stats.targetTotal)
            serverReachable = true
        } catch {
            serverReachable = false
        }
    }

    private func handle(_ detection: FrameProcessor.Detection) {
        let code = detection.confirmed
        let scan = ScanUpload(code, device: deviceName, capturedAt: detection.capturedAt)
        let entry: RecentScan
        switch registry.record(code.code) {
        case .new:
            feedback.playNew()
            entry = RecentScan(id: scan.scanID, code: code.code, isNew: true, seenCount: 1, uncertainPositions: code.uncertainPositions)
        case .duplicate(_, let seenCount):
            feedback.playDuplicate()
            entry = RecentScan(id: scan.scanID, code: code.code, isNew: false, seenCount: seenCount, uncertainPositions: code.uncertainPositions)
        }
        localUnique = registry.uniqueCount
        latest = entry
        recent = Array(([entry] + recent).prefix(5))

        guard let queue else { return }
        Task {
            do {
                try await queue.enqueue(scan, images: detection.images)
            } catch {
                lastError = "Could not save scan \(code.code): \(error.localizedDescription)"
            }
            await refreshPendingCount()
        }
    }

    private func runUploads() async {
        guard let queue else { return }
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            guard let client else {
                serverReachable = false
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            do {
                if let outcome = try await queue.deliverNext(using: client) {
                    handle(outcome)
                    serverReachable = true
                    backoff = .seconds(1)
                } else {
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch is CancellationError {
                return
            } catch {
                serverReachable = false
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(15))
            }
            await refreshPendingCount()
        }
    }

    private func handle(_ outcome: UploadQueue.Outcome) {
        switch outcome {
        case .delivered(let scan, let response):
            apply(uniqueTotal: response.uniqueTotal, targetTotal: response.targetTotal)
            if let index = recent.firstIndex(where: { $0.id == scan.scanID }) {
                recent[index].seenCount = response.seenCount
            }
            if latest?.id == scan.scanID {
                latest?.seenCount = response.seenCount
            }
        case .rejected(let scan, let reason):
            lastError = "Server rejected \(scan?.code ?? "a scan"): \(reason)"
        }
    }

    private func runHeartbeats() async {
        while !Task.isCancelled {
            if let client, let processor {
                let battery = UIDevice.current.batteryLevel
                let status = HeartbeatStatus(
                    device: deviceName,
                    cameraRunning: cameraRunning,
                    paused: paused,
                    torch: torchOn,
                    tracking: frame.tracks,
                    pendingUploads: pendingUploads,
                    battery: battery,
                    localUnique: localUnique
                )
                do {
                    let stats = try await client.heartbeat(status, preview: processor.latestPreview)
                    apply(uniqueTotal: stats.uniqueTotal, targetTotal: stats.targetTotal)
                    serverReachable = true
                } catch {
                    serverReachable = false
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func apply(uniqueTotal: Int, targetTotal: Int) {
        serverUnique = uniqueTotal
        self.targetTotal = targetTotal
    }

    private func refreshPendingCount() async {
        if let queue {
            pendingUploads = await queue.pendingCount
        }
    }

    func clearError() {
        lastError = nil
    }
}
