# Vesperaへの再デプロイ

- 対象はSecondBrainの現行iOSアプリ。Project ContextはMATCH。
- 現在の未コミット変更を含む作業ツリーを、既存の署名設定とDerivedDataでDebug buildした。`BUILD SUCCEEDED`を確認。
- Vespera（iPhone 17e）へ`com.example.AiTextApp`を上書きインストールし、`devicectl`で起動成功を確認した。
- アプリ削除・端末内データ削除は実施していない。ソースコード変更、commit、pushは実施していない。
- `git diff --check`成功。今回は配布作業のためUnit Test／XCUITestは再実行していない。画面・外部APIの動作は未確認。
- XCTestDevicesは3.5G。テスト端末の新規作成0件、削除0件。
