# 最新mainの取り込み・テスト・Vespera再デプロイ

- Project ContextはMATCH。Git rootを確認し、`origin/main`をfetchして`367a017`から`01122e1`へfast-forwardした。
- 既存の未コミット変更と未追跡ファイルを`codex-pre-sync-2026-09-30` stashへ保全してから復元した。stashは復旧用として保持している。commit／pushは実施していない。
- 文書の競合は最新のToolsタブ／Default Catalog v2仕様を優先し、Mac検証の最新状況をCURRENTとMAC_VALIDATIONへ反映した。元の文書もstashへ保全済み。
- テストの競合はlaunch policy、v19 migration、catalog v2追加の双方を保持。Swift Testingのthrowing式をマクロから分離し、v19 migration後のcatalog期待を5件へ修正した。
- `ThoughtStore.secondBrainApps`の統合後の重複定義を除去した。
- UIテストのタグ編集メニュー、投稿後のHome復帰、日本語画面名、返信折りたたみ後の最新AI返信先の検証を現行仕様へ合わせた。
- iOS 17.4 Simulatorで、返信後にメンションへ移動するとUINavigationBar内でSIGABRTが再現した。HomeのNavigationStack全体の再生成をNavigationPathリセットへ変更し、Homeからの投稿時は他タブも再生成しないようにした。

## 検証

- `swift test`: 13 suites、155 tests成功。
- 既存iPhone SE (3rd generation) iOS 17.4の1台を使用。全UIテスト16件を実行して11件成功、5件失敗。修正後、失敗5件は対象を絞った再検証ですべて成功した。
- Navigation変更後は返信・AI会話・5タブ遷移の3件に加え、Continuation・Draft保持・投稿／削除の3件も成功した。最終版で全16件を一括再実行はしていない。
- UIテストは常に`-parallel-testing-enabled NO -maximum-parallel-testing-workers 1`で実行した。
- 実機buildとSimulator testの同時起動で共有build DB lockが1回発生した。実機build終了後にSimulator testを単独実行し成功した。
- 最終版のVespera向けDebug署名build、`com.example.AiTextApp`の上書きinstall、`devicectl`起動確認に成功した。アプリ削除・端末内データ削除はしていない。
- `git diff --check`成功。実API生成、外部URLへの実遷移、Accessibilityの手動確認は未実施。

## ストレージ

- XCTestDevicesは開始時・終了時とも既存UUIDフォルダ1件、3.5G。
- テスト端末の新規作成0件、削除0件。既存DerivedDataを再利用し、削除していない。
