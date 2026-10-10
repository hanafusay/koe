import AVFoundation
import Speech

/// マイク（またはファイル）の音を SpeechAnalyzer に流し、認識の途中経過を `transcript` として公開する。
@MainActor
final class SpeechManager: ObservableObject {
    static let shared = SpeechManager()

    @Published private(set) var isRecording = false
    @Published private(set) var transcript = Transcript()
    /// 録音中のマイク音量（0〜1）。オーバーレイの棒グラフ用。
    @Published private(set) var level: Float = 0
    /// 直近の録音で認識を始められなかった理由。
    private(set) var lastError: Error?

    private let levelMeter = LevelMeter()

    private var audioEngine = AVAudioEngine()
    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioCaptureDelegate?
    private var fileFeeder: Task<Void, Never>?
    private var audioInput: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    /// 前の録音の結果が遅れて届いても、今の録音に混ぜないための番号。
    private var session = 0
    private var dictionary: [DictionaryEntry] = []

    private init() {
        levelMeter.onLevel = { [weak self] level in
            guard let self, self.isRecording else { return }
            self.level = level
        }
    }

    /// 録音はすぐに始め、認識の準備（モデルの確認と読み込み）を待つ間の音は貯めておく。押した瞬間の話し始めを欠かさないため。
    /// `file` を渡すとマイクの代わりにそのファイルを実時間の速さで流す（動作確認用）。
    func startRecording(language: String, dictionary: [DictionaryEntry], file: URL? = nil) throws {
        cancelRecording()
        self.dictionary = dictionary

        let (audio, input) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        session += 1
        let current = session
        lastError = nil

        do {
            if let file {
                try startFeeding(file: file, into: input)
            } else {
                try startCapture(into: input)
            }
        } catch {
            input.finish()
            throw error
        }

        audioInput = input
        analysisTask = Task { [weak self] in
            await self?.analyze(audio, locale: Locale(identifier: language), session: current)
        }
        isRecording = true
        Log.d("[SpeechManager] Recording started (session=\(current))")
    }

    /// 音の入力を止める。最終結果は `finalTranscript()` で待つ。
    func stopRecording() {
        guard isRecording else { return }
        Log.d("[SpeechManager] Stopping recording")
        stopAudioCapture()
        audioInput?.finish()
        audioInput = nil
        isRecording = false
    }

    /// 入力し終えた音の認識が確定するのを待つ。認識が止まった場合に備えて上限を設ける。
    func finalTranscript(timeout: Duration = .seconds(3)) async -> Transcript {
        guard let task = analysisTask else { return transcript }
        analysisTask = nil
        // 確定処理が cancelAndFinishNow 後も戻らないことがあり、待ち続けると次の録音を受け付けなくなる。
        // 期限が来たらそこまでの認識結果で打ち切り、遅れて届く結果は session を進めて捨てる。
        let finished = await Self.first(of: { await task.value }, orAfter: timeout)
        guard !finished else { return transcript }
        Log.d("[SpeechManager] Finalizing timed out; using the transcript so far")
        let result = transcript
        session += 1
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        return result
    }

    /// work が timeout 内に終われば true。終わらなくても work の完了は待たない。
    private static func first(of work: @escaping @MainActor () async -> Void, orAfter timeout: Duration) async -> Bool {
        final class Once {
            var continuation: CheckedContinuation<Bool, Never>?
            func resume(_ value: Bool) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { @MainActor in
                await work()
                once.resume(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(false)
            }
        }
    }

    func cancelRecording() {
        stopAudioCapture()
        audioInput?.finish()
        audioInput = nil
        session += 1
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        analysisTask = nil
        if isRecording { Log.d("[SpeechManager] Recording cancelled") }
        isRecording = false
        transcript = Transcript()
    }

    private func analyze(_ audio: AsyncStream<AVAudioPCMBuffer>, locale: Locale, session current: Int) async {
        do {
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw SpeechError.unsupportedLanguage
            }
            let transcriber = SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            // 端末に入っていない言語は、初回だけここでモデルを取得する（入っていれば即座に終わる）。
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw SpeechError.unsupportedLanguage
            }
            guard current == session else { return }

            let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            if !dictionary.words.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = dictionary.words
                try await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: inputs)

            let results = Task { [weak self] in
                for try await result in transcriber.results {
                    self?.receive(String(result.text.characters), isFinal: result.isFinal, session: current)
                }
            }

            let converter = BufferConverter(to: format)
            for await buffer in audio {
                if let converted = converter.convert(buffer) {
                    inputContinuation.yield(AnalyzerInput(buffer: converted))
                }
            }
            inputContinuation.finish()
            guard current == session else { return }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results.value
        } catch {
            guard current == session else { return }
            Log.d("[SpeechManager] Analysis error: \(error)")
            lastError = error
        }
        if current == session {
            analyzer = nil
        }
    }

    private func receive(_ text: String, isFinal: Bool, session current: Int) {
        guard current == session else { return }
        let text = dictionary.corrected(text)
        if isFinal {
            transcript = Transcript(finalized: transcript.finalized + text)
        } else {
            transcript.volatile = text
        }
    }

    // MARK: - 音の取り込み

    /// デバイス指定がある場合は AVCaptureSession、なければ AVAudioEngine。
    private func startCapture(into input: AsyncStream<AVAudioPCMBuffer>.Continuation) throws {
        let selectedUID = Config.shared.audioInputDeviceUID
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
        if !selectedUID.isEmpty, let device = discovery.devices.first(where: { $0.uniqueID == selectedUID }) {
            try startCaptureSession(device: device, into: input)
        } else {
            if !selectedUID.isEmpty {
                Log.d("[SpeechManager] デバイスが見つかりません: \(selectedUID)、システムデフォルトを使用")
            }
            try startAudioEngine(into: input)
        }
    }

    private func startAudioEngine(into input: AsyncStream<AVAudioPCMBuffer>.Continuation) throws {
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        Log.d("[SpeechManager] AVAudioEngine フォーマット: ch=\(format.channelCount), rate=\(format.sampleRate)")

        let meter = levelMeter
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            input.yield(buffer)
            meter.feed(decibels: LevelMeter.decibels(of: buffer))
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startCaptureSession(device: AVCaptureDevice, into input: AsyncStream<AVAudioPCMBuffer>.Continuation) throws {
        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else { throw SpeechError.deviceUnavailable }
        session.addInput(deviceInput)

        let output = AVCaptureAudioDataOutput()
        let meter = levelMeter
        let delegate = AudioCaptureDelegate { sampleBuffer, connection in
            if let buffer = AVAudioPCMBuffer.copying(sampleBuffer) {
                input.yield(buffer)
            }
            if let decibels = connection.audioChannels.first?.averagePowerLevel {
                meter.feed(decibels: decibels)
            }
        }
        captureDelegate = delegate
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "com.koe.audiocapture"))
        guard session.canAddOutput(output) else { throw SpeechError.deviceUnavailable }
        session.addOutput(output)

        session.startRunning()
        captureSession = session
        Log.d("[SpeechManager] AVCaptureSession で録音開始: \(device.localizedName) (\(device.uniqueID))")
    }

    private func startFeeding(file url: URL, into input: AsyncStream<AVAudioPCMBuffer>.Continuation) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        fileFeeder = Task.detached {
            while !Task.isCancelled,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
                  (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
                input.yield(buffer)
                try? await Task.sleep(for: .seconds(Double(buffer.frameLength) / format.sampleRate))
            }
            input.finish()
        }
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        if let captureSession, captureSession.isRunning {
            captureSession.stopRunning()
        }
        captureSession = nil
        captureDelegate = nil
        fileFeeder?.cancel()
        fileFeeder = nil
        level = 0
    }

    enum SpeechError: LocalizedError {
        case unsupportedLanguage
        case deviceUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage:
                return "この言語は Mac 内の音声認識に対応していません"
            case .deviceUnavailable:
                return "選択されたマイクデバイスが利用できません"
            }
        }
    }
}

/// 取り込んだ音を SpeechAnalyzer が受け付ける形式へ変換する。入力形式が変わったら作り直す。
private final class BufferConverter {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) {
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format != format else { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            // 既定の priming はバッファの先頭を捨てるため、細切れに変換すると継ぎ目ごとに音が欠ける。
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.d("[SpeechManager] Audio conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        return output
    }
}

private extension AVAudioPCMBuffer {
    static func copying(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

/// AVCaptureSession のオーディオデータを受け取るデリゲート
private final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let handler: (CMSampleBuffer, AVCaptureConnection) -> Void

    init(handler: @escaping (CMSampleBuffer, AVCaptureConnection) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer, connection)
    }
}

/// 音声スレッドで受け取った音量を、メインスレッドへ約 25Hz に間引いて渡す。
private final class LevelMeter: @unchecked Sendable {
    var onLevel: @MainActor (Float) -> Void = { _ in }
    private var lastSent: TimeInterval = 0

    func feed(decibels: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSent >= 0.04 else { return }
        lastSent = now
        // 話し声はおおむね -50〜-10 dBFS に収まるため、その範囲を 0〜1 に広げる。
        let level = min(max((decibels + 50) / 40, 0), 1)
        DispatchQueue.main.async { [onLevel] in
            MainActor.assumeIsolated { onLevel(level) }
        }
    }

    static func decibels(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        return 20 * log10(max((sum / Float(count)).squareRoot(), 1e-8))
    }
}
