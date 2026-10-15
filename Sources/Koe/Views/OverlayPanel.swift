import Cocoa
import SwiftUI

/// 画面下中央（Dock の上）に出る、録音状態を示すピル。
final class OverlayPanel: NSPanel {
    let overlayState = OverlayState()
    private var presentation = 0

    /// ピルの最大幅と影の余白を含む大きさ。ピルはこの中の下中央に置く。
    private static let size = NSSize(width: 520, height: 120)
    private static let shadowInset: CGFloat = 16
    private static let gapAboveDock: CGFloat = 24

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = NSHostingView(rootView: OverlayPlacement(state: overlayState, bottomInset: Self.shadowInset))
    }

    /// キー操作のたびに出るため、現れるときは動かさない。
    func show() {
        presentation += 1
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + Self.gapAboveDock - Self.shadowInset
        ))
        // 消えかけの途中で呼ばれたら、フェードを打ち切って不透明に戻す。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = 1
        }
        orderFrontRegardless()
    }

    func update(_ status: OverlayStatus) {
        overlayState.status = status
    }

    func dismiss() {
        guard isVisible else { return }
        let dismissed = presentation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.presentation == dismissed else { return }
            self.orderOut(nil)
        })
    }
}

enum OverlayStatus: Equatable {
    /// リアルタイム入力中。文字は入力欄に出ているので、ここには書き起こしを出さない。
    case typing(isHandsFree: Bool)
    case done
    /// 履歴から選んだ文をクリップボードに入れた。
    case copied
    case notice(String)
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var status: OverlayStatus = .typing(isHandsFree: false)
    /// 直近の音量（0〜1）。末尾が最新。
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 4)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

private struct OverlayPlacement: View {
    let state: OverlayState
    let bottomInset: CGFloat

    var body: some View {
        OverlayView(state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, bottomInset)
    }
}

struct OverlayView: View {
    @ObservedObject var state: OverlayState
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private static let warning = Color(red: 1.0, green: 0.8, blue: 0.3)

    var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minWidth: 120, minHeight: 36)
            .frame(maxWidth: maxWidth)
            .fixedSize()
            .background(shape.fill(Color(white: 0.09).opacity(0.92)))
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
            // 状態が変わったとき幅が瞬間移動すると壊れて見えるため、形ごと縮める。
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0), value: state.status)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    @ViewBuilder
    private var content: some View {
        switch state.status {
        case .typing(let isHandsFree):
            HStack(spacing: 8) {
                if isHandsFree {
                    lockIcon
                }
                LevelBars(levels: state.levels, color: .white, reduceMotion: reduceMotion)
                Text("リアルタイム入力中")
                    .fixedSize()
                if isHandsFree {
                    handsFreeHint
                }
            }
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
        case .copied:
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                Text("コピーしました")
            }
        case .notice(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Self.warning)
                Text(message)
                    .lineLimit(2)
            }
        }
    }

    private var lockIcon: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.65))
    }

    private var handsFreeHint: some View {
        Text("\(Config.shared.triggerKey.shortName) で確定・esc で取消")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize()
    }

    private var maxWidth: CGFloat {
        if case .notice = state.status { return 480 }
        return 440
    }

    private var borderColor: Color {
        switch state.status {
        case .notice: return Self.warning.opacity(0.4)
        default: return .white.opacity(0.12)
        }
    }
}

/// 中央が最新の音量で、外側ほど少し前の音量を映す。声が中央から広がって見える。
private struct LevelBars: View {
    let levels: [Float]
    let color: Color
    let reduceMotion: Bool

    private static let envelope: [CGFloat] = [0.5, 0.7, 0.9, 1, 0.9, 0.7, 0.5]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Self.envelope.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: height(at: index))
            }
        }
        .frame(height: 18)
        // 動きを減らす設定では棒を止め、音量は明るさだけで伝える。
        .opacity(reduceMotion ? 0.45 + 0.55 * Double(levels.last ?? 0) : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: levels)
    }

    private func height(at index: Int) -> CGFloat {
        let envelope = Self.envelope[index]
        guard !reduceMotion else { return 4 + 8 * envelope }
        let age = abs(index - Self.envelope.count / 2)
        let level = CGFloat(levels[levels.count - 1 - age])
        return 4 + 14 * level * envelope
    }
}
