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

## リリース

- PRに `feat:` または `fix:` コミットが含まれる場合、マージ後にリリースタグを打つこと
- タグは semver 形式（`v1.x.x`）。`feat:` はマイナーバージョン、`fix:` はパッチバージョンを上げる
- タグを push すると GitHub Actions（`.github/workflows/release.yml`）が DMG ビルド → GitHub Release 作成まで自動実行される

```bash
# 例: 現在 v1.4.0 で fix: を含むPRをマージした場合
git checkout main && git pull
git tag v1.4.1
git push origin v1.4.1
```

## ローカル動作確認手順

### インストールせずに確かめる

キー監視と入力には `.app` バンドルと権限が要るため、常駐アプリとしての動作は開発用バイナリでは確かめられない。
次の 3 つは `/Applications` を触らずに使える。

```bash
# 純粋ロジック（録音キーの状態遷移・リアルタイム入力の打ち直し・辞書の置き換え）の検査
bash scripts/check-trigger-state-machine.sh

# 音声ファイルを本番と同じ認識経路へ流し、途中結果と打ち込む操作を時刻付きで表示（キー入力は送らない）
source scripts/lib.sh && build_release   # Command Line Tools だけの環境では macOS 26 SDK を選んでビルド
say -v Kyoko -o /tmp/d.aiff "スラックで仕様を確認します"
.build/release/Koe --transcribe-file /tmp/d.aiff --dictionary Slack=スラック,仕様=使用

# 画面下の表示・設定画面・メニューを PNG に書き出す（権限は「未許可」で描かれる）
.build/release/Koe --render-snapshots /tmp/koe-snapshots
```

### インストールして確かめる

```bash
./build.sh
```

- release ビルド、`.app` バンドル作成、固定の識別子での署名、`/Applications` へのインストールまで行う。利用者が普段使っている `/Applications/Koe.app` を上書きするので、実行前に確認すること
- 署名の識別子が変わった場合、**システム設定 → プライバシーとセキュリティ → アクセシビリティ** で Koe を再許可する必要がある
- アクセシビリティ権限がないと、リアルタイム入力のキー送出と `⌃⌘V` の貼り付けが動作しない

## Swift開発ガイドライン参照ドキュメント

### デザイン（UI/UX）

- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) — Appleプラットフォーム全体のUIデザイン原則・パターン・コンポーネント

### コード設計・命名規則

- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) — 命名規則、APIの設計原則
- [Swift Documentation](https://www.swift.org/documentation/) — Swift言語公式ドキュメント（Standard Library、Package Manager、DocC等）

### フレームワークリファレンス

- [SwiftUI](https://developer.apple.com/documentation/SwiftUI) — SwiftUI公式リファレンス
- [Swift (Apple Developer)](https://developer.apple.com/documentation/swift) — Apple Developer上のSwiftリファレンス
