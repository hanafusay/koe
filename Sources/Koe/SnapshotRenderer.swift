import SwiftUI

/// `--render-snapshots <dir>` で起動すると、オーバーレイ・設定・メニューを PNG に書き出して終了する。
/// 録音もキー監視も始めずに見た目を確認するための仕組み。
@MainActor
enum SnapshotRenderer {
    nonisolated static var requestedDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-snapshots"), index + 1 < arguments.count else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    private struct OverlayCase {
        let name: String
        let status: OverlayStatus
        var transcript = ""
        var levels: [Float] = [0.35, 0.6, 0.8, 0.95]
        var reduceMotion = false
    }

    private static let overlayCases: [OverlayCase] = [
        OverlayCase(name: "typing", status: .typing(isHandsFree: false)),
        OverlayCase(name: "typing-handsfree", status: .typing(isHandsFree: true)),
        OverlayCase(name: "typing-quiet", status: .typing(isHandsFree: false), levels: [0, 0, 0.05, 0.1]),
        OverlayCase(name: "correction", status: .correction(isHandsFree: false), transcript: "丁寧語にして"),
        OverlayCase(name: "correction-empty", status: .correction(isHandsFree: false)),
        OverlayCase(name: "correction-handsfree", status: .correction(isHandsFree: true),
                    transcript: "箇条書きにまとめて"),
        OverlayCase(name: "correcting", status: .correcting),
        OverlayCase(name: "done", status: .done),
        OverlayCase(name: "copied", status: .copied),
        OverlayCase(name: "notice-unavailable", status: .notice("Apple Intelligence が無効のため修正できません")),
        OverlayCase(name: "notice-no-speech", status: .notice("声を聞き取れませんでした。もう少し長く話してください")),
        OverlayCase(name: "notice-interrupted", status: .notice("入力先が変わったため途中で止めました。⌃⌘V で全文を入力できます")),
        OverlayCase(name: "notice-correction-target-changed",
                    status: .notice("入力先が変わったため貼り付けませんでした。⌃⌘V で入力できます")),
        OverlayCase(name: "notice-secure-input", status: .notice("パスワード入力中のため音声入力を止めています")),
        OverlayCase(name: "typing-reduce-motion", status: .typing(isHandsFree: false), reduceMotion: true),
    ]

    static func renderAll(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for item in overlayCases {
            let state = OverlayState()
            state.status = item.status
            state.transcript = item.transcript
            item.levels.forEach(state.push(level:))
            // ピルは常に暗いので、明るい壁紙と暗い壁紙の上で読めるかを確かめる。
            for (suffix, backdrop) in [("light", Color(white: 0.92)), ("dark", Color(white: 0.18))] {
                let view = OverlayView(state: state, reduceMotion: item.reduceMotion)
                    .padding(28)
                    .background(backdrop)
                writeRendered(view, to: directory.appendingPathComponent("overlay-\(item.name)-\(suffix).png"))
            }
        }

        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            writeHosted(SettingsView(), appearance: appearance,
                        to: directory.appendingPathComponent("settings-\(suffix).png"))
            let menu = VStack(alignment: .leading, spacing: 6) {
                MenuContent(
                    config: .shared,
                    coordinator: .shared,
                    openSettings: {}
                )
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            writeHosted(menu, appearance: appearance, to: directory.appendingPathComponent("menu-\(suffix).png"))
        }
        print("Rendered snapshots to \(directory.path)")
    }

    private static func writeRendered(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("Failed to render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }

    /// フォームやボタンは AppKit で描かれ ImageRenderer では写らないため、ウィンドウに載せて描画する。
    private static func writeHosted(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("Failed to render \(url.lastPathComponent)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
