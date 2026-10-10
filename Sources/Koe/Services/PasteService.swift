import Cocoa

final class PasteService {
    static let shared = PasteService()

    private init() {}

    /// Retrieve the currently selected text from the focused application via Accessibility API.
    static func getSelectedText() -> String? {
        guard AXIsProcessTrusted() else {
            Log.d("[PasteService] Accessibility not trusted. Cannot get selected text.")
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success,
        let focusedElement,
        CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            Log.d("[PasteService] Could not get focused element")
            return nil
        }

        let focused = unsafeBitCast(focusedElement, to: AXUIElement.self)

        var selectedText: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        ) == .success,
        let selectedText,
        let text = selectedText as? String,
        !text.isEmpty else {
            Log.d("[PasteService] No selected text found")
            return nil
        }

        Log.d("[PasteService] Selected text found (\(text.count) chars)")
        return text
    }

    static func paste(text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map(copy) ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // Simulate Cmd+V after a brief delay to ensure clipboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulateCmdV()
        }

        // 前面アプリが貼り付けを読み終えてから、利用者のクリップボードを元に戻す。
        // その間に利用者や他アプリがコピーしていたら、そちらを優先して戻さない。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard pasteboard.changeCount == ourChangeCount else { return }
            pasteboard.clearContents()
            if !saved.isEmpty {
                pasteboard.writeObjects(saved)
            }
        }
    }

    private static func copy(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let copied = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) {
                copied.setData(data, forType: type)
            }
        }
        return copied
    }

    private static func simulateCmdV() {
        guard AXIsProcessTrusted() else {
            Log.d("[PasteService] Accessibility not trusted. Skip Cmd+V simulation.")
            return
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9
        let commandKey: CGKeyCode = 55

        // Emit as a full chord to improve compatibility across apps.
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true)
        cmdDown?.flags = .maskCommand
        cmdDown?.post(tap: .cgAnnotatedSessionEventTap)

        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cgAnnotatedSessionEventTap)

        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cgAnnotatedSessionEventTap)

        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false)
        cmdUp?.post(tap: .cgAnnotatedSessionEventTap)
        Log.d("[PasteService] Cmd+V posted")
    }
}

@MainActor
extension PasteService: PasteServing {
    func getSelectedText() -> String? {
        Self.getSelectedText()
    }

    func paste(text: String) {
        Self.paste(text: text)
    }

    func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
