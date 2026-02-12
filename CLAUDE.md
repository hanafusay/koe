# Project Rules

## ブランチ運用

- mainブランチへの直接コミットは禁止。必ずフィーチャーブランチを作成してから作業すること
- フィーチャーブランチをマージしたら、リモートのブランチを削除すること

## コミットメッセージ

- コミットメッセージは日本語で書くこと
- Conventional Commits 形式を使用する。プレフィックス後のメッセージはユーザー向けのわかりやすい表現にすること
  - `feat:` — 新機能（例: `feat: 設定画面にマイク選択機能を追加`）
  - `fix:` — バグ修正（例: `fix: AirPods切り替え時にアプリが落ちる問題を修正`）
  - `docs:` — ドキュメントのみの変更
  - `chore:` — ビルド・CI・設定などコードに影響しない変更
  - `refactor:` — 機能変更を伴わないリファクタリング
- `feat:` と `fix:` はリリースノートに自動掲載されるため、エンドユーザーに伝わる内容で書く

## Swift開発ガイドライン参照ドキュメント

### デザイン（UI/UX）

- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) — Appleプラットフォーム全体のUIデザイン原則・パターン・コンポーネント

### コード設計・命名規則

- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) — 命名規則、APIの設計原則
- [Swift Documentation](https://www.swift.org/documentation/) — Swift言語公式ドキュメント（Standard Library、Package Manager、DocC等）

### フレームワークリファレンス

- [SwiftUI](https://developer.apple.com/documentation/SwiftUI) — SwiftUI公式リファレンス
- [Swift (Apple Developer)](https://developer.apple.com/documentation/swift) — Apple Developer上のSwiftリファレンス
