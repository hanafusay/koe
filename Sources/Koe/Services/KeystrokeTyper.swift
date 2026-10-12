import Cocoa
import Carbon.HIToolbox

/// 認識中の文字をキー入力として前面アプリへ打ち込む。
///
/// 日本語入力（ことえり、Google 日本語入力など）がオンのままだと、合成したキーを入力メソッドが
/// キーコードから解釈し直して未確定文字に変えるおそれがある。そのため打ち込む間だけ英字配列へ切り替え、
/// 終わったら元の入力ソースに戻す。
@MainActor
final class KeystrokeTyper: LiveTyping {
    static let shared = KeystrokeTyper()

    /// 自分が合成したキーを録音キーの判定から外すための印（eventSourceUserData に入れる）。
    static let eventMarker: Int64 = 0x6B6F_6521

    /// CGEvent に載せる文字列は長いと切り捨てられる環境があるため、この UTF-16 長で区切る。
    private static let maxUnitsPerEvent = 16
    /// 入力ソースの切り替えが前面アプリに届く前にキーが処理されないよう、戻すのも打ち終えてから少し待つ。
    private static let restoreDelay: Duration = .milliseconds(500)

    /// 押しっぱなしの録音キーがキーに混ざらないよう、修飾キーの状態を持たない発生源を使う。
    private let source = CGEventSource(stateID: .privateState)
    private var savedInputSource: TISInputSource?
    private var restoreTask: Task<Void, Never>?
    private var targetProcess: pid_t?
    private var targetElement: AXUIElement?

    private init() {}

    func begin() {
        targetProcess = NSWorkspace.shared.frontmostApplication?.processIdentifier
        targetElement = PasteService.focusedElement()
        restoreTask?.cancel()
        restoreTask = nil
        guard savedInputSource == nil else { return }

        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard Self.isInputMethod(current),
              let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
        savedInputSource = current
        TISSelectInputSource(ascii)
        Log.d("[KeystrokeTyper] Switched input source to an ASCII layout while typing")
    }

    var canType: Bool {
        LiveTextReconciler.canType(flags: CGEventSource.flagsState(.combinedSessionState))
    }

    func apply(_ ops: [LiveTextOp]) -> Bool {
        guard !ops.isEmpty else { return true }
        // 途中で別のアプリへ移ったら、そのアプリの文字を消さないよう打つのをやめる。
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcess else {
            Log.d("[KeystrokeTyper] Frontmost app changed; stop typing")
            return false
        }
        // 同じアプリの別の入力欄へ移った場合も、そこの文字を消さないよう打つのをやめる。
        // AXUIElement の == は CFEqual で比べる。
        guard PasteService.focusedElement() == targetElement else {
            Log.d("[KeystrokeTyper] Focused element changed; stop typing")
            return false
        }
        Log.d("[KeystrokeTyper] apply \(ops.map(Self.describe).joined(separator: " "))")
        for op in ops {
            switch op {
            case .backspace(let count):
                for _ in 0..<count { post(keyCode: CGKeyCode(kVK_Delete), text: nil) }
            case .type(let text):
                for chunk in Self.chunks(of: text) { post(keyCode: 0, text: chunk) }
            }
        }
        return true
    }

    func end() {
        targetProcess = nil
        targetElement = nil
        guard savedInputSource != nil else { return }
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: Self.restoreDelay)
            guard !Task.isCancelled else { return }
            self?.restoreInputSource()
        }
    }

    func restoreInputSource() {
        restoreTask?.cancel()
        restoreTask = nil
        guard let saved = savedInputSource else { return }
        savedInputSource = nil
        TISSelectInputSource(saved)
        Log.d("[KeystrokeTyper] Restored input source")
    }

    private func post(keyCode: CGKeyCode, text: [UniChar]?) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = []
            if let text {
                event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
            }
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// 書記素（絵文字や濁点付きの文字）を途中で割らずに区切る。
    private static func describe(_ op: LiveTextOp) -> String {
        switch op {
        case .backspace(let count): return "bs\(count)"
        case .type(let text): return "+\(text.count)"
        }
    }

    private static func chunks(of text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(character.utf16)
            if !current.isEmpty, current.count + units.count > maxUnitsPerEvent {
                chunks.append(current)
                current = []
            }
            current += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func isInputMethod(_ source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue()
        return type != kTISTypeKeyboardLayout
    }
}
