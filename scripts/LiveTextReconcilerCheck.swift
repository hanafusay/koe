import CoreGraphics
import Foundation

extension TriggerStateMachineCheck {
    /// 前面アプリの入力欄を真似る。backspace が打った量を超えたら false を返す。
    struct FakeField {
        var text: String
        var overDeleted = false

        mutating func apply(_ ops: [LiveTextOp]) {
            for op in ops {
                switch op {
                case .backspace(let count):
                    if count > text.count { overDeleted = true }
                    text = String(text.dropLast(count))
                case .type(let string):
                    text += string
                }
            }
        }
    }

    static func checkLiveTextReconciler() {
        var growth = LiveTextReconciler()
        growth.observe(Transcript(volatile: "今"), at: 0)
        growth.observe(Transcript(volatile: "今日"), at: 0.1)
        growth.observe(Transcript(volatile: "今日は"), at: 0.2)
        check(growth.sync(at: 0.2) == [], "live: nothing is typed before any text has been stable for 0.3s")
        check(growth.sync(at: 0.45) == [.type("今日")], "live: types the prefix unchanged for 0.3s")
        check(growth.sync(at: 0.6) == [.type("は")], "live: types the newer text once it has been stable too")
        check(growth.sync(at: 0.7) == [], "live: no ops when nothing changed")

        var revision = LiveTextReconciler()
        revision.observe(Transcript(volatile: "今日は良い"), at: 0)
        check(revision.sync(at: 0.4) == [.type("今日は良い")], "live: stable volatile text is typed")
        revision.observe(Transcript(volatile: "今日はいい天気"), at: 0.5)
        check(revision.sync(at: 0.5) == [.backspace(2)], "live: a revision mid-tail deletes only the contradicted characters")
        check(revision.sync(at: 0.85) == [.type("いい天気")], "live: the revised text is typed once stable")
        revision.observe(Transcript(volatile: "今日はいい天気で"), at: 0.9)
        check(revision.sync(at: 0.95) == [], "live: typed text consistent with the latest result is kept while new text settles")

        var finalization = LiveTextReconciler()
        finalization.observe(Transcript(volatile: "そう世界も"), at: 0)
        _ = finalization.sync(at: 0.4)
        finalization.observe(Transcript(finalized: "そうだし世界も。"), at: 0.5)
        check(finalization.sync(at: 0.5) == [.backspace(3), .type("だし世界も。")], "live: finalization rewrites the typed tail immediately, including punctuation")
        finalization.observe(Transcript(finalized: "そうだし世界も。", volatile: "で"), at: 0.6)
        check(finalization.sync(at: 0.6) == [], "live: volatile text after a final segment waits for stability")
        finalization.observe(Transcript(finalized: "そうだし世界も。", volatile: "でもね"), at: 0.7)
        check(finalization.finish() == [.type("でもね")], "live: finishing types the whole last result without waiting")

        var punctuation = LiveTextReconciler()
        punctuation.observe(Transcript(volatile: "今日はいい天気です"), at: 0)
        _ = punctuation.sync(at: 0.4)
        punctuation.observe(Transcript(finalized: "今日はいい天気です。"), at: 0.5)
        check(punctuation.sync(at: 0.5) == [.type("。")], "live: a final that only adds punctuation appends it without deleting")

        var cancelled = LiveTextReconciler()
        cancelled.observe(Transcript(finalized: "確定した文。", volatile: "途中"), at: 0)
        _ = cancelled.sync(at: 0.4)
        check(cancelled.cancel() == [.backspace(8)], "live: cancel deletes exactly what this session typed")
        check(cancelled.typed.isEmpty, "live: nothing remains typed after cancel")
        var untouched = LiveTextReconciler()
        check(untouched.cancel() == [], "live: cancel before typing deletes nothing")

        check(LiveTextReconciler.canType(flags: []), "modifiers: types when no modifier is held")
        check(LiveTextReconciler.canType(flags: [.maskSecondaryFn]), "modifiers: types while fn is held")
        check(LiveTextReconciler.canType(flags: [.maskShift, .maskAlphaShift]), "modifiers: shift and caps lock do not stop typing")
        check(!LiveTextReconciler.canType(flags: [.maskControl]), "modifiers: does not type while control is held")
        check(!LiveTextReconciler.canType(flags: [.maskAlternate]), "modifiers: does not type while option is held")
        check(!LiveTextReconciler.canType(flags: [.maskCommand]), "modifiers: does not type while command is held")
        check(!LiveTextReconciler.canType(flags: [.maskSecondaryFn, .maskControl]), "modifiers: fn plus control still stops typing")

        // 修飾キーを押している間は sync を呼ばない。離したあとの sync と finish で、打った文字が結果に揃うこと。
        var held = LiveTextReconciler()
        var heldField = FakeField(text: "既存")
        held.observe(Transcript(volatile: "資料は"), at: 0)
        heldField.apply(held.sync(at: 0.4))
        held.observe(Transcript(volatile: "資料はSlack"), at: 0.5)
        held.observe(Transcript(volatile: "資料はslackで"), at: 0.6)
        held.observe(Transcript(finalized: "資料はSlackで共有しておきます。"), at: 0.9)
        heldField.apply(held.sync(at: 1.5))
        heldField.apply(held.finish())
        check(heldField.text == "既存資料はSlackで共有しておきます。" && !heldField.overDeleted,
              "modifiers: text skipped while held is typed after release without touching existing text")

        checkNeverOverDeletes()
    }

    /// 伸びる・書き換わる・確定するを乱数で混ぜ、入力欄の既存の文字を消さないことと、最後に結果と一致することを確かめる。
    static func checkNeverOverDeletes() {
        var generator = SplitMix64(seed: 41)
        let alphabet = Array("あいうえおかきくけこ、。")
        var allSafe = true
        var allMatch = true
        for _ in 0..<300 {
            var reconciler = LiveTextReconciler()
            var field = FakeField(text: "既存の文")
            var transcript = Transcript()
            var time: TimeInterval = 0
            for _ in 0..<40 {
                time += Double(generator.next() % 200) / 1000
                switch generator.next() % 6 {
                case 0 where !transcript.volatile.isEmpty:
                    transcript.finalized += transcript.volatile + "。"
                    transcript.volatile = ""
                case 1 where !transcript.volatile.isEmpty:
                    transcript.volatile = String(transcript.volatile.dropLast(Int(generator.next() % 3)))
                default:
                    transcript.volatile.append(alphabet[Int(generator.next() % UInt64(alphabet.count))])
                }
                reconciler.observe(transcript, at: time)
                field.apply(reconciler.sync(at: time))
            }
            field.apply(reconciler.finish())
            allMatch = allMatch && field.text == "既存の文" + transcript.text
            field.apply(reconciler.cancel())
            allSafe = allSafe && !field.overDeleted && field.text == "既存の文"
        }
        check(allMatch, "live: after finishing, the field holds exactly the final transcript (300 random sessions)")
        check(allSafe, "live: never deletes more than this session typed, and cancel restores the field (300 random sessions)")
    }

    struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
