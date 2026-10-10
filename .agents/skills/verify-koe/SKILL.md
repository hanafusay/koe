---
name: verify-koe
description: koe! の変更を確かめる手順。純粋ロジックの検査、音声ファイルでの認識確認、画面のスナップショット、/Applications へのインストール後の実機確認を扱う。「動作確認して」「ビルドして入れて」「ハンズフリーを試したい」や、キー監視・打ち込み・録音キー・音声認識・画面を変えたときに使う。
---

# koe! の動作確認

キー監視と入力には `.app` バンドルと権限が要るため、常駐アプリとしての動作は開発用バイナリでは確かめられない。
変更の種類に応じて、インストールしない確認から順に行う。

## インストールせずに確かめる

```bash
# 純粋ロジック（録音キーの状態遷移・リアルタイム入力の打ち直し・辞書の置き換え）の検査
bash scripts/check-trigger-state-machine.sh

# ビルド。Command Line Tools だけの環境では macOS 26 SDK を選ぶ
source scripts/lib.sh && build_release

# 音声ファイルを本番と同じ認識経路へ流し、途中結果と打ち込む操作を時刻付きで表示（キー入力は送らない）
say -v Kyoko -o /tmp/d.aiff "スラックで仕様を確認します"
.build/release/Koe --transcribe-file /tmp/d.aiff --dictionary Slack=スラック,仕様=使用

# 画面下の表示・設定画面・メニューを PNG に書き出す（権限は「未許可」で描かれる）
.build/release/Koe --render-snapshots /tmp/koe-snapshots
```

## インストールして確かめる

```bash
./build.sh
```

- release ビルド、`.app` バンドル作成、固定の識別子での署名、`/Applications` へのインストールまで行う。利用者が普段使っている `/Applications/Koe.app` を上書きするので、実行前に利用者へ確認する
- 入れ替えた直後に録音キーが反応しないことがある。`pkill -x Koe; open /Applications/Koe.app` で起動し直してから確かめる
- 署名の識別子が変わった場合、**システム設定 → プライバシーとセキュリティ → アクセシビリティ** で Koe を再許可する必要がある
- アクセシビリティ権限がないと、リアルタイム入力のキー送出と `⌃⌘V` の貼り付けが動作しない

## キー監視・打ち込み・録音キーを変えたとき

マージ前に、インストールした版で **fn の押しっぱなし** と **fn の 2 回押し（ハンズフリー）** の両方を試す。
`~/Library/Logs/Koe/koe.log` で、途中停止（`User input during live typing`）が無く、`typedAll=true` で終わることを確かめる。

Control など別の録音キーでの確認では代わりにならない。fn は押すたびに keyDown も出すため、fn でしか起きない不具合がある（v1.1.0 でハンズフリーが動かなくなった）。
