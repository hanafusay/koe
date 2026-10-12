import CoreGraphics
import Foundation

/// 音声認識の途中経過。確定した区間の文と、まだ書き換わりうる末尾の文に分かれる。
struct Transcript: Equatable {
    var finalized = ""
    var volatile = ""

    var text: String { finalized + volatile }
}

enum LiveTextOp: Equatable {
    /// 文字（書記素）単位で後ろから消す。
    case backspace(Int)
    case type(String)
}

/// 前面アプリへ打ち込んだ文字を、認識結果に合わせる最小の削除と入力に変換する。時刻は呼び出し側が渡す。
struct LiveTextReconciler {
    /// 認識途中の文字は、この時間変わらなかった部分だけを打つ。
    /// 測定では途中結果がおよそ 0.1 秒ごとに 1 文字ずつ伸びるため、3 回分の更新を見てから打つことになり、
    /// 打っては消すちらつきを抑えつつ、話してから文字が出るまでの遅れを 0.3 秒ほどに収められる。
    static let stabilityWindow: TimeInterval = 0.3

    /// このセッションで打ち込んだ文字。削除はこの範囲を超えない。
    private(set) var typed = ""
    private var transcript = Transcript()
    /// 現在の確定済みの文に続く途中結果の履歴。先頭は窓の始まりの時点で見えていた結果。
    private var history: [(time: TimeInterval, volatile: String)] = []

    mutating func observe(_ newTranscript: Transcript, at time: TimeInterval) {
        if newTranscript.finalized != transcript.finalized {
            history = []
        }
        transcript = newTranscript
        history.append((time, newTranscript.volatile))
    }

    mutating func sync(at time: TimeInterval) -> [LiveTextOp] {
        let windowStart = time - Self.stabilityWindow
        if let baseline = history.lastIndex(where: { $0.time <= windowStart }) {
            history.removeFirst(baseline)
        }
        var stableVolatile = ""
        if let baseline = history.first, baseline.time <= windowStart {
            stableVolatile = history.dropFirst().reduce(baseline.volatile) { Self.commonPrefix($0, $1.volatile) }
        }
        let stable = transcript.finalized + stableVolatile
        // 打った文字が最新の結果と矛盾しないうちは、安定判定が一時的に短くなっても消さない。
        let keepsTyped = transcript.text.hasPrefix(typed) && typed.count >= stable.count
        return reconcile(to: keepsTyped ? typed : stable)
    }

    /// 録音を確定したとき、最後の結果すべてに合わせる。
    mutating func finish() -> [LiveTextOp] {
        reconcile(to: transcript.text)
    }

    /// 取り消したとき、このセッションで打った文字をすべて消す。
    mutating func cancel() -> [LiveTextOp] {
        reconcile(to: "")
    }

    private mutating func reconcile(to target: String) -> [LiveTextOp] {
        let common = Self.commonPrefix(typed, target).count
        var ops: [LiveTextOp] = []
        if typed.count > common {
            ops.append(.backspace(typed.count - common))
        }
        if target.count > common {
            ops.append(.type(String(target.dropFirst(common))))
        }
        typed = target
        return ops
    }

    private static func commonPrefix(_ a: String, _ b: String) -> String {
        String(zip(a, b).prefix { $0 == $1 }.map(\.0))
    }
}

extension LiveTextReconciler {
    static func canType(flags: CGEventFlags) -> Bool {
        !flags.contains(.maskCommand)
    }
}
