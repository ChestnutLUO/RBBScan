import AVFoundation
import os
import PasscodeCore

/// Runs OCR on camera frames. Recognizer, tracker and renderer are only used on the
/// camera's video queue; `shared` is the only state touched from other threads.
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Detection: Sendable {
        let confirmed: ConfirmedCode
        let images: ScanImages?
        let capturedAt: Date
    }

    struct FrameUpdate: Sendable {
        /// Vision boxes (normalized, bottom-left origin) of passcode reads in this frame.
        let boxes: [CGRect]
        let confirmedBoxes: [CGRect]
        let imageSize: CGSize
        let tracks: [TrackSnapshot]
    }

    private struct Shared {
        var paused = false
        var latestPreview: Data?
    }

    private let recognizer = PasscodeRecognizer()
    private let tracker = CandidateTracker()
    private let renderer = SnapshotRenderer()
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RBBScan", category: "frames")
    private var lastPreviewTime = -Double.infinity
    private let onDetection: @Sendable (Detection) -> Void
    private let onFrame: @Sendable (FrameUpdate) -> Void

    init(onDetection: @escaping @Sendable (Detection) -> Void, onFrame: @escaping @Sendable (FrameUpdate) -> Void) {
        self.onDetection = onDetection
        self.onFrame = onFrame
    }

    func setPaused(_ paused: Bool) {
        shared.withLock { $0.paused = paused }
    }

    /// The most recent small JPEG of the camera view, refreshed about once a second.
    var latestPreview: Data? {
        shared.withLock { $0.latestPreview }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))

        if time - lastPreviewTime >= 1 {
            lastPreviewTime = time
            let preview = renderer.preview(from: buffer)
            shared.withLock { $0.latestPreview = preview }
        }
        if shared.withLock({ $0.paused }) {
            onFrame(FrameUpdate(boxes: [], confirmedBoxes: [], imageSize: size, tracks: []))
            return
        }

        let reads: [TextRead]
        do {
            reads = try recognizer.recognize(buffer)
        } catch {
            logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
            reads = []
        }
        let confirmed = tracker.ingest(reads, at: time)
        for code in confirmed {
            let images = renderer.images(from: buffer, quad: code.quad)
            onDetection(Detection(confirmed: code, images: images, capturedAt: Date()))
        }
        onFrame(FrameUpdate(
            boxes: reads.map(\.boundingBox),
            confirmedBoxes: confirmed.map(\.boundingBox),
            imageSize: size,
            tracks: tracker.activeTracks
        ))
    }
}
