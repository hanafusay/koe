import Foundation

/// 辞書の 1 項目。誤認識パターンはカンマか読点で区切る。
struct DictionaryEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var word = ""
    var misrecognitions = ""

    var trimmedWord: String { word.trimmingCharacters(in: .whitespaces) }

    var patterns: [String] {
        misrecognitions
            .split(whereSeparator: { $0 == "," || $0 == "、" || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension [DictionaryEntry] {
    /// 音声認識に聞き取りの手がかりとして渡す語。
    var words: [String] {
        map(\.trimmedWord).filter { !$0.isEmpty }
    }

    /// 誤認識パターンを正しい表記に置き換える。左から一度だけ走査し、長い一致を優先する。
    /// 正しい表記そのものも一致の対象にして素通しするため、正しい表記がパターンを含んでいても
    /// （「議事」→「議事録」など）二重に置き換わらない。
    func corrected(_ text: String) -> String {
        let rules = flatMap { entry -> [(from: String, to: String)] in
            let word = entry.trimmedWord
            guard !word.isEmpty else { return [] }
            return [(word, word)] + entry.patterns.map { ($0, word) }
        }
        .sorted { $0.from.count > $1.from.count }
        guard rules.contains(where: { $0.from != $0.to }) else { return text }

        var result = ""
        var rest = text[...]
        while !rest.isEmpty {
            if let rule = rules.first(where: { rest.hasPrefix($0.from) }) {
                result += rule.to
                rest = rest.dropFirst(rule.from.count)
            } else {
                result.append(rest.removeFirst())
            }
        }
        return result
    }
}
