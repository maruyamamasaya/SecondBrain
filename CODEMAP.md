# Code Map

機能から主要コードへ到達するための索引です。

現行コードだけを対象とします。Apps / Tools HubはDomain／Persistence／Default Catalog／3列タイルUI／起動処理まで実装済みです。

## Application Entry / UI

- `AiTextApp/App/AiTextApp.swift` — SwiftUIエントリーポイント、UIテスト用composition。
- `AiTextApp/App/AppTheme.swift` — Primitive／Semantic／Theme／Effect token、4テーマ、UserDefaults永続化、Reduce Motion対応background、共通Surface、テーマ選択Preview。
- `AiTextApp/App/ThoughtAnalyticsView.swift` — ローカル分析のサマリーと日別／曜日／時間帯／タグ／Continuation表示。
- `AiTextApp/App/DailySummaryView.swift` — 生成済みサマリーの閲覧専用一覧／詳細、日本語表記の月カレンダー、日別件数／継続件数、構造化Summary、Human限定の送信前プレビュー、要約済み過去日の安全な再生成、その日のjournal Draft生成。独立した日本語表記の日記カレンダーと日別詳細では、同期済みGitHub日記のMarkdownを見出し・箇条書き・引用として読みやすく表示する。
- `AiTextApp/App/WeeklyReviewView.swift` — 過去12完了週の一覧、週間サマリーの送信前確認／生成／再生成、保存内容表示、次週プラン候補の編集・確定UI。
- `AiTextApp/App/TimelineView.swift` — `MainTabView`（Home／Mentions／AI機能／Tools／Profile）、各タブの独立`NavigationStack`、Home／Mentions末尾の追加読込、Home上部の本文検索、右上の振り返り・返信表示切替・投稿Composer・投稿者フィルター、Mention／Reply一覧、AI機能ハブ、Apps catalogの3列正方形タイルとURL／Native起動、サマリー閲覧／生成を分けた振り返り画面、投稿一覧を持たない共通Actor Profile、Profile右上から開く一般Settings、Thought Detail、History、Continuation Composer、削除UI。
- `AiTextApp/App/TimelineView.swift`内`AIProviderSettingsView`／各Provider設定View — GeminiのFirebase設定検出、OpenAIの端末限定Keychain API key管理、Claude未対応表示と、色・文言を併用した設定状態一覧。
- `AiTextApp/App/TimelineView.swift`内`ProfileEditorView`／`PersonaIcon` — デフォルト人間の表示名、写真選択・縮小、丸型アイコン表示。
- `AiTextApp/App/TimelineView.swift`内`PersonaManagementView`／`AIPersonaEditorView` — 複数AI Personaの一覧、追加、編集、無効化。
- `AiTextApp/App/TimelineView.swift`内`AIPersonaManagementView`／`ActorProfileView` — AI Persona一覧からプロフィールを開き、表示内容と設定を確認・編集する管理導線。AIプロフィールには外部ブレインのローカル準備状態、GET接続確認、成功時の緑ライトと最終確認日時を表示する。
- `AiTextApp/App/TimelineView.swift`内`AIPostRequestView`／`AIPostPreviewView` — Settingsの独立画面で投稿者AIを選択して依頼を入力し、Persona External Brainのroute／source、最終payloadを確認して明示送信する導線。
- `AiTextApp/App/TimelineView.swift`内`AIReplyRequestView`／`AIReplyPreviewView` — メンション付きThoughtへのAI返信依頼、対象と最終payload確認、明示送信、Detail返信表示。
- `AiTextApp/App/ThoughtStore.swift` — Timeline投稿・50件単位の追加読込境界、本文検索／タグ／Review／History／Continuation／Apps catalog UI stateとCoreの接続。
- `AiTextApp/App/ShareSheet.swift` — Exportファイルを標準Share Sheetへ渡すbridge。
- `AiTextApp/App/ExternalBackupManager.swift` — security-scoped bookmark、外部backup／RestoreのUI state。
- `AiTextApp/App/FolderPicker.swift` — iOS標準Filesフォルダpicker bridge。
- `AiTextApp/App/GeminiReviewSummaryClient.swift` — Firebase／App Check bootstrap、Firebase AI Logic transport、通常起動用client factory。
- `AiTextApp/App/OpenAIReviewSummaryClient.swift` — 個人所有端末限定のOpenAI直接client、`ThisDeviceOnly` Keychain、Responses APIの`reasoning.effort`／`max_output_tokens`、response／token usage、HTTP error変換。
- `AiTextApp/App/ExternalBrainManager.swift` — 単一GitHub Repository設定、Keychain token、read-only GitHub API、同期状態。
- `AiTextApp/App/ExternalBrainManager.swift` — read用remoteと分離したGitHub Draft writer、`drafts/`へのnew-file-only保存、Read／Write Drafts capability表示。
- `AiTextApp/App/TimelineView.swift`内`KnowledgeManagementView`／`KnowledgeDraftReviewView` — Draft一覧・検索・filter、Review編集、Approve／Reject、Promote確認、正式Knowledge一覧・詳細。
- `AiTextApp/App/TimelineView.swift`内`KnowledgeQualityView`／`KnowledgeCompareView` — 手動Quality解析、候補一覧、比較、Dismiss、Merge Draft、Archive／Supersede、Knowledge利用状況。
- `AiTextApp/AiTextApp.entitlements` — Release App Attestのproduction environment entitlement。
- `AiTextApp.xcodeproj` — iPhone app、UI Testとshared scheme。

Search: `@main|TimelineView|ThoughtStore|confirmationDialog`

## Thought Domain

- `ThoughtCore/SecondBrainApp.swift` — Apps / Tools共通model、Native／Web／Local Web／External種別、分離したlaunch target、URL／scheme／local host／sort order validation、Repository protocol、固定UUIDとversionを持つDefault Catalog v2、分離したPreview／test fixture。

- `ThoughtCore/Thought.swift` — 原文、Persona、AI Persona設定、AI投稿／AI返信preview・生成use case、typed Reply Contextと取得repository境界、メンションmodel。
- `ThoughtCore/ThoughtDraft.swift` — 140文字、trim、validation。
- `ThoughtCore/ThoughtTimeline.swift` — 投稿、降順表示、初回50件とkeyset cursorによる追加読込、soft delete use case。
- `ThoughtCore/ThoughtRelation.swift` — Relationモデル、repository／原子的Continuation境界、History取得use case。
- `ThoughtCore/ThoughtTag.swift` — タグmodel、正規化規則、付与結果、repository／transaction境界。
- `ThoughtCore/ThoughtAnalytics.swift` — typed分析model、30日Calendar境界、分析Repository／Use Case。

Search: `ThoughtDraft|post|delete|deletedAt`

## Persistence

- `ThoughtCore/ThoughtRepository.swift` — CRUD・Timeline page・本文検索・通常の日付範囲query・Daily Summary専用`fetchHumanThoughts(from:to:)`境界、Review期間計算、テスト用メモリ実装。
- `ThoughtCore/SQLiteThoughtRepository.swift` — SQLite schema v22、作成日時＋UUIDのkeyset Timeline page、Persona／投稿者／AI設定・Provider・生成来歴／メンション／AI返信Relation、Daily／Weekly SummaryとWeekly Plan、独立Apps catalog CRUD、Default Catalogのmissing-only seed／適用履歴、Knowledge Review／Quality／usage、実カラム照合migration、各種query、旧JSON migration／2世代backup。
- `ThoughtCore/ReviewSummary.swift` — AI要約model、immutable送信preview、通信／transport／保存protocol、中央provider／model設定、用途別`AIGenerationProfile`、typed service error、対象準備／鮮度検証／生成・保存use case、Mock client。
- `ThoughtCore/DailySummary.swift` — Human限定のv3 prompt、確定Humanタグ・時間帯・Human Relation、stale対応preview、準備／生成use case。既存v1／v2 modelの互換decodeは維持し、新規生成ではAI本文・`aiInteractions`を扱わない。
- `ThoughtCore/WeeklyReview.swift` — 月曜〜日曜の週境界、Human限定週間Summary、次週Plan、用途別prompt／preview／生成use case、確定前Planを保存しないrepository境界。
- `ThoughtCore/ReviewSummaryExporter.swift` — 旧期間要約の互換コード。現在のUIからは利用せず、既存データを壊さないため保持する。
- `ThoughtCore/ThoughtExporter.swift` — Repository経由のMarkdown／JSON生成。
- `ThoughtCore/ExternalBackup.swift` — manifest、外部2世代backup、検証、pending Restore／rollback。
- `ThoughtCore/ExternalBrain.swift` — Persona別設定、AGENT.md／front matter parser、heading chunk、manifest差分cache、SQLite FTS5、route優先retrieval、AI Reply／Persona Post共通のprompt用provenance。
- `ThoughtCore/ExternalBrain.swift` — Knowledge Draft source／type（意思決定・ナレッジ・メモリ・プロジェクトメモ・日記）／Markdown／safe slug、Draft生成prompt・use case、関連資料FTS検索、日記を過去の記憶として扱う取得時ルール、write protocol。
- `ThoughtCore/ExternalBrain.swift` — Review状態遷移、provenance、KnowledgeDocument、安全な正式path、Draft／Knowledge repositoryとlifecycle event境界。
- `ThoughtCore/ExternalBrain.swift` — Knowledge status、Quality Candidate、正規化重複／類似／stale analyzer、Merge provenance、usage tracking境界。

Search: `ThoughtRepository|ThoughtRelationRepository|createContinuation|SQLiteThoughtRepository|ExternalBackupService|RestoreCoordinator|legacy_json_v1`

## AI API Usage Analytics v1

- `ThoughtCore/AIAPIUsage.swift` — Usage metadata、Feature／Status／Error分類、記録・分析repository境界、共通Recorder、ローカル集計。
- `ThoughtCore/SQLiteThoughtRepository.swift` — schema v14内の`ai_api_usage`保存・期間query、Knowledge lifecycle／Quality／retrieval usage保存。
- `AiTextApp/App/AIAPIUsageAnalyticsView.swift` — AI機能タブから開く期間別Dashboard。
- `ThoughtCoreTests/AIAPIUsageTests.swift` — 記録、集計、privacy、failure isolation。

## Tests

- `ThoughtCoreTests/SecondBrainAppTests.swift` — App validation、Default Catalog固定UUID／順序／お気に入り／Study fragment／Study App URL、v1→v2追加seed、missing-only seed／編集保持／削除後非再生成、URL query／fragment round-trip、SQLite CRUD、既存Thoughtを保持するschema v20→v22／v21→v22 migration。

- `ThoughtCoreTests/ThoughtTimelineTests.swift` — 投稿境界、Unicode、SQL順序、50件単位のページングと同一日時cursor、削除、本文検索、タグ・v4 migration、再読込、Export、Review期間・順序・件数。
- `ThoughtCoreTests/ExternalBrainTests.swift` — AGENT parser、path traversal、front matter、heading chunk、draft除外、SHA差分同期／削除／offline cache、Persona route、最大件数、0件、prompt境界。
- `ThoughtCoreTests/ExternalBrainTests.swift` — Knowledge Draft全type／source、front matter、安全なslug・path、生成prompt、最大3件のローカルFTS関連検索、生成後のRetrieval除外。
- `AiTextApp/App/ExternalBrainManager.swift` — 共有GitHub repository設定、Keychain PAT、既存Contents API client、read-only接続確認、capability／接続エラー分類。
- `AiTextApp/App/TimelineView.swift` — Settings内GitHub Repository編集、Token置換・削除、Repository変更警告、接続結果・保存path・External Brain状態表示。
- `AiTextAppUITests/ThoughtFlowUITests.swift` — 投稿、削除、検索、タグ追加・Timeline表示・絞り込み・Detail遷移、Continuation、History、Reviewの主要UI flow。
- `Package.swift` — `swift test`用manifest。
