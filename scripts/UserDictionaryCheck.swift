import Foundation

extension TriggerStateMachineCheck {
    static func checkUserDictionary() {
        let dictionary = [
            DictionaryEntry(word: "経費精算", misrecognitions: "経費生産"),
            DictionaryEntry(word: "仕様", misrecognitions: "使用、私用"),
            DictionaryEntry(word: "  ", misrecognitions: "無視される"),
        ]
        check(dictionary.words == ["経費精算", "仕様"], "dictionary: blank words are not passed to the recognizer")
        check(dictionary.corrected("経費生産の使用と私用を確認") == "経費精算の仕様と仕様を確認",
              "dictionary: every misrecognition is replaced, with either separator")
        check(dictionary.corrected("無視される") == "無視される", "dictionary: patterns of a blank word are ignored")
        check([DictionaryEntry(word: "仕様")].corrected("使用") == "使用", "dictionary: a word without patterns replaces nothing")

        let containing = [DictionaryEntry(word: "経費精算", misrecognitions: "精算")]
        check(containing.corrected("経費精算と精算") == "経費精算と経費精算",
              "dictionary: a word that contains its own pattern is not replaced twice")
        let overlapping = [
            DictionaryEntry(word: "A社", misrecognitions: "えー"),
            DictionaryEntry(word: "AB社", misrecognitions: "えーびー"),
        ]
        check(overlapping.corrected("えーびーとえー") == "AB社とA社", "dictionary: the longest pattern wins")

        checkDictionaryWhileVolatileGrows(dictionary)
    }

    /// 本番では途中結果のたびに置き換えてから LiveTextReconciler に渡す。誤認識が 1 文字ずつ現れても、
    /// 置き換わる瞬間に 1 度だけ打ち直し、行ったり来たりしないことを確かめる。
    /// 1 文字ごとに 0.5 秒空け、安定判定の窓（0.3 秒）より遅く伸びる、打ち直しが最も出やすい速さにする。
    static func checkDictionaryWhileVolatileGrows(_ dictionary: [DictionaryEntry]) {
        let spoken = Array("経費生産の使用です")
        var reconciler = LiveTextReconciler()
        var field = FakeField(text: "")
        var backspaces = 0
        var tick = 0
        for count in 1...spoken.count {
            reconciler.observe(Transcript(volatile: dictionary.corrected(String(spoken.prefix(count)))), at: Double(tick) / 10)
            for _ in 0..<5 {
                let ops = reconciler.sync(at: Double(tick) / 10)
                backspaces += ops.filter { if case .backspace = $0 { return true } else { return false } }.count
                field.apply(ops)
                tick += 1
            }
        }
        field.apply(reconciler.finish())
        check(field.text == "経費精算の仕様です", "dictionary: live typing ends with the corrected text")
        check(backspaces == 2, "dictionary: each misrecognition is retyped exactly once as it is corrected (got \(backspaces))")
        check(!field.overDeleted, "dictionary: corrections never delete beyond what was typed")
    }
}
