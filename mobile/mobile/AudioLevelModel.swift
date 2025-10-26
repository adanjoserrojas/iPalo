import Foundation
import AVFoundation
import Accelerate   // for vDSP RMS
import SwiftUI      // for CGFloat
import Combine

final class AudioLevelModel: ObservableObject {
    @Published var level: CGFloat = 0.0

    private let engine = AVAudioEngine()
    private var isStarted = false

    /// Smoother feel: 0.05 = very floaty, 0.3 = snappier
    private let smoothing: CGFloat = 0.18

    init() {
        // Start immediately; you can move this to an explicit start() if you prefer.
        configureAndStart()
    }

    deinit {
        stop()
    }

    // MARK: - Public control (optional)
    func start() { if !isStarted { configureAndStart() } }
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isStarted = false
    }

    // MARK: - Setup
    private func configureAndStart() {
        guard !isStarted else { return }

        let session = AVAudioSession.sharedInstance()

        // Request mic permission (new API on iOS 17+, fallback on older)
        let requestPermission: (@escaping (Bool) -> Void) -> Void = { completion in
            if #available(iOS 17.0, *) {
                // New API lives in AVFAudio. AVFoundation re-exports it, so your current import is fine.
                AVAudioApplication.requestRecordPermission { granted in
                    completion(granted)
                }
            } else {
                session.requestRecordPermission { granted in
                    completion(granted)
                }
            }
        }

        requestPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.level = 0
                    print("Microphone permission denied.")
                    return
                }

                do {
                    // Category & mode: good for live input + future TTS playback
                    try session.setCategory(.playAndRecord,
                                            mode: .measurement,
                                            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])

                    // Prefer values; system may override. You can also omit these if you like.
                    try session.setPreferredSampleRate(44_100)
                    try session.setPreferredIOBufferDuration(0.0232)

                    try session.setActive(true, options: [])

                    let input = self.engine.inputNode
                    let bus = 0

                    // Use native format to avoid sample-rate/channel mismatches
                    let format = input.outputFormat(forBus: bus)

                    // Clean any previous tap
                    input.removeTap(onBus: bus)

                    // Install tap; do NOT modify buffer.frameLength inside the callback
                    input.installTap(onBus: bus, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                        self?.process(buffer: buffer)
                    }

                    self.engine.prepare()
                    try self.engine.start()
                    self.isStarted = true
                } catch {
                    print("Audio engine start error:", error)
                    self.level = 0
                }
            }
        }
    }

    // MARK: - Processing
    private func process(buffer: AVAudioPCMBuffer) {
        // Never change buffer.frameLength — use what we get.
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        guard let channelData = buffer.floatChannelData else { return }

        let channels = Int(buffer.format.channelCount)
        var meanSquares: [Float] = Array(repeating: 0, count: channels)

        // vDSP_measqv returns the mean of squares directly
        for ch in 0..<channels {
            vDSP_measqv(channelData[ch], 1, &meanSquares[ch], vDSP_Length(frameCount))
        }

        // Average channels then sqrt → RMS
        var msAvg = meanSquares.reduce(0, +) / Float(channels)
        msAvg = max(msAvg, 1e-12) // avoid log of zero
        let rms = sqrtf(msAvg)

        // Convert to dBFS roughly; map [-60, 0] dB to [0, 1]
        let db = 20 * log10f(rms)
        let normalized = max(0, min(1, CGFloat((db + 60) / 60))) // clamp

        // Low-pass smoothing to make the circle feel even smoother
        DispatchQueue.main.async {
            self.level = self.level * (1 - self.smoothing) + normalized * self.smoothing
        }
    }
}
