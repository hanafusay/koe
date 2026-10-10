import AppKit
import Combine

@MainActor
final class DictationCoordinator: ObservableObject {
    static let shared = DictationCoordinator()

    @Published private(set) var statusText: String = "待機中"
    @Published private(set) var isProcessing: Bool = false

    private let speechManager: SpeechManager
    private let pasteService: PasteServing
    private let typer: LiveTyping
    private let overlay: OverlayPanel

    private var selectedTextForCorrection: String?
    private var completionTask: Task<Void, Never>?
    private var overlayDismissTask: Task<Void, Never>?
    private var speechSubscriptions: Set<AnyCancellable> = []

    /// 録音中だけ存在する。
    private struct LiveSession {
        var reconciler = LiveTextReconciler()
        /// 打ち込みを始めてよい時刻。録音キーの押下が確定するまでは nil で、短い fn タップでは何も打たない。
        var typingFrom: TimeInterval?
        /// 途中で前面アプリが変わり、打ち込みをやめた。
        var interrupted = false
    }

    private var live: LiveSession?
    private var liveTimer: Timer?
    /// 認識結果が変わるたびに呼ばれる。ハンズフリーの無音タイムアウトを延ばすのに使う。
    var onSpeech: () -> Void = {}
    /// 入力ソースを英字に切り替えてから、前面アプリに切り替えが届くまで待つ時間。
    private static let inputSourceSettle: TimeInterval = 0.1

    /// 完了のチェックは打ち込んだ文そのものが成功の合図なので短く、注意は読めるだけ残す。
    private static let doneLinger = 0.45
    private static let noticeLinger = 2.5
    private static let copiedLinger = 1.0

    private convenience init() {
        self.init(
            speechManager: .shared,
            pasteService: PasteService.shared,
            typer: KeystrokeTyper.shared,
            overlay: OverlayPanel()
        )
    }

    init(
        speechManager: SpeechManager,
        pasteService: PasteServing,
        typer: LiveTyping,
        overlay: OverlayPanel
    ) {
        self.speechManager = speechManager
        self.pasteService = pasteService
        self.typer = typer
        self.overlay = overlay

        let state = overlay.overlayState
        speechManager.$transcript
            .sink { [weak self] transcript in
                state.transcript = transcript.text
                self?.liveTranscriptChanged(transcript)
                self?.onSpeech()
            }
            .store(in: &speechSubscriptions)
        speechManager.$level
            .sink { state.push(level: $0) }
            .store(in: &speechSubscriptions)
    }

    /// 録音だけを始め、オーバーレイは出さない。短い fn タップ（入力ソース切り替え）で画面がちらつかないようにするため。
    func startRecording() {
        Log.d("[DictationCoordinator] startRecording called (isProcessing=\(isProcessing), isRecording=\(speechManager.isRecording))")
        guard !isProcessing, !speechManager.isRecording else { return }
        overlayDismissTask?.cancel()
        overlayDismissTask = nil
        overlay.orderOut(nil)

        let selected = pasteService.getSelectedText()
        selectedTextForCorrection = selected
        Log.d("[DictationCoordinator] Selected text for correction: \(selected.map { "\($0.count) chars" } ?? "none")")

        do {
            try speechManager.startRecording(language: Config.recognitionLanguage, dictionary: Config.shared.dictionary)
            Log.d("[DictationCoordinator] Recording started")
            // 選択範囲の修正は、話し終えた指示で書き換えるため打ち込まずにまとめて処理する。
            if selected == nil {
                live = LiveSession()
                overlay.update(.typing(isHandsFree: false))
                statusText = "録音中..."
            } else {
                overlay.update(.correction(isHandsFree: false))
                statusText = "修正の指示を録音中..."
            }
        } catch {
            Log.d("[DictationCoordinator] startRecording error: \(error.localizedDescription)")
            statusText = "エラー: \(error.localizedDescription)"
            overlay.update(.notice(error.localizedDescription))
            overlay.show()
            selectedTextForCorrection = nil
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
        }
    }

    /// 0.25 秒以上押し続けた（短い fn タップではない）と確定した時点。
    func showRecordingOverlay() {
        guard speechManager.isRecording else { return }
        overlay.show()
        beginLiveTyping()
    }

    func lockHandsFree() {
        guard speechManager.isRecording else { return }
        statusText = "ハンズフリー録音中..."
        overlay.update(live != nil ? .typing(isHandsFree: true) : .correction(isHandsFree: true))
        overlay.show()
        beginLiveTyping()
    }

    func stopRecording() {
        Log.d("[DictationCoordinator] stopRecording called (isRecording=\(speechManager.isRecording))")
        guard speechManager.isRecording else { return }

        speechManager.stopRecording()
        play(.commit)
        isProcessing = true
        if live != nil {
            stopLiveTimer()
            completionTask = Task { await completeLiveTyping() }
        } else if let selected = selectedTextForCorrection {
            selectedTextForCorrection = nil
            overlay.update(.correcting)
            overlay.show()
            completionTask = Task { await completeCorrection(of: selected) }
        }
    }

    /// 録音を捨てる。打ち込んだ文字も消す。
    func cancelRecording() {
        guard speechManager.isRecording else { return }
        Log.d("[DictationCoordinator] cancelRecording")
        // 短い fn タップ（入力ソースの切り替え）の取り消しは利用者の操作ではないので鳴らさない。
        if overlay.isVisible { play(.cancel) }
        speechManager.cancelRecording()
        if var session = live {
            stopLiveTimer()
            if session.typingFrom != nil, !session.interrupted {
                _ = typer.apply(session.reconciler.cancel())
            }
            typer.end()
            live = nil
        }
        selectedTextForCorrection = nil
        statusText = "待機中"
        overlay.dismiss()
    }

    func pasteLastTranscript() {
        guard let lastTranscript = Config.shared.history.first, !speechManager.isRecording, !isProcessing else { return }
        Log.d("[DictationCoordinator] pasteLastTranscript (\(lastTranscript.count) chars)")
        pasteService.paste(text: lastTranscript)
    }

    func copyFromHistory(_ text: String) {
        pasteService.copy(text: text)
        // 録音中や処理中はオーバーレイがその状態を表しているので、上書きしない。
        guard !speechManager.isRecording, !isProcessing else { return }
        overlay.update(.copied)
        overlay.show()
        dismissOverlayAfterDelay(seconds: Self.copiedLinger)
    }

    private func beginLiveTyping() {
        guard live != nil, live?.typingFrom == nil else { return }
        startTyping()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushLive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func startTyping() {
        typer.begin()
        live?.typingFrom = Self.now + Self.inputSourceSettle
    }

    private func stopLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func liveTranscriptChanged(_ transcript: Transcript) {
        guard live != nil else { return }
        live?.reconciler.observe(transcript, at: Self.now)
        flushLive()
    }

    /// 安定した分だけを打ち込む。時間が経つだけで安定する文字もあるため、タイマーからも呼ぶ。
    private func flushLive() {
        let now = Self.now
        guard let session = live, !session.interrupted, let typingFrom = session.typingFrom, now >= typingFrom,
              let ops = live?.reconciler.sync(at: now) else { return }
        if !typer.apply(ops) {
            live?.interrupted = true
            stopLiveTimer()
        }
    }

    private func completeLiveTyping() async {
        defer { isProcessing = false }
        if live?.typingFrom == nil {
            startTyping()
            try? await Task.sleep(for: .seconds(Self.inputSourceSettle))
        }
        let final = await speechManager.finalTranscript()
        guard var session = live else { return }
        live = nil
        session.reconciler.observe(final, at: Self.now)
        let ops = session.reconciler.finish()
        let typedAll = !session.interrupted && typer.apply(ops)
        typer.end()
        Log.d("[DictationCoordinator] Live typing finished (final=\(final.text.count) chars, typedAll=\(typedAll))")

        guard !final.text.isEmpty else {
            showNoSpeechNotice()
            return
        }
        Config.shared.remember(final.text)
        if typedAll {
            statusText = "完了"
            overlay.update(.done)
            dismissOverlayAfterDelay(seconds: Self.doneLinger)
        } else {
            statusText = "完了（途中で中断）"
            overlay.update(.notice("入力先が変わったため途中で止めました。⌃⌘V で全文を入力できます"))
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func completeCorrection(of selectedText: String) async {
        defer { isProcessing = false }
        let instruction = await speechManager.finalTranscript().text
        guard !instruction.isEmpty else {
            showNoSpeechNotice()
            return
        }
        Log.d("[DictationCoordinator] Correcting \(selectedText.count) chars")
        let corrector = OnDeviceLanguageModelService()
        if let reason = corrector.unavailableReason {
            statusText = "修正できません"
            overlay.update(.notice("\(reason.message)のため修正できません"))
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
            return
        }
        statusText = "修正中..."
        do {
            let corrected = try await corrector.correct(selectedText: selectedText, instruction: instruction)
            pasteService.paste(text: corrected)
            Config.shared.remember(corrected)
            statusText = "完了"
            overlay.update(.done)
            dismissOverlayAfterDelay(seconds: Self.doneLinger)
        } catch where error is CancellationError {
            overlay.dismiss()
        } catch {
            statusText = "修正エラー"
            overlay.update(.notice("修正できませんでした（\(error.localizedDescription)）"))
            dismissOverlayAfterDelay(seconds: Self.noticeLinger)
        }
    }

    private func showNoSpeechNotice() {
        statusText = "テキストが認識されませんでした"
        if let error = speechManager.lastError {
            overlay.update(.notice("音声認識を始められませんでした（\(error.localizedDescription)）"))
        } else {
            overlay.update(.notice("声を聞き取れませんでした。もう少し長く話してください"))
        }
        dismissOverlayAfterDelay(seconds: Self.noticeLinger)
    }

    private enum Sound: String {
        case commit = "Pop"
        case cancel = "Bottle"
    }

    private func play(_ sound: Sound) {
        guard Config.shared.soundEffects, let player = NSSound(named: sound.rawValue) else { return }
        player.volume = 0.3
        player.play()
    }

    private func dismissOverlayAfterDelay(seconds: Double) {
        overlayDismissTask?.cancel()
        overlayDismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled {
                self.overlay.dismiss()
            }
        }
    }
}
