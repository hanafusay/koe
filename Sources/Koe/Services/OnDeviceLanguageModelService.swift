import Foundation
import FoundationModels

enum LanguageModelUnavailableReason: Error, Equatable {
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case unknown

    /// 「〜のため修正できません」のように後ろへ続けて使う。
    var message: String {
        switch self {
        case .appleIntelligenceNotEnabled: return "Apple Intelligence が無効"
        case .deviceNotEligible: return "この Mac が Apple Intelligence に非対応"
        case .modelNotReady: return "Apple Intelligence のモデルが準備中"
        case .unknown: return "オンデバイスモデルが利用不可"
        }
    }
}

/// 選択したテキストを、話した指示に従って Mac 内蔵の Apple Intelligence で書き換える。
final class OnDeviceLanguageModelService {
    // 規則だけの指示では「時間を16時に変えて」が「16時にからです」になった。例を見せると部分置換と箇条書きが安定する。
    static let instructions = """
    あなたは文章を書き換える道具です。対象テキストを指示どおりに書き換えた完成文だけを出力します。説明や前置きは書きません。
    指示が一部の語句の変更なら、その語句だけを置き換え、残りは一字も変えません。
    箇条書きは行頭に「・」を使い、Markdown の記号（* や -）は使いません。

    例1
    対象テキスト: 会議は月曜の10時からです
    指示: 曜日を水曜に変えて
    出力: 会議は水曜の10時からです

    例2
    対象テキスト: 資料送っといて
    指示: 丁寧語にして
    出力: 資料をお送りいただけますでしょうか。

    例3
    対象テキスト: 確認事項は日程と予算と担当者です
    指示: 箇条書きにして
    出力: 確認事項
    ・日程
    ・予算
    ・担当者
    """

    var unavailableReason: LanguageModelUnavailableReason? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .unknown
        }
    }

    func correct(selectedText: String, instruction: String) async throws -> String {
        if let reason = unavailableReason { throw reason }
        // 会話履歴が次の修正に混ざらないよう、リクエストごとに新しいセッションを作る。
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(
            to: "対象テキスト: \(selectedText)\n指示: \(instruction)\n出力:",
            options: GenerationOptions(sampling: .greedy)
        )
        return Self.clean(response.content, original: selectedText)
    }

    private static let quotePairs: [(Character, Character)] = [
        ("「", "」"), ("『", "』"), ("\"", "\""), ("“", "”"), ("'", "'"),
    ]

    /// モデルが出力を「」で囲むことがある。元の文が囲まれていなければ外す。
    static func clean(_ output: String, original: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in quotePairs where text.count >= 2 && text.first == open && text.last == close {
            if source.first == open && source.last == close { return text }
            return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
