import AVFoundation
import AudioToolbox
import CoreAudio
import Speech

@MainActor
final class SpeechManager: ObservableObject {
    static let shared = SpeechManager()

    @Published var isRecording = false
    @Published var recognizedText = ""
    @Published var partialText = ""
    @Published var errorMessage = ""

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

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

        // Reset audio engine if needed
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

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

        // 選択されたマイクデバイスを適用
        let selectedUID = Config.shared.audioInputDeviceUID
        if !selectedUID.isEmpty, let deviceID = Self.audioDeviceID(forUID: selectedUID) {
            let inputNode = audioEngine.inputNode
            let audioUnit = inputNode.audioUnit!
            var deviceID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                Log.d("[SpeechManager] デバイス切り替え失敗 (status=\(status))、システムデフォルトを使用")
            } else {
                Log.d("[SpeechManager] 入力デバイスを切り替え: \(selectedUID)")
            }
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        recognizedText = ""
        partialText = ""
        Log.d("[SpeechManager] Recording started")
    }

    func stopRecording() {
        guard isRecording else { return }
        Log.d("[SpeechManager] Stopping recording...")

        // Stop audio first
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

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

    /// UID から CoreAudio の AudioDeviceID を取得
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else {
            return nil
        }

        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &deviceUID) == noErr {
                if let uidString = deviceUID?.takeUnretainedValue() as String?, uidString == uid {
                    return device
                }
            }
        }
        return nil
    }

    enum SpeechError: LocalizedError {
        case requestCreationFailed
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .requestCreationFailed:
                return "音声認識リクエストの作成に失敗しました"
            case .recognizerUnavailable:
                return "音声認識が利用できません。システム設定で音声認識を許可してください。"
            }
        }
    }
}
