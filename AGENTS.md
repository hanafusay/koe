# koe!

macOS メニューバー常駐の日本語リアルタイム音声入力アプリ。使い方と構成は [README.md](README.md)、設計方針は [ARCHITECTURE.md](ARCHITECTURE.md) を読む。

## ブランチ運用

- main ブランチへの直接コミットは禁止。必ずフィーチャーブランチを作成してから作業する
- フィーチャーブランチをマージしたら、リモートのブランチを削除する

## コミットメッセージ

- 日本語の Conventional Commits で書く。プレフィックス後はユーザー向けのわかりやすい表現にする
  - `feat:` 新機能（例: `feat: 設定画面にマイク選択機能を追加`）
  - `fix:` バグ修正（例: `fix: AirPods切り替え時にアプリが落ちる問題を修正`）
  - `docs:` ドキュメントのみ / `chore:` ビルド・CI・設定 / `refactor:` 機能変更を伴わない整理
- `feat:` と `fix:` はリリースノートに自動掲載されるため、エンドユーザーに伝わる内容で書く

## 動作確認とリリース

- 変更を確かめるときは `verify-koe` Skill、マージ後にリリースするときは `release-koe` Skill の手順に従う
- キー監視・打ち込み・録音キーの判定を変えたら、マージ前にインストールした版で fn の押しっぱなしとハンズフリーの両方を試す（手順は `verify-koe`）

## 参照ドキュメント

- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) — UI デザイン原則
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) — 命名規則と API 設計
- [SwiftUI](https://developer.apple.com/documentation/SwiftUI) / [Swift (Apple Developer)](https://developer.apple.com/documentation/swift) — フレームワークリファレンス
