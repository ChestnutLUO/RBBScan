import AVFoundation

/// Owns the capture session. Session configuration and start/stop run on `sessionQueue`;
/// frames are delivered to the delegate on `videoQueue`.
final class CameraController: @unchecked Sendable {
    enum SetupError: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No back camera is available."
            case .cannotAddInput: return "The camera could not be connected."
            case .cannotAddOutput: return "Camera frames could not be read."
            }
        }
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "rbbscan.camera.session")
    private let videoQueue = DispatchQueue(label: "rbbscan.camera.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    // Only touched on sessionQueue.
    private var device: AVCaptureDevice?
    private var configured = false

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start(delegate: FrameProcessor) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    if !self.configured {
                        try self.configure(delegate: delegate)
                        self.configured = true
                    }
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let device = self.device, device.hasTorch, device.isTorchAvailable else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = on ? .on : .off
                device.unlockForConfiguration()
            } catch {
                // Torch is a convenience; scanning continues without it.
            }
        }
    }

    private func configure(delegate: FrameProcessor) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = Self.bestBackCamera() else { throw SetupError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SetupError.cannotAddInput }
        session.addInput(input)
        // 4K keeps 16-character codes legible when several cards are in view.
        session.sessionPreset = session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .hd1920x1080

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        // While Vision is busy, newer frames replace older ones instead of queueing up.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: videoQueue)
        guard session.canAddOutput(output) else { throw SetupError.cannotAddOutput }
        session.addOutput(output)
        // PasscodeCore expects upright frames; the UI is portrait-only.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        try device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        // HDR video tone-maps unpredictably; plain SDR gives the label filter stable contrast.
        if device.activeFormat.isVideoHDRSupported {
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
        }
        device.unlockForConfiguration()
        self.device = device
    }

    /// Virtual multi-lens devices switch to the ultra-wide lens automatically when a card is
    /// closer than the main lens can focus.
    private static func bestBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return nil
    }
}
