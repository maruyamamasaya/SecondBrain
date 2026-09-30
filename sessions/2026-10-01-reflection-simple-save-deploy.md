# 2026-10-01 日記・振り返りの簡単保存と実機導入

- Project Context: MATCH。ユーザー承認済みの「作る → 確認・編集 → 保存」を実装しVesperaへ導入。既存の未コミット変更を保持。
- 日記生成は共通編集画面へ、Daily／Weekly生成成功後も編集・保存画面を自動表示。生成済み振り返りは追加AI callなしで保存できる。サマリー一覧にも編集・保存導線を追加。
- 明示保存はSQLite Draftへ先行保存してGitHubのactiveファイルへ反映。UUID付きpathを固定し、既知SHAで同じファイルを更新。送信待ちを保持し、日記のカレンダー・詳細から再編集／再送できる。通常Knowledgeの承認／正式化は維持。
- 保存先をprovenanceへ固定。GitHub外部編集／削除・保存先変更は上書きしない。GET内容一致なら成功として扱い、応答喪失時の再送を可能にする。cacheは書き込み成功後に更新。既存日記は元front matterの生成元とcustom metadataを保持。
- SQLite schemaはv22のまま。既存provenance JSONへのoptional追加は互換decodeをテスト。AI Summary原本とMarkdown編集版を分離し、閲覧は保存した編集版を優先。

## 検証

- swift test: 全159件／14 suite成功。追加4件はSHA条件・衝突・同一内容再送、UUID pathとfront matter、送信待ち／保存済み再読込、既存metadata保持を確認。
- 最初のCore compileでapp限定error型参照を検出しDomain専用error型へ修正。追加テストのparser先頭改行とSQLite日時浮動小数点精度依存も期待・固定時刻を修正し、最終全件成功。
- 既存iPhone 17 Pro Simulatorを1台のみ使用、並列無効／worker 1。testJournalSaveFailureKeepsEditedContentInCalendar、testDailySummaryGenerationOpensSaveEditorの各1回実行に成功。専用一時SQLite／未設定GitHub／Mockを使用し実データ・実GitHub書き込みなし。
- Debug Vespera向け署名build成功、devicectl上書きinstallと--terminate-existing起動成功。既存アプリ・端末データ削除なし。実GitHubとの通信・実機UIの目視確認は未実施。
- git diff --check成功。commit／pushなし。
- XCTestDevicesの開始前一覧・3.5Gを記録。終了後の新規UUID folderは0、削除0、残容量3.5G。既存Simulator／Xcodeデータ削除なし。

## 追加: 実行状態と連打防止

- ユーザーの追加要望により、日記／Daily／Weekly生成中と端末保存・GitHub反映／更新中のProgressViewを追加。保存／生成／入力／画面終了を実行中は無効化。Daily／Weekly／Plan生成のstore境界にも多重実行guardを追加。
- UIだけの追加に対してCore test再実行なし。先行検証はCore159件・UI2件成功。追加版の署名buildとVespera導入は以下へ追記。

- 実行状態表示・多重実行防止の最終版もDebug署名build成功。Vesperaへの上書きinstall／devicectl起動成功。git diff --check成功。追加後の実機UI目視／実GitHub通信は未確認。
