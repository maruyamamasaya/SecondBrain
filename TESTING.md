# Testing

## Test Strategy

UI非依存のドメイン／永続化／ExportはSwift PackageとしてLinux/macOS共通で検証します。SwiftUI appとXCUITestはmacOS/XcodeのSimulatorで検証します。

## Unit / Persistence Test

```bash
swift test
```

入力境界、SQLite、Persona、AI Reply／Context、タグ、ローカル分析、backup、Export、Historyに加え、Timelineの初回50件・50件単位追加読込・同一日時UUID cursor、Actor handleの正規化・一意性・ID維持、Human／AI Mention snapshotと範囲、Conversation Treeの両Relation統合・branch・currentPath・最新leaf、同一対象への複数AI各1返信、Daily Summary v3のHuman限定取得、Humanタグ限定、AIタグ候補のHuman index解決／不正index除外／生成時非保存／明示追加、Relation、共通時間帯とtimezone境界、空Insight、旧Summary decode、SQLite再読込、stale previewを検証します。

週間振り返りは月曜〜日曜の完了週境界、Human Thought限定、Terraの`weeklySummary`／medium／8,192 token、同週Summary置換、次週Plan候補の生成時非保存／明示確定、schema v20のSQLite round-tripを`WeeklyReviewTests.swift`で検証します。

Apps / Tools Hubは`SecondBrainAppTests.swift`で空名、負の表示順、不正URL、WebのHTTP、非local host、危険scheme、kind／launch target不整合を拒否し、Local WebのHTTP、External Deep Linkを許可するDomain境界を検証します。SQLiteはschema v21のCRUD、安定UUID、表示順、お気に入り、fixture非seed、既存Thoughtを保持するv20→v21 migrationを検証します。Windowsでtest codeまで実装済みですが、Swift toolchainがないため未実行です。

Persona External Brain／External Brain Routing v1はAGENT.md解析、`{current_project}`展開、unsafe path拒否、Markdown front matter／heading chunk／draft除外、SHA差分同期・削除・offline cache、日本語自然文queryのtrigram検索、長いchunkの一致箇所周辺2,000文字excerpt、FTS route／metadata優先、最大件数、0件、AI Reply／Persona Post promptの参考資料境界とUsage metadataを`ExternalBrainTests.swift`で検証します。

Knowledge Draft Pipelineは5種のtype、6種のsource、front matter、safe slugと`drafts/`path境界、同日同名Draftの一意path、SQLite再読込後のpath維持とDraft単位削除、source外の事実を追加しないprompt、Human／AI区別、journal固有フォーマットと過去の記憶として扱う取得時ルール、ローカルFTS最大3件、0件、AI生成、`status: draft`のRetrieval除外を`ExternalBrainTests.swift`で検証します。GitHub Contents write／deleteのtoken未設定、権限、offline、同名conflict、new-file-only、保存・削除失敗時Draft保持はMac上のURLProtocol／実Repository検証対象です。

Knowledge Review & Promoteは許可された状態遷移、unreviewedからの直接Promote拒否、schema v12 Draft／Knowledge round-trip、Draft FTS、Promote metadata、Draft除外とpromoted Knowledgeの即時FTS反映を`ExternalBrainTests.swift`で検証します。Review lifecycle eventはAI Usageと分離しtoken情報を持ちません。

Knowledge Quality & Consolidationはschema v14で追加され、現在のschema v21でも完全一致duplicate、無関係Knowledgeの候補除外、stale条件、candidate dismiss、Knowledge本文不変、Archive／Supersede metadata、retrievalCount／lastRetrievedAtを`ExternalBrainTests.swift`で検証します。Quality解析とローカルMerge DraftはAI clientを受け取らないpure/local境界です。

GitHub Repository Settingsは設定modelのCodable round-trip、secret fieldを持たないこと、Draft／Knowledge pathのdomain正本、401／403／404とrate limitの分類、AIプロフィールの接続状態で実接続成功時だけverifiedになることを`ExternalBrainTests.swift`で検証します。UserDefaults復元、Keychain保存・置換・削除、既存GitHub clientへの同一設定反映、GETだけの実接続確認、プロフィール上の緑ライトと最終確認日時はMac上のapp integration検証対象です。

AI API Usage Analyticsは`AIAPIUsageTests.swift`で現在のschema v21における保存・再読込、Knowledge Draft source type、success／failure／cancel／retry、Persona有無、External Brain有無、character、実測tokenのnil保持、Latency、Error分類、今日／7日／30日／全期間と各dimension、本文系columnを持たないprivacy、Telemetry書込失敗時の生成結果維持を検証します。v13なのに追加列が欠けた既存DBを構築し、起動時の非破壊補修、該当SELECT、再実行可能性も検証します。加えて、最新versionを名乗りながら旧Relation制約を持つDBのv15自動補修と、必須table欠落をhealth checkが拒否することを検証します。生成requestについてはPersona系の`concisePersona`／low／1,024 token、Daily SummaryのOpenAI／`dailySummary`／medium、Knowledge Draftの`knowledgeDraft`／mediumが固定されることをCore testで確認します。

## UI Test

`AiTextAppUITests`はHome／Mentions／AI機能／Insights／Profileの5タブ、Home上部の本文検索とDetail遷移、Home Composerの投稿、メンションメニュのAI Persona選択による`@handle`本文挿入、Thought本文コピー操作、MentionsのMention／Replyセグメント分離とHome共通行表示、AI機能のペルソナ／使用状況／外部ブレイン入口、AIプロバイダー設定からGemini／OpenAI／Claude各詳細への入口、`@mio`の自動返信、Conversation表示、最新leafへの通常返信、Homeで返信2件目以降が初期非表示となることと全件表示への切替、Insightsのサマリー閲覧専用ページ・Daily Summary生成・Analytics入口、共通Profile表示、Profile右上から一般Settingsへの導線を検証します。Thoughtに紐づくタグ、Continuation、Daily Summaryなどの主要flowも維持します。

Theme UI testは4テーマを順に選択し、Home／Mentions／AI機能／Insights／ProfileとTab Barの各組み合わせをScreenshot attachmentへ保存します。最後に再起動して選択状態が維持されることを確認します。AI Thought固有Surfaceは共通`ThoughtRow`のactor kind分岐だけで適用し、本文自体へGlowを付けないことをコードレビュー対象とします。

ローカル分析UIは「Timelineで1件投稿 → 分析を開く → 今日／7日／30日／活動日／活動日平均 → 日別カレンダーの今日が1件」をXCUITestで確認します。日別カレンダーの配置・濃淡・今日の枠線、locale曜日、時間帯、タグEmpty State、Continuation説明はSimulatorで目視とVoiceOver確認も行います。

```bash
xcodebuild -project AiTextApp.xcodeproj -scheme AiTextApp \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' test
```

キーボード表示、140文字、複数件、Dynamic Type、Light/Dark mode、VoiceOver label、Share Sheet保存先に加え、メンション付きThoughtのAI返信プレビュー／送信／生成中disable／Detail返信表示、AI要約の送信確認／loading／失敗／再試行／Mock表示／再要約、Files／iCloud Drive picker、Restore後の再起動をSimulator／実機で手動確認します。

Knowledge DraftはAI Reply／Persona Post／Daily Summaryの各導線、type選択、生成前非通信、編集可能Preview、保存予定path、関連資料、GitHub保存の明示操作、失敗後の内容保持と再試行、保存後の手動sync、Usage Dashboardの`Knowledge Draft`表示を確認します。

## Build

```bash
xcodebuild -project AiTextApp.xcodeproj -scheme AiTextApp \
  -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation)' build
```

最新標準iPhone名は`xcrun simctl list devices available`で確認してdestinationへ指定します。

## Firebase Integration / Device

Daily SummaryはThoughtがある日／ない日、要約済み状態、過去月移動、送信前payload、構造化各Section、再起動後の復元を確認します。要約済みの日は再生成ボタンから同じPreviewへ進み、失敗時は旧Summaryを保持し、成功時だけ同日の1件を置き換えることを確認します。実通信ではJSON応答が保存され、タグ／Thought／Continuationが変更されないことを確認します。

日記はDaily Summaryの日別画面で、要約の有無にかかわらずHuman Thoughtがある日に「日記を作る」が有効になり、選択日付のjournal Draftプレビューが開くことを確認します。閲覧は振り返りの独立した日記カレンダーを開き、日記のある日だけ識別表示されること、GitHub同期済みの同日journal本文・状態・pathだけが日別詳細に表示されること、カレンダーから同期できることを確認します。デイリーサマリー／日記カレンダーの月・曜日・日付が日本語であること、日記Markdownの見出し・箇条書き・引用・強調が本文を変更せず読みやすく描画されることをSimulatorで目視確認します。

Promote元の`status: draft`と、日付・title・本文が一致する`status: active`が同期cacheに共存する場合、日記閲覧にはactiveだけを返すことをUnit Testで確認します。内容が異なる未正式化Draftは除外しません。

XcodeでFirebase package resolveとapp targetのcompileを行った後、Debug Providerを登録したSimulator、App Attestを登録した実機の順で明示送信を確認します。成功時のSQLite provider／model、未設定plist、未登録Debug token、App Check拒否、offline、429／quota、その他API、空応答を確認します。Console設定や実APIを必要とする検証は通常のUnit Testへ組み込みません。

OpenAI直接接続は個人所有実機だけで確認します。設定画面でAPI keyの未設定／保存済み／削除状態、Keychain保存後の再起動、401／403、429、offline、空応答を確認します。Persona Post／手動Reply／自動ReplyはPersonaで選んだGemini／OpenAIとlow、Daily SummaryはOpenAIとmedium、Knowledge Draftは設定したProviderとmediumが実応答・Usageへ反映されることを確認します。API keyそのものをテストfixture、Screenshot attachment、ログへ含めません。TestFlight／App Store用archiveの検証前には、直接接続をバックエンド方式へ置き換えることを確認します。

## General Checks

Windowsで実装済み・Mac未検証の蓄積と一括実施順は`MAC_VALIDATION.md`を参照します。

2026-09-14時点の最新Mac検証では、`ThoughtCore/ExternalBrain.swift`のSwift 6.3型推論errorによりtest実行前のcompileで停止します。過去の全140件成功は週間振り返り追加前のbaselineであり、blocker解消後に最新件数と結果を更新します。

Apps / Tools Hub追加分の検証状態は、**Windowsで実装済み／Mac/Xcode compile未確認／Swift Testing未実施／実機確認未実施**です。Macでは既知compile blocker解消後、全Package test、schema v20→v21 migration、既存機能回帰を一度だけ実行します。

```bash
git diff --check
git status --short
git ls-files
```
