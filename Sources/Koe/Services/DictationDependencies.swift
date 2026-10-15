import Foundation

@MainActor
protocol PasteServing: AnyObject {
    func paste(text: String)
    func copy(text: String)
}

/// 話している最中に前面アプリへ文字を打ち込む。
@MainActor
protocol LiveTyping: AnyObject {
    func begin()
    /// 今キーを送ってよいか。false の間は apply を呼ばない。
    var canType: Bool { get }
    /// 前面アプリか入力欄が前回から変わっていたら、打つ先を今の入力欄に移して true を返す。
    func followFocus() -> Bool
    /// パスワード欄では何もせず false を返す。
    func apply(_ ops: [LiveTextOp]) -> Bool
    func end()
}
