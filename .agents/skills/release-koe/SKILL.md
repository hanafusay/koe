---
name: release-koe
description: koe! のリリース手順。feat/fix を含む PR をマージしたあとに semver のタグを打ち、GitHub Actions で DMG と GitHub Release を作る。「リリースして」「タグを打って」「バージョンを上げて」で使う。
---

# koe! のリリース

PR に `feat:` または `fix:` コミットが含まれる場合、マージ後にリリースタグを打つ。`docs:` や `chore:` だけなら打たない。

1. 直近のタグを確かめ、次の版を決める。`feat:` はマイナー、`fix:` はパッチを上げる（semver、`vX.Y.Z` 形式）
2. main を最新にしてタグを push する

   ```bash
   git checkout main && git pull --ff-only
   git tag --sort=-v:refname | head -1
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

3. タグの push で `.github/workflows/release.yml` が動き、DMG のビルドと GitHub Release の作成まで行う。`gh run watch` で完了を確かめ、`gh release view vX.Y.Z` で DMG とリリースノートの SHA-256 を確認する
4. `v` で始まるタグはルールセットで削除・付け替えが禁止されている。打ち間違えたら新しい版で出し直す
