# Code Map

機能から主要コードへ到達するための索引です。

## Application Entry / UI

- `AiTextApp/App/AiTextApp.swift` — SwiftUIエントリーポイント、scene-level `AppRoute.quickCapture`、UIテスト用composition。
- `Shared/QuickCaptureRoute.swift` — app／Widget共通の外部URL定義と厳密な検証。
- `AiTextApp/Info.plist` — `aitextapp` custom URL scheme登録。
- `AiTextAppWidget/QuickCaptureWidget.swift` — 固定表示のsystemSmall Widgetと`widgetURL`。
- `AiTextAppWidget/Info.plist` — WidgetKit Extension宣言。
- `AiTextApp/App/QuickCaptureView.swift` — 集中入力、local draft、自動focus、投稿・破棄確認UI。
- `AiTextApp/App/ThoughtAnalyticsView.swift` — ローカル分析のサマリーと日別／曜日／時間帯／タグ／Continuation表示。
- `AiTextApp/App/DailySummaryView.swift` — 月カレンダー、日別詳細、構造化Summary、送信前プレビュー。
- `AiTextApp/App/TimelineView.swift` — Composer、Lazy Timeline、トップ右上の歯車から開く設定（プロフィール／Persona、Export、バックアップ）、Thought検索、本文に紐づくタグUI、Thought Detail、History、Continuation Composer、削除UI。独立したHistory Review／タグ一覧のトップバー導線は持たない。
- `AiTextApp/App/TimelineView.swift`内`ProfileEditorView`／`PersonaIcon` — デフォルト人間の表示名、写真選択・縮小、丸型アイコン表示。
- `AiTextApp/App/TimelineView.swift`内`PersonaManagementView`／`AIPersonaEditorView` — 複数AI Personaの一覧、追加、編集、無効化。
- `AiTextApp/App/TimelineView.swift`内`AIPostRequestView`／`AIPostPreviewView` — AIへの依頼入力、最終payload確認、明示送信。
- `AiTextApp/App/ThoughtStore.swift` — Timeline／Quick Capture共通投稿境界、本文検索／タグ／Review／History／Continuation UI stateとCoreの接続。
- `AiTextApp/App/ShareSheet.swift` — Exportファイルを標準Share Sheetへ渡すbridge。
- `AiTextApp/App/ExternalBackupManager.swift` — security-scoped bookmark、外部backup／RestoreのUI state。
- `AiTextApp/App/FolderPicker.swift` — iOS標準Filesフォルダpicker bridge。
- `AiTextApp/App/GeminiReviewSummaryClient.swift` — Firebase／App Check bootstrap、Firebase AI Logic transport、通常起動用client factory。
- `AiTextApp/AiTextApp.entitlements` — Release App Attestのproduction environment entitlement。
- `AiTextApp.xcodeproj` — iPhone app、UI Test、埋め込み`AiTextAppWidget` Extension targetとshared scheme。

Search: `@main|TimelineView|ThoughtStore|confirmationDialog`

## Thought Domain

- `ThoughtCore/Thought.swift` — 原文、SNS型アカウントプロフィール、AI接続、AI投稿／メンション返信preview・生成use case、repository境界。
- `ThoughtCore/ThoughtDraft.swift` — 140文字、trim、validation。
- `ThoughtCore/ThoughtTimeline.swift` — 投稿、降順表示、soft delete use case。
- `ThoughtCore/ThoughtRelation.swift` — Relationモデル、repository／原子的Continuation境界、History取得use case。
- `ThoughtCore/ThoughtTag.swift` — タグmodel、正規化規則、付与結果、repository／transaction境界。
- `ThoughtCore/ThoughtAnalytics.swift` — typed分析model、30日Calendar境界、分析Repository／Use Case。

Search: `ThoughtDraft|post|delete|deletedAt`

## Persistence

- `ThoughtCore/ThoughtRepository.swift` — CRUD・本文検索・日付範囲repository境界、今日／昨日／直近日数／今週／今月／指定日のReview期間計算、テスト用メモリ実装。
- `ThoughtCore/SQLiteThoughtRepository.swift` — SQLite schema v11、アカウント／AI接続／投稿者／AI設定・生成来歴／メンション、AI返信Continuation transaction、本文検索／タグ／分析、旧JSON migration／2世代backup。
- `ThoughtCore/ReviewSummary.swift` — AI要約model、immutable送信preview、通信／transport／保存protocol、中央provider／model設定、typed service error、対象準備／鮮度検証／生成・保存use case、Mock client。
- `ThoughtCore/DailySummary.swift` — 構造化model、prompt、preview、準備／生成use case、1日1件のrepository境界。
- `ThoughtCore/ReviewSummaryExporter.swift` — 旧期間要約の互換コード。現在のUIからは利用せず、既存データを壊さないため保持する。
- `ThoughtCore/ThoughtExporter.swift` — Repository経由のMarkdown／JSON生成。
- `ThoughtCore/ExternalBackup.swift` — manifest、外部2世代backup、検証、pending Restore／rollback。

Search: `ThoughtRepository|ThoughtRelationRepository|createContinuation|SQLiteThoughtRepository|ExternalBackupService|RestoreCoordinator|legacy_json_v1`

## Tests

- `ThoughtCoreTests/ThoughtTimelineTests.swift` — 投稿境界、Unicode、SQL順序、削除、本文検索、タグ・v4 migration、再読込、Export、Review期間・順序・件数。
- `AiTextAppUITests/ThoughtFlowUITests.swift` — 投稿、削除、検索、タグ追加・Timeline表示・絞り込み・Detail遷移、Continuation、History、Reviewの主要UI flow。
- `Package.swift` — `swift test`用manifest。
