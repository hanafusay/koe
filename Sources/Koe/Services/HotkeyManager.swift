import Cocoa
import Carbon.HIToolbox

enum TriggerKey: String, CaseIterable, Identifiable {
    case fn
    case rightOption
    case control

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "右 Option (⌥)"
        case .control: return "Control (⌃)"
        }
    }

    /// オーバーレイの狭い幅に収めるための表記。
    var shortName: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "右⌥"
        case .control: return "⌃"
        }
    }

    var flagMask: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .control: return .maskControl
        }
    }

    /// 左右の修飾キーを区別するため、デバイス依存ビット（IOLLEvent.h の NX_DEVICE*KEYMASK）で押下を判定する。
    var heldMask: UInt64 {
        switch self {
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        case .rightOption: return 0x40
        case .control: return 0x01 | 0x2000
        }
    }
}

/// OS のキーイベントを TriggerStateMachine のイベントに変換し、返ってきた Effect を実行する。
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private typealias Machine = TriggerStateMachine

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapRefcon: UnsafeMutableRawPointer?
    private var fallbackMonitor: Any?
    private var tickTimer: Timer?
    private var machine = Machine()
    private var triggerHeld = false
    private var perform: (Machine.Effect) -> Void = { _ in }
    private var pasteLastTranscript: () -> Void = {}
    private var interruptLiveTyping: () -> Void = {}

    private static let systemDefinedEventType: UInt32 = 14
    private static let mediaKeySubtype: Int16 = 8

    private init() {}

    func start(
        perform: @escaping (TriggerStateMachine.Effect) -> Void,
        pasteLastTranscript: @escaping () -> Void,
        interruptLiveTyping: @escaping () -> Void
    ) {
        stop()
        self.perform = perform
        self.pasteLastTranscript = pasteLastTranscript
        self.interruptLiveTyping = interruptLiveTyping
        Log.d("[HotkeyManager] Accessibility trusted: \(AXIsProcessTrusted())")
        setupEventTap()
    }

    private func setupEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventMask(Self.systemDefinedEventType))
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let retainedSelf = Unmanaged.passRetained(self)
        let refcon = retainedSelf.toOpaque()
        eventTapRefcon = refcon

        // esc と ⌃⌘V を前面アプリに届けないため、listenOnly ではなく能動タップにする。
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                let swallow = MainActor.assumeIsolated {
                    manager.handle(type: type, event: event)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        )

        if let tap = eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.d("[HotkeyManager] CGEvent tap OK (trigger=\(Config.shared.triggerKey.displayName))")
        } else {
            retainedSelf.release()
            eventTapRefcon = nil
            Log.d("[HotkeyManager] CGEvent tap FAILED → fallback to NSEvent monitor (esc cannot be swallowed)")
            fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let cgEvent = event.cgEvent else { return }
                MainActor.assumeIsolated {
                    _ = self?.handle(type: cgEvent.type, event: cgEvent)
                }
            }
        }
    }

    /// 戻り値が true のイベントは前面アプリに渡さない。
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // リアルタイム入力で自分が打った文字を「別のキー」とみなすと、押している最中の録音を取り消してしまう。
        if event.getIntegerValueField(.eventSourceUserData) == KeystrokeTyper.eventMarker {
            return false
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                Log.d("[HotkeyManager] CGEvent tap re-enabled")
            }
            return false
        case .flagsChanged:
            handleFlagsChanged(event.flags)
            return false
        case .keyDown:
            return handleKeyDown(event)
        case .leftMouseDown, .rightMouseDown:
            // クリックで入力位置が動いたあとに打ち直すと、別の場所の文字を消してしまう。前面アプリに届く前に止める。
            interruptLiveTyping()
            return false
        default:
            if type.rawValue == Self.systemDefinedEventType,
               NSEvent(cgEvent: event)?.subtype.rawValue == Self.mediaKeySubtype {
                send(.otherKeyDown)
            }
            return false
        }
    }

    private func handleFlagsChanged(_ flags: CGEventFlags) {
        let held = flags.rawValue & Config.shared.triggerKey.heldMask != 0
        if held != triggerHeld {
            triggerHeld = held
            send(held ? .triggerDown : .triggerUp)
        } else {
            send(.otherKeyDown)
        }
    }

    private static let functionKeyCodes: Set<Int> = [kVK_Function, 179]

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == kVK_Escape {
            return send(.escape).contains(.cancel)
        }

        // fn（🌐）キーは押すたびに keyDown も出すため、録音キーの操作を利用者の入力と取り違えないよう読み捨てる。
        guard !Self.functionKeyCodes.contains(keyCode) else { return false }

        interruptLiveTyping()
        send(.otherKeyDown)

        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard keyCode == kVK_ANSI_V, modifiers == [.maskCommand, .maskControl] else { return false }
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { [pasteLastTranscript] in pasteLastTranscript() }
        }
        return true
    }

    @discardableResult
    private func send(_ event: Machine.Event) -> [Machine.Effect] {
        let effects = machine.handle(event, at: ProcessInfo.processInfo.systemUptime)
        if !effects.isEmpty {
            Log.d("[HotkeyManager] \(event) → \(effects) state=\(machine.state)")
            // タップのコールバックは早く返さないと OS に無効化されるため、録音開始などの重い処理は後で実行する。
            DispatchQueue.main.async { [perform] in effects.forEach(perform) }
        }
        updateTickTimer()
        return effects
    }

    private func updateTickTimer() {
        if machine.state == .idle {
            tickTimer?.invalidate()
            tickTimer = nil
            return
        }
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        // flagsChanged を取りこぼしてもキーを離したことを検知できるよう、現在の修飾キー状態と照合する。
        if triggerHeld,
           !CGEventSource.flagsState(.combinedSessionState).contains(Config.shared.triggerKey.flagMask) {
            triggerHeld = false
            send(.triggerUp)
        }
        send(.tick)
    }

    func resetState() {
        if machine.state != .idle {
            perform(.cancel)
        }
        machine = Machine()
        triggerHeld = false
        tickTimer?.invalidate()
        tickTimer = nil
        Log.d("[HotkeyManager] State reset (triggerKey=\(Config.shared.triggerKey.rawValue))")
    }

    /// 声を認識したことを伝える。ハンズフリーの無音タイムアウトを延ばす。
    func noteSpeech() {
        guard machine.state != .idle else { return }
        send(.speech)
    }

    func stop() {
        resetState()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil
        }
        if let refcon = eventTapRefcon {
            Unmanaged<HotkeyManager>.fromOpaque(refcon).release()
            eventTapRefcon = nil
        }
        if let monitor = fallbackMonitor {
            NSEvent.removeMonitor(monitor)
            fallbackMonitor = nil
        }
    }
}
