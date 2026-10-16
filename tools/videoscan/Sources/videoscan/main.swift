import AVFoundation
import CoreImage
import Foundation
import PasscodeCore

/// Replays a recorded video through the same recognizer + tracker the iPhone app uses
/// and prints every confirmed passcode. Used to tune thresholds and as a regression check.
struct Options {
    var videoPath = ""
    var fps = 10.0
    var minimumPolarity = LabelFilter.defaultMinimumPolarity
    var verbose = false
    var dumpDirectory: String?
    var expectPath: String?
    var serverURL: URL?
    var rotation = QuarterTurn.none

    static let usage = """
    usage: videoscan <video> [--fps N] [--polarity 0..1] [--rotate 0|90|180|270] [--verbose] [--dump DIR] [--expect FILE] [--post URL]
      --fps     frames per second to analyse (default 10)
      --polarity minimum label polarity, 1 = dark text on light (default \(LabelFilter.defaultMinimumPolarity))
      --rotate   turn every frame clockwise by this many degrees first, as if the cards lay sideways
      --verbose  print every passcode-shaped read with its label measurement
      --dump     write label/card/frame JPEGs of each confirmed code into DIR
      --expect   file of expected passcodes (one per line, # comments); exit 1 on any missing or extra
      --post     act as the iPhone: upload confirmed codes and send heartbeats to the server at URL
    """

    static func parse(_ arguments: [String]) -> Options? {
        var options = Options()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--fps":
                guard let value = iterator.next().flatMap(Double.init), value > 0 else { return nil }
                options.fps = value
            case "--polarity":
                guard let value = iterator.next().flatMap(Float.init), (0...1).contains(value) else { return nil }
                options.minimumPolarity = value
            case "--rotate":
                guard let value = iterator.next().flatMap(Int.init).flatMap(QuarterTurn.init(rawValue:)) else { return nil }
                options.rotation = value
            case "--verbose":
                options.verbose = true
            case "--dump":
                guard let value = iterator.next() else { return nil }
                options.dumpDirectory = value
            case "--expect":
                guard let value = iterator.next() else { return nil }
                options.expectPath = value
            case "--post":
                guard let value = iterator.next(), let url = URL(string: value), url.scheme != nil else { return nil }
                options.serverURL = url
            default:
                guard options.videoPath.isEmpty, !argument.hasPrefix("--") else { return nil }
                options.videoPath = argument
            }
        }
        return options.videoPath.isEmpty ? nil : options
    }
}

enum ScanError: Error, CustomStringConvertible {
    case noVideoTrack
    case readerFailed(String)
    case rotationFailed(CVReturn)

    var description: String {
        switch self {
        case .noVideoTrack: return "the file has no video track"
        case .readerFailed(let reason): return "could not read video: \(reason)"
        case .rotationFailed(let status): return "could not allocate a rotated frame (CVReturn \(status))"
        }
    }
}

/// Turns decoded frames so the recognizer sees the cards the way they lie when not upright.
struct FrameRotator {
    let rotation: QuarterTurn
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(rotation: QuarterTurn) {
        self.rotation = rotation
    }

    func rotate(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        guard rotation != .none else { return buffer }
        let image = CIImage(cvPixelBuffer: buffer).oriented(rotation.imageOrientation)
        let upright = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(upright.extent.width), Int(upright.extent.height),
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output
        )
        guard status == kCVReturnSuccess, let output else { throw ScanError.rotationFailed(status) }
        context.render(upright, to: output)
        return output
    }
}

/// Returns false when the scan missed expected codes or found unexpected ones.
func run(_ options: Options) async throws -> Bool {
    let asset = AVURLAsset(url: URL(fileURLWithPath: options.videoPath))
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ScanError.noVideoTrack }
    let reader = try AVAssetReader(asset: asset)
    // iPhone recordings are HDR (HLG); ask for SDR Rec.709 so frames look like the
    // live camera feed the app analyses instead of washed-out raw HLG values.
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else {
        throw ScanError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
    }

    let recognizer = PasscodeRecognizer(minimumPolarity: options.minimumPolarity)
    let tracker = CandidateTracker()
    let renderer = SnapshotRenderer()
    let rotator = FrameRotator(rotation: options.rotation)
    if let directory = options.dumpDirectory {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    var registry = PasscodeRegistry()
    var found: [String] = []
    let client = options.serverURL.map { ScanClient(baseURL: $0) }
    var nextHeartbeat = 0.0
    var nextSampleTime = 0.0
    var analysedFrames = 0
    let started = Date()

    while let sample = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard time >= nextSampleTime, let decoded = CMSampleBufferGetImageBuffer(sample) else { continue }
        let buffer = try rotator.rotate(decoded)
        nextSampleTime = time + 1 / options.fps
        analysedFrames += 1

        let (observations, accepted) = try recognizer.analyze(buffer)
        if options.verbose {
            for observation in observations {
                let label = observation.label.map {
                    String(format: "pol=%.2f mean=%.2f p10=%.2f p50=%.2f p90=%.2f", $0.polarity, $0.mean, $0.p10, $0.median, $0.p90)
                } ?? "label=n/a"
                let verdict = recognizer.accepts(observation) ? "keep" : "drop"
                print(String(format: "  %7.2fs %@ %@ conf=%.2f %@", time, verdict, observation.read.text, observation.read.confidence, label))
            }
        }
        for code in tracker.ingest(accepted, at: time) {
            let status: String
            switch registry.record(code.code) {
            case .new:
                status = "NEW  ×1"
                found.append(code.code)
            case .duplicate(_, let count): status = "seen ×\(count)"
            }
            let uncertain = code.uncertainPositions.isEmpty ? "" : " uncertain@\(code.uncertainPositions.map { $0 + 1 })"
            print(String(format: "%7.2fs %@ %@ (reads=%d conf=%.2f rot=%d)%@", time, status, code.code, code.readCount, code.confidence, code.rotation.rawValue, uncertain))
            if let client {
                let response = try await client.upload(ScanUpload(code, device: "videoscan"),
                                                       images: renderer.images(from: buffer, quad: code.quad))
                print("         server: \(response.isNew ? "new" : "seen ×\(response.seenCount)") unique=\(response.uniqueTotal)")
            }
            if let directory = options.dumpDirectory,
               let images = renderer.images(from: buffer, quad: code.quad) {
                let base = URL(fileURLWithPath: directory).appendingPathComponent("\(code.code)_\(Int(time * 100))")
                try images.label.write(to: base.appendingPathExtension("label.jpg"))
                try images.card.write(to: base.appendingPathExtension("card.jpg"))
                try images.frame.write(to: base.appendingPathExtension("frame.jpg"))
            }
        }
        if let client, time >= nextHeartbeat {
            nextHeartbeat = time + 1
            let status = HeartbeatStatus(device: "videoscan", cameraRunning: true, paused: false, torch: false,
                                         tracking: tracker.activeTracks, pendingUploads: 0, battery: -1,
                                         localUnique: registry.uniqueCount)
            try await client.heartbeat(status, preview: renderer.preview(from: buffer))
        }
    }
    if reader.status == .failed {
        throw ScanError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
    }

    print("")
    print(String(format: "unique=%d frames=%d elapsed=%.1fs", registry.uniqueCount, analysedFrames, Date().timeIntervalSince(started)))

    guard let expectPath = options.expectPath else { return true }
    let expected = try String(contentsOfFile: expectPath, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    var expectedRegistry = PasscodeRegistry()
    expected.forEach { expectedRegistry.record($0) }
    var foundRegistry = PasscodeRegistry()
    found.forEach { foundRegistry.record($0) }
    let missing = expected.filter { foundRegistry.match($0) == nil }
    let extra = found.filter { expectedRegistry.match($0) == nil }
    print("expected=\(expected.count) missing=\(missing.count) extra=\(extra.count)")
    missing.forEach { print("  missing \($0)") }
    extra.forEach { print("  extra   \($0)") }
    return missing.isEmpty && extra.isEmpty
}

guard let options = Options.parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data((Options.usage + "\n").utf8))
    exit(2)
}
do {
    if try await !run(options) { exit(1) }
} catch {
    FileHandle.standardError.write(Data("videoscan: \(error)\n".utf8))
    exit(1)
}
