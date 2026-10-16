import AVFoundation
import UIKit

/// Sound and haptics for scan results. The person scanning is looking at the cards, not
/// the screen, so every result needs a distinct sound.
@MainActor
final class FeedbackPlayer {
    private let newPlayer: AVAudioPlayer?
    private let duplicatePlayer: AVAudioPlayer?
    private let success = UINotificationFeedbackGenerator()
    private let tap = UIImpactFeedbackGenerator(style: .light)

    init() {
        // `.playback` keeps the beep audible with the ring/silent switch on silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        newPlayer = Self.player(ToneSynth.wav([(1320, 0.10), (0, 0.04), (1760, 0.14)]))
        duplicatePlayer = Self.player(ToneSynth.wav([(440, 0.16)], volume: 0.5))
        success.prepare()
        tap.prepare()
    }

    func playNew() {
        play(newPlayer)
        success.notificationOccurred(.success)
    }

    func playDuplicate() {
        play(duplicatePlayer)
        tap.impactOccurred()
    }

    private func play(_ player: AVAudioPlayer?) {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    private static func player(_ data: Data) -> AVAudioPlayer? {
        let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
        player?.prepareToPlay()
        return player
    }
}

/// Generates short sine-tone WAV clips, so no audio assets need to be bundled.
enum ToneSynth {
    /// `segments` are (frequency Hz, seconds); a frequency of 0 is silence.
    static func wav(_ segments: [(frequency: Double, duration: Double)], sampleRate: Int = 44_100, volume: Double = 0.8) -> Data {
        var samples: [Int16] = []
        for segment in segments {
            let count = max(0, Int(segment.duration * Double(sampleRate)))
            let fade = max(1, min(count / 4, sampleRate / 200))
            for index in 0..<count {
                guard segment.frequency > 0 else {
                    samples.append(0)
                    continue
                }
                // Short linear fades avoid audible clicks at the tone edges.
                let envelope = min(1, Double(min(index, count - 1 - index)) / Double(fade))
                let value = sin(2 * .pi * segment.frequency * Double(index) / Double(sampleRate)) * volume * envelope
                samples.append(Int16(max(-1, min(1, value)) * Double(Int16.max)))
            }
        }

        let dataSize = samples.count * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate * 2))
        data.append(littleEndian: UInt16(2))
        data.append(littleEndian: UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: UInt32(dataSize))
        for sample in samples {
            data.append(littleEndian: UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
