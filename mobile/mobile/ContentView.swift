import SwiftUI
import Combine
import AVFoundation
import Speech

// MARK: - API Service for Server Communication
@MainActor
final class iPaloAPIService: ObservableObject {
    // Replace with your actual server URL
    private let serverURL = "https://ipalo-23vj4.ondigitalocean.app/image-to-audio"
    
    @Published var isProcessing = false
    @Published var errorMessage: String?
    
    /// Send image to server and receive audio data
    func sendImageToServer(imageData: Data) async -> Data? {
        guard let url = URL(string: serverURL) else {
            print("❌ Invalid server URL")
            errorMessage = "Invalid server URL"
            return nil
        }
        
        isProcessing = true
        defer { isProcessing = false }
        
        // Create multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        
        // Add the file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30
        
        print("📤 Sending image to server: \(imageData.count) bytes (multipart)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Invalid response type")
                errorMessage = "Invalid server response"
                return nil
            }
            
            print("📥 Server response: \(httpResponse.statusCode)")
            
            guard httpResponse.statusCode == 200 else {
                print("❌ Server error: \(httpResponse.statusCode)")
                errorMessage = "Server returned error: \(httpResponse.statusCode)"
                return nil
            }
            
            print("✅ Received audio data: \(data.count) bytes")
            return data
            
        } catch {
            print("❌ Network error: \(error.localizedDescription)")
            errorMessage = "Network error: \(error.localizedDescription)"
            return nil
        }
    }
}

// MARK: - Simple command set
enum VoiceCommand: String, Equatable {
    case iPalo = "iPalo"
    case unknown
}

// MARK: - Sliding window phrase matcher
struct CommandLexicon {
    static let phrases: [VoiceCommand: [String]] = [
        .iPalo: [
            "ipalo", "ipolo", "i paula", "hi paulo", "hi paul", "i paul",
            "i polo", "i palo", "ipad", "hi pam", "i paulo", "hi pal"
        ]
    ]

    static func norm(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "[^a-z\\s']", with: "", options: .regularExpression)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lev(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    static func match(from transcript: String) -> (VoiceCommand, Double) {
        let normalized = norm(transcript)
        guard !normalized.isEmpty else { return (.unknown, 0) }

        let words = normalized.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return (.unknown, 0) }

        let minWindow = 1
        let maxWindow = 3

        var bestMatch: (VoiceCommand, Double) = (.unknown, 0)

        for windowSize in minWindow...maxWindow {
            for startIdx in stride(from: words.count - windowSize, through: max(0, words.count - maxWindow - 3), by: -1) {
                guard startIdx >= 0 else { continue }
                
                let endIdx = min(startIdx + windowSize, words.count)
                let window = words[startIdx..<endIdx].joined(separator: " ")
                
                for (cmd, variants) in phrases {
                    for variant in variants {
                        let normVariant = norm(variant)
                        
                        if window == normVariant {
                            print("🎯 EXACT MATCH: '\(window)' == '\(normVariant)'")
                            return (cmd, 1.0)
                        }
                        
                        let distance = lev(window, normVariant)
                        let maxLen = max(window.count, normVariant.count)
                        let score = 1.0 - Double(distance) / Double(maxLen)
                        
                        if score > bestMatch.1 {
                            bestMatch = (cmd, score)
                            if score >= 0.75 {
                                print("🔍 Window match: '\(window)' ≈ '\(normVariant)' (score: \(String(format: "%.2f", score)))")
                            }
                        }
                    }
                }
            }
        }

        return bestMatch
    }

    static var contextualStrings: [String] {
        phrases.values.flatMap { $0 }
    }
}

// MARK: - Camera
@MainActor
final class OpenCam: NSObject, AVCapturePhotoCaptureDelegate, ObservableObject {
    enum Position {
        case back, front
        var avPosition: AVCaptureDevice.Position { self == .back ? .back : .front }
    }

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var captureCompletion: ((Data?) -> Void)?
    
    @Published var errorMessage: String?

    func startPrewarmed(position: Position = .back) async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else {
            errorMessage = "Camera permission denied"
            return
        }

        if !isConfigured { configureSession(position: position) }
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    func stop() {
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.stopRunning()
            }
        }
    }

    func captureOnce(completion: @escaping (Data?) -> Void) {
        guard isConfigured, session.isRunning else {
            print("❌ Camera not ready")
            completion(nil)
            return
        }
        
        captureCompletion = completion
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
        print("📸 Photo capture initiated")
    }

    private func configureSession(position: Position) {
        session.beginConfiguration()
        session.sessionPreset = .photo

        if let existing = videoDeviceInput {
            session.removeInput(existing)
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position.avPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            errorMessage = "Failed to configure camera"
            return
        }
        
        session.addInput(input)
        videoDeviceInput = input

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
        isConfigured = true
        print("✅ Camera configured successfully")
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            print("❌ Photo capture error: \(error.localizedDescription)")
            captureCompletion?(nil)
            captureCompletion = nil
            return
        }
        
        let data = photo.fileDataRepresentation()
        print("✅ Photo captured: \(data?.count ?? 0) bytes")
        captureCompletion?(data)
        captureCompletion = nil
    }
}

// MARK: - Speech Recognition
@MainActor
final class PhraseSpotterVM: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var lastCommand: VoiceCommand = .unknown
    @Published var score: Double = 0
    @Published var transcript: String = ""
    @Published var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var shouldKeepListening = false
    private var isPausedForAction = false
    private var lastTriggerTime: Date?
    private let triggerCooldown: TimeInterval = 3.0

    func startContinuous() async {
        shouldKeepListening = true
        await start()
    }

    func pause() {
        print("⏸️ Pausing speech recognition")
        isPausedForAction = true
        stopInternal()
    }

    func resume() async {
        print("▶️ Resuming speech recognition")
        isPausedForAction = false
        if shouldKeepListening { await start() }
    }

    func stopAll() {
        shouldKeepListening = false
        isPausedForAction = false
        stopInternal()
    }
    
    func resetCommand() {
        lastCommand = .unknown
        score = 0
    }

    private func start() async {
        guard await ensureAuth() else {
            errorMessage = "Microphone or speech recognition permission denied"
            return
        }
        guard !audioEngine.isRunning else { return }

        isRecording = true

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("❌ Audio session error: \(error)")
            errorMessage = "Failed to configure audio session"
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = false
        req.contextualStrings = CommandLexicon.contextualStrings
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            print("🎤 Listening for 'iPalo'...")
        } catch {
            print("❌ Failed to start audio engine: \(error)")
            errorMessage = "Failed to start microphone"
            return
        }

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            
            if let r = result {
                let text = r.bestTranscription.formattedString
                Task { @MainActor in
                    self.transcript = text
                    let (cmd, sc) = CommandLexicon.match(from: text)
                    
                    let now = Date()
                    let canTrigger: Bool = {
                        guard let lastTime = self.lastTriggerTime else { return true }
                        return now.timeIntervalSince(lastTime) >= self.triggerCooldown
                    }()
                    
                    if sc >= 0.75 && cmd != .unknown && canTrigger {
                        print("✅ COMMAND TRIGGERED: \(cmd) with score \(String(format: "%.2f", sc))")
                        self.lastCommand = cmd
                        self.score = sc
                        self.lastTriggerTime = now
                    }
                }
            }
            
            if error != nil || (result?.isFinal ?? false) {
                self.stopInternal()
                Task { @MainActor in
                    if self.shouldKeepListening && !self.isPausedForAction {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await self.start()
                    }
                }
            }
        }
    }

    private func stopInternal() {
        isRecording = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func ensureAuth() async -> Bool {
        let micGranted: Bool = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard micGranted else {
            print("❌ Microphone permission denied")
            return false
        }

        let status = await withCheckedContinuation {
            (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }

        guard status == .authorized else {
            print("❌ Speech recognition permission denied")
            return false
        }
        
        print("✅ All permissions granted")
        return true
    }
}

// MARK: - Audio Player
@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completionHandler: (() -> Void)?
    
    func playAudio(data: Data, onFinish: @escaping () -> Void) {
        completionHandler = onFinish
        
        do {
            // Configure audio session for playback
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            
            // Create and configure player
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.prepareToPlay()
            
            print("🔊 Starting audio playback...")
            player?.play()
            
        } catch {
            print("❌ Audio playback error: \(error.localizedDescription)")
            completionHandler?()
            completionHandler = nil
        }
    }
    
    func stop() {
        player?.stop()
        player = nil
    }
    
    // AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("✅ Audio playback finished")
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        completionHandler?()
        completionHandler = nil
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("❌ Audio decode error: \(error?.localizedDescription ?? "unknown")")
        completionHandler?()
        completionHandler = nil
    }
}

// MARK: - Pulse Animation
final class PulseLevelModel: ObservableObject {
    @Published var level: CGFloat = 0.1
    private var timer: AnyCancellable?

    init() {
        var t: Double = 0
        timer = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                t += 0.05
                let v = (sin(t * 2) + 1) / 2
                self.level = CGFloat(0.05 + 0.95 * v)
            }
    }

    deinit { timer?.cancel() }
}

// MARK: - Main UI
struct ContentView: View {
    @StateObject private var pulseModel = PulseLevelModel()
    @StateObject private var vm = PhraseSpotterVM()
    @StateObject private var camera = OpenCam()
    @StateObject private var apiService = iPaloAPIService()
    @StateObject private var audioPlayer = AudioPlayer()
    
    @State private var capturedImage: UIImage?
    @State private var isBusy = false
    @State private var statusMessage = "Say 'iPalo' to start"

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                Text("iPalo")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 16)
                    .font(.system(size: 32, weight: .thin, design: .monospaced))
                    .foregroundColor(.black)

                Spacer()

                VoicePulseView(level: pulseModel.level, isListening: vm.isRecording)
                    .frame(height: 240)
                
                Text(statusMessage)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(vm.isRecording ? .green : .gray)
                    .padding(.top, 8)
                
                if !vm.transcript.isEmpty {
                    Text("🎤 \"\(vm.transcript)\"")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .lineLimit(3)
                }

                Spacer()
                
                if let img = capturedImage {
                    VStack {
                        Text("Last Capture:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 200)
                            .cornerRadius(12)
                            .shadow(radius: 4)
                            .padding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal)
        }
        .onAppear {
            print("🚀 iPalo started - say 'iPalo' to activate")
            Task {
                await camera.startPrewarmed(position: .back)
                await vm.startContinuous()
            }
        }
        .onChange(of: vm.lastCommand) { oldValue, newValue in
            guard vm.score >= 0.75 else { return }
            guard newValue != oldValue else { return }
            guard newValue == .iPalo else { return }
            
            print("🎯 'iPalo' detected - starting pipeline")
            triggerPipeline()
        }
    }

    private func triggerPipeline() {
        guard !isBusy else {
            print("⚠️ Pipeline already running")
            return
        }
        
        isBusy = true
        statusMessage = "Capturing..."
        print("\n🔄 === PIPELINE START ===")

        vm.pause()
        vm.resetCommand()

        // Step 1: Capture photo
        camera.captureOnce { jpegData in
            guard let jpegData = jpegData else {
                print("❌ Failed to capture photo")
                statusMessage = "Camera error"
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await vm.resume()
                    isBusy = false
                    statusMessage = "Say 'iPalo' to start"
                }
                return
            }
            
            print("✅ Photo captured: \(jpegData.count) bytes")
            
            if let uiImage = UIImage(data: jpegData) {
                Task { @MainActor in
                    capturedImage = uiImage
                }
            }
            
            // Step 2: Send to server and get audio
            Task { @MainActor in
                statusMessage = "Analyzing..."
                
                guard let audioData = await apiService.sendImageToServer(imageData: jpegData) else {
                    print("❌ Failed to get audio from server")
                    statusMessage = "Server error"
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await vm.resume()
                    isBusy = false
                    statusMessage = "Say 'iPalo' to start"
                    return
                }
                
                // Step 3: Play audio response
                statusMessage = "Speaking..."
                audioPlayer.playAudio(data: audioData) {
                    Task { @MainActor in
                        print("🔄 Pipeline complete, resuming listening")
                        statusMessage = "Say 'iPalo' to start"
                        await vm.resume()
                        isBusy = false
                        print("=== PIPELINE END ===\n")
                    }
                }
            }
        }
    }
}

// MARK: - Visual Pulse
struct VoicePulseView: View {
    var level: CGFloat
    var isListening: Bool = true

    private let minScale: CGFloat = 0.95
    private let maxScale: CGFloat = 1.45
    private let baseDiameter: CGFloat = 160

    private let animation = Animation.interpolatingSpring(
        mass: 0.50,
        stiffness: 30,
        damping: 18,
        initialVelocity: 0
    )

    var body: some View {
        let scale = minScale + (maxScale - minScale) * level
        let color: Color = isListening ? .black : .gray

        ZStack {
            Circle()
                .fill(color)
                .frame(width: baseDiameter, height: baseDiameter)
                .shadow(color: .gray.opacity(0.25), radius: 10, x: 0, y: 4)

            Circle()
                .fill(color.opacity(0.10))
                .frame(width: baseDiameter, height: baseDiameter)
                .scaleEffect(scale)
                .animation(animation, value: level)
                .shadow(color: .gray.opacity(0.95), radius: 10, x: 0, y: 4)
        }
    }
}
