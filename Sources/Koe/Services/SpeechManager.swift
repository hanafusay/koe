import AVFoundation
import Speech

@MainActor
final class SpeechManager: ObservableObject {
    static let shared = SpeechManager()

    @Published var isRecording = false
    @Published var recognizedText = ""
    @Published var partialText = ""
    @Published var errorMessage = ""

    private var audioEngine = AVAudioEngine()
    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioCaptureDelegate?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var usingCaptureSession = false

    private init() {
        updateRecognizer(language: Config.shared.recognitionLanguage)
    }

    func updateRecognizer(language: String) {
        let locale = Locale(identifier: language)
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        if let recognizer = speechRecognizer {
            Log.d("[SpeechManager] Recognizer for \(language): available=\(recognizer.isAvailable)")
        } else {
            Log.d("[SpeechManager] Failed to create recognizer for \(language)")
        }
    }

    func startRecording() throws {
        errorMessage = ""

        // Cancel any ongoing task
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        // 前回のセッションをクリーンアップ
        stopAudioCapture()

        guard let speechRecognizer = speechRecognizer else {
            throw SpeechError.recognizerUnavailable
        }

        guard speechRecognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        self.recognitionRequest = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let result = result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.recognizedText = text
                        self.partialText = ""
                        Log.d("[SpeechManager] Final: \(text)")
                        // Debug: log per-segment confidence
                        for seg in result.bestTranscription.segments {
                            Log.d("[SpeechManager]   segment: \"\(seg.substring)\" confidence=\(seg.confidence) duration=\(seg.duration)")
                        }
                        // Debug: log alternative transcriptions
                        for (i, alt) in result.transcriptions.dropFirst().prefix(3).enumerated() {
                            Log.d("[SpeechManager]   alt[\(i+1)]: \(alt.formattedString)")
                        }
                    } else {
                        self.partialText = text
                    }
                }

                if let error = error {
                    let nsError = error as NSError
                    // Ignore cancellation errors (code 216 = request was cancelled)
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                        return
                    }
                    Log.d("[SpeechManager] Error: \(error.localizedDescription)")
                    self.errorMessage = error.localizedDescription
                }
            }
        }

        // デバイス指定がある場合は AVCaptureSession、なければ AVAudioEngine
        let selectedUID = Config.shared.audioInputDeviceUID
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        if !selectedUID.isEmpty, let device = discoverySession.devices.first(where: { $0.uniqueID == selectedUID }) {
            try startWithCaptureSession(device: device)
        } else {
            if !selectedUID.isEmpty {
                Log.d("[SpeechManager] デバイスが見つかりません: \(selectedUID)、システムデフォルトを使用")
            }
            try startWithAudioEngine()
        }

        isRecording = true
        recognizedText = ""
        partialText = ""
        Log.d("[SpeechManager] Recording started")
    }

    private func startWithAudioEngine() throws {
        usingCaptureSession = false
        audioEngine = AVAudioEngine()

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        Log.d("[SpeechManager] AVAudioEngine フォーマット: ch=\(recordingFormat.channelCount), rate=\(recordingFormat.sampleRate)")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startWithCaptureSession(device: AVCaptureDevice) throws {
        usingCaptureSession = true
        let session = AVCaptureSession()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw SpeechError.deviceUnavailable
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        let delegate = AudioCaptureDelegate { [weak self] sampleBuffer in
            self?.recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
        }
        self.captureDelegate = delegate
        let queue = DispatchQueue(label: "com.koe.audiocapture")
        output.setSampleBufferDelegate(delegate, queue: queue)

        guard session.canAddOutput(output) else {
            throw SpeechError.deviceUnavailable
        }
        session.addOutput(output)

        session.startRunning()
        self.captureSession = session
        Log.d("[SpeechManager] AVCaptureSession で録音開始: \(device.localizedName) (\(device.uniqueID))")
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
        captureSession = nil
        captureDelegate = nil
    }

    func stopRecording() {
        guard isRecording else { return }
        Log.d("[SpeechManager] Stopping recording...")

        stopAudioCapture()

        // End audio on the request (triggers final result)
        recognitionRequest?.endAudio()

        isRecording = false

        // If we only have partial text (no final result yet), use it
        if recognizedText.isEmpty && !partialText.isEmpty {
            recognizedText = partialText
            partialText = ""
        }
    }

    /// Wait for the final recognition result (up to timeout)
    func waitForResult(timeout: TimeInterval = 1.5) async -> String {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            // If we already have a final result, return it
            if !recognizedText.isEmpty {
                return recognizedText
            }
            // If partial text exists and task is done, use that
            if recognitionTask?.state == .completed || recognitionTask?.state == .canceling {
                if !partialText.isEmpty {
                    recognizedText = partialText
                    partialText = ""
                    return recognizedText
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Timeout: use whatever we have
        if recognizedText.isEmpty && !partialText.isEmpty {
            recognizedText = partialText
            partialText = ""
        }

        // Clean up
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        return recognizedText
    }

    enum SpeechError: LocalizedError {
        case requestCreationFailed
        case recognizerUnavailable
        case deviceUnavailable

        var errorDescription: String? {
            switch self {
            case .requestCreationFailed:
                return "音声認識リクエストの作成に失敗しました"
            case .recognizerUnavailable:
                return "音声認識が利用できません。システム設定で音声認識を許可してください。"
            case .deviceUnavailable:
                return "選択されたマイクデバイスが利用できません。"
            }
        }
    }
}

/// AVCaptureSession のオーディオデータを受け取るデリゲート
private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}
