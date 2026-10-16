import AVFoundation
import PasscodeCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: ScanViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            CameraPreview(session: model.camera.session)
                .ignoresSafeArea()
            DetectionOverlay(frame: model.frame)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 12) {
                CounterCard(model: model)
                Spacer()
                if let latest = model.latest {
                    LatestBanner(scan: latest)
                }
                RecentList(scans: model.recent)
                Controls(model: model, showingSettings: $showingSettings)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
        .alert("RBB Scan", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.clearError() } })) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: {
            Text(model.lastError ?? "")
        }
        .task {
            showingSettings = model.client == nil
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.start() }
            case .background: model.stop()
            default: break
            }
        }
    }
}

private struct CounterCard: View {
    let model: ScanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(model.displayedUnique)")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("/ \(model.targetTotal)")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                StatusBadge(reachable: model.serverReachable, pending: model.pendingUploads)
            }
            ProgressView(value: Double(min(model.displayedUnique, model.targetTotal)), total: Double(max(model.targetTotal, 1)))
                .tint(.indigo)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .animation(.snappy, value: model.displayedUnique)
    }
}

private struct StatusBadge: View {
    let reachable: Bool
    let pending: Int

    var body: some View {
        let (color, text): (Color, String) = switch (reachable, pending) {
        case (true, 0): (.green, "Mac connected")
        case (true, _): (.orange, "\(pending) uploading")
        case (false, 0): (.red, "Mac offline")
        case (false, _): (.red, "Offline · \(pending) saved")
        }
        Label(text, systemImage: "circle.fill")
            .font(.footnote.weight(.semibold))
            .labelStyle(BadgeLabelStyle(color: color))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.2), in: Capsule())
    }
}

private struct BadgeLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 8)).foregroundStyle(color)
            configuration.title
        }
    }
}

private struct LatestBanner: View {
    let scan: ScanViewModel.RecentScan

    var body: some View {
        VStack(spacing: 6) {
            Text(scan.isNew ? "NEW" : "DUPLICATE · seen ×\(scan.seenCount)")
                .font(.headline.weight(.heavy))
                .foregroundStyle(scan.isNew ? .black : .black)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(scan.isNew ? Color.green : Color.orange, in: Capsule())
            PasscodeText(code: scan.code, uncertain: scan.uncertainPositions)
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .id(scan.id)
        .transition(.scale.combined(with: .opacity))
    }
}

/// Renders a passcode with characters the scanner was unsure about in red.
struct PasscodeText: View {
    let code: String
    let uncertain: [Int]

    var body: some View {
        let unsure = Set(uncertain)
        Text(code.enumerated().reduce(AttributedString()) { result, element in
            var piece = AttributedString(String(element.element))
            if unsure.contains(element.offset) {
                piece.foregroundColor = .red
                piece.underlineStyle = .single
            }
            return result + piece
        })
    }
}

private struct RecentList: View {
    let scans: [ScanViewModel.RecentScan]

    var body: some View {
        if !scans.isEmpty {
            VStack(spacing: 4) {
                ForEach(scans) { scan in
                    HStack {
                        PasscodeText(code: scan.code, uncertain: scan.uncertainPositions)
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text(scan.isNew ? "new" : "×\(scan.seenCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(scan.isNew ? .green : .orange)
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct Controls: View {
    @Bindable var model: ScanViewModel
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 12) {
            ControlButton(systemImage: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill", label: "Torch", active: model.torchOn) {
                model.torchOn.toggle()
            }
            ControlButton(systemImage: model.paused ? "play.fill" : "pause.fill", label: model.paused ? "Resume" : "Pause", active: model.paused) {
                model.paused.toggle()
            }
            ControlButton(systemImage: "gearshape.fill", label: "Server", active: false) {
                showingSettings = true
            }
        }
    }
}

private struct ControlButton: View {
    let systemImage: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(label).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(active ? .black : .white)
            .background(active ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.ultraThinMaterial), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Outlines passcode reads on the preview: yellow while being read, green when confirmed.
private struct DetectionOverlay: View {
    let frame: FrameProcessor.FrameUpdate

    var body: some View {
        GeometryReader { geometry in
            let mapping = AspectFillMapping(imageSize: frame.imageSize, viewSize: geometry.size)
            ZStack {
                ForEach(Array(frame.boxes.enumerated()), id: \.offset) { _, box in
                    outline(mapping.rect(for: box), color: .yellow)
                }
                ForEach(Array(frame.confirmedBoxes.enumerated()), id: \.offset) { _, box in
                    outline(mapping.rect(for: box), color: .green)
                }
            }
        }
    }

    private func outline(_ rect: CGRect, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(color, lineWidth: 3)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

/// Maps Vision's normalized, bottom-left-origin boxes onto a view showing the frame with
/// `.resizeAspectFill`.
struct AspectFillMapping {
    let imageSize: CGSize
    let viewSize: CGSize

    func rect(for visionBox: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let offsetX = (viewSize.width - imageSize.width * scale) / 2
        let offsetY = (viewSize.height - imageSize.height * scale) / 2
        return CGRect(
            x: offsetX + visionBox.minX * imageSize.width * scale,
            y: offsetY + (1 - visionBox.maxY) * imageSize.height * scale,
            width: visionBox.width * imageSize.width * scale,
            height: visionBox.height * imageSize.height * scale
        )
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}
