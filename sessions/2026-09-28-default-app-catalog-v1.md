# Session: Default App Catalog v1

- Date: 2026-09-28
- Environment: Windows
- Status: 実装済み、Mac検証待ち

## 目的

Apps / Tools Hub v1へ、実在する4つのWebアプリを正式なDefault Catalogとして追加する。初期値の利便性を提供しながら、ユーザー編集を上書きせず、削除したDefault Appを再生成しない永続化境界を作る。

## 実装

- `SecondBrainDefaultApps`へcatalog version 1と4つの固定UUIDを定義した。
- Shared Memo、My Wiki、Study、Toolを指定URL、favorite、sortOrderで定義した。Studyの`#/`を文字列のまま保持する。
- `SecondBrainAppFixtures`はPreview／test専用としてDefault Catalogから分離した。
- schemaをv21からv22へ上げ、`secondbrain_default_app_seed_history`を非破壊追加した。
- Repository初期化時にDefault Catalogをmissing-onlyでseedする。
- App挿入と履歴記録をtransaction化し、同じ固定UUIDの既存Appを変更しない。
- 適用履歴にはApp tableへの外部キーを付けず、Default App削除後も再seedしない。
- CRUD、固定UUID／順序／favorite、二重seed防止、編集保持、削除後非再生成、URL query／fragment round-trip、v20→v22／v21→v22 migrationのtestを追加・更新した。
- `CURRENT.md`、`ARCHITECTURE.md`、`CODEMAP.md`、`TESTING.md`、`NEXT_FEATURES.md`、`MAC_VALIDATION.md`、README、Decisionを更新した。

## schema v22の理由

App行が存在するかだけでは、未登録とユーザーによる削除を区別できない。削除を尊重しながら将来のcatalog versionで新しい固定IDだけを追加できるよう、App単位の適用履歴を正本SQLiteへ保存する必要があるためv22へ上げた。

## 検証

- WindowsにはSwift toolchain／Xcode／iOS Simulatorがないため、Swift compileとSwift Testingは未実施。
- Xcode build、schema migrationの実行、完全Backup / Restore、SwiftUI、URL起動、実機ネットワークは未確認。
- 静的差分確認と`git diff --check`を実施し、空白errorがないことを確認した（改行コードのwarningのみ）。

## 次の作業

1. Macで既知のSwift 6.3 compile blockerを解消する。
2. `SecondBrainAppTests`を含む全Swift Testingを実行する。
3. schema v20→v22／v21→v22と完全Backup / Restoreを確認する。
4. Catalog一覧／編集UIと、確認可能なURL起動app layerを実装する。
