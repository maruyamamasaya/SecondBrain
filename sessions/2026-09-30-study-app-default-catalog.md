# Study App Default Catalog追加

日付: 2026-09-30

## 変更

- 既存の`Study`と`My Wiki`を維持したまま、Default Catalogへ`Study App`を追加した。
- 起動先は`https://study-app-maruyama.maruyama-001.chatgpt.site/`、固定UUIDは`40000000-0000-4000-8000-000000000005`、表示順は既存`Study`と`Tool`の間にした。
- catalog versionを2へ更新した。per-appのseed履歴を使うため、v1適用済みDBにはStudy Appだけが追加され、既存項目の編集内容は上書きされない。
- Core testとUI testの期待値を5件へ更新し、v1適用済みDBからの追加seed testを追加した。

## 検証

- Windows環境にSwift toolchainがないためSwift Testing／Xcode build／UI Testは未実施。
- `git diff --check`は成功し、変更箇所を静的確認した。
- 指定URLは外部確認ツールからアクセスできなかったため、到達性は未確認。文字列とHTTPS Domain validationは実装・test期待値で確認する。
