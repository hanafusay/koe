import Foundation

@MainActor
protocol PasteServing: AnyObject {
    func getSelectedText() -> String?
    func paste(text: String)
    func copy(text: String)
}

/// 話している最中に前面アプリへ文字を打ち込む。
@MainActor
protocol LiveTyping: AnyObject {
    func begin()
    /// 今キーを送ってよいか。false の間は apply を呼ばない。
    var canType: Bool { get }
    /// 前面アプリか入力欄が begin のときから変わっていたら何もせず false を返す。
    func apply(_ ops: [LiveTextOp]) -> Bool
    func end()
}
