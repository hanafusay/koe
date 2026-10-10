import Foundation

/// 録音キーの押し方を録音操作に変換する。時刻は呼び出し側が渡すため、OS に依存せず検査できる。
struct TriggerStateMachine {
    enum State: Equatable {
        case idle
        /// キーを押している。録音は始まっているが、短押しかもしれないのでオーバーレイは保留する。
        case pressed(at: TimeInterval, overlayShown: Bool)
        /// 短押しで離した。2 回目が来ればハンズフリー、来なければ取り消す。録音は裏で続いている。
        case awaitingSecondTap(releasedAt: TimeInterval)
        /// 最後に声を認識した時刻。押しっぱなしと違い、閉じ忘れても録音が続かないよう無音が続いたら確定する。
        case handsFree(lastSpeechAt: TimeInterval)
    }

    enum Event: Equatable {
        case triggerDown
        case triggerUp
        case otherKeyDown
        case escape
        case tick
        case speech
    }

    enum Effect: Equatable {
        case startRecording
        case showOverlay
        case commit
        case cancel
        case lockHandsFree
    }

    /// これより短い押下は入力ソース切り替えなどの fn タップとみなし、オーバーレイを出さない。
    static let holdThreshold: TimeInterval = 0.25
    static let doubleTapWindow: TimeInterval = 0.35
    static let handsFreeIdleTimeout: TimeInterval = 30

    private(set) var state: State = .idle

    mutating func handle(_ event: Event, at time: TimeInterval) -> [Effect] {
        switch (state, event) {
        case (.idle, .triggerDown):
            state = .pressed(at: time, overlayShown: false)
            return [.startRecording]

        case let (.pressed(downAt, overlayShown), .tick):
            guard !overlayShown, time - downAt >= Self.holdThreshold else { return [] }
            state = .pressed(at: downAt, overlayShown: true)
            return [.showOverlay]

        case let (.pressed(downAt, _), .triggerUp):
            if time - downAt >= Self.holdThreshold {
                state = .idle
                return [.commit]
            }
            state = .awaitingSecondTap(releasedAt: time)
            return []

        case (.pressed, .otherKeyDown),
             (.pressed, .escape),
             (.awaitingSecondTap, .escape),
             (.handsFree, .escape):
            state = .idle
            return [.cancel]

        case let (.awaitingSecondTap(releasedAt), .tick):
            guard time - releasedAt >= Self.doubleTapWindow else { return [] }
            state = .idle
            return [.cancel]

        case let (.awaitingSecondTap(releasedAt), .triggerDown):
            // tick が遅れて窓を過ぎた押下が届いた場合は、前の短押しを捨てて新しい押下として扱う。
            if time - releasedAt >= Self.doubleTapWindow {
                state = .pressed(at: time, overlayShown: false)
                return [.cancel, .startRecording]
            }
            state = .handsFree(lastSpeechAt: time)
            return [.lockHandsFree]

        // 確定した押下の離す操作は idle で読み捨てられる。
        case (.handsFree, .speech):
            state = .handsFree(lastSpeechAt: time)
            return []

        case let (.handsFree(lastSpeechAt), .tick):
            guard time - lastSpeechAt >= Self.handsFreeIdleTimeout else { return [] }
            state = .idle
            return [.commit]

        case (.handsFree, .triggerDown):
            state = .idle
            return [.commit]

        default:
            return []
        }
    }
}
