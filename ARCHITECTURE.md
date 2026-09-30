# Architecture

SecondBrainの現行iOS実装では、HumanとAI Personaを`Persona`（公開上は`Actor` alias）という単一モデルで扱います。不変UUIDを参照キー、変更可能な一意`handle`を表示用IDとし、Mentionは本文とは別にActor ID、投稿時handle snapshot、UTF-16範囲を保存します。Replyは`thought_relations.repliesTo`、Continuationは`thought_relations.continues`で独立して表現します。

この文書は将来構想ではなく、2026-09-30にコードと照合した実装済み構成を記録します。Apps / Tools HubはDomain／Persistence／Default Catalog／3列タイルUI／起動処理までを現在構成として扱い、未実装の編集UIは`NEXT_FEATURES.md`へ分離します。

## System Overview

```text
SwiftUI App -> MainTabView -> Home / Mentions / AI機能 / Tools / Profile
  Home (TimelineView) -> ThoughtDetailView / Continuation Composer
  MentionsView -> Mention・Reply一覧 -> ThoughtDetailView
  AI機能 -> Persona / Provider / Usage / External Brain / Knowledge
  振り返り -> Daily Summary / Weekly Review / Journal / Thought Analytics
  Home -> 振り返り
  Tools -> SecondBrainApp catalog -> Native route / openURL
  ProfileTabView -> ActorProfileView -> SettingsView
  SettingsView -> AIAPIUsageAnalyticsView -> LoadAIAPIUsageAnalytics
  -> ThoughtStore (presentation state)
    -> ThoughtTimeline (validation/order/delete use cases)
      -> ThoughtRepository / ThoughtTagRepository / PersonaRepository protocols
        -> SQLiteThoughtRepository (Application Support SQLite)
      -> ThoughtContinuationRepository (Thought + Relation transaction)
    -> ThoughtRelationRepository (History relation queries)
    -> LoadThoughtAnalytics -> ThoughtAnalyticsRepository (read-only SQLite aggregates)
    -> PrepareDailySummary / GenerateDailySummary -> ReviewSummaryClient / DailySummaryRepository
    -> AIAPIUsageRecorder -> AIAPIUsageRepository（best-effort metadata）
    -> ExternalBrainManager -> GitHub read-only API -> Local Markdown Cache -> SQLite FTS5 -> AI Reply Preview
    -> GenerateKnowledgeDraft -> editable Preview -> ExternalBrainDraftWriter -> GitHub drafts/ new-file-only
    -> ThoughtExporter -> ThoughtRepository
    -> ShareSheet (UIActivityViewController)
    -> ExternalBackupManager -> ExternalBackupService / RestoreCoordinator
```

## Technology Stack

- Swift 5 language mode、SwiftUI、Combine、Foundation。
- iPhone / iOS 16.0以降。Firebase Apple SDK（FirebaseCore／FirebaseAILogic／FirebaseAppCheck）はGemini用としてapp targetだけが依存し、ThoughtCoreはSDK非依存。
- Xcode projectと、CoreのLinuxテストにも使うSwift Package。

## Main Components

- `AppTheme` / `ThemeController` / `ThemeHost`: raw color・radius・durationのPrimitive、用途別Semantic、4種のTheme preset、画面強度とReduce Motionを解決するEffect境界を分離する。選択はUserDefaultsへ保存し、全5タブは同じView構造のままEnvironmentのresolved tokenを消費する。常駐Effectは少数のSwiftUI Shape、静的な決定論的star、transform／opacity中心の長周期animationに限定する。

- `MainTabView`: 標準`TabView`でHome／Mentions／AI機能／Tools／Profileの5つの主要導線を構成し、タブごとの`NavigationStack`とHomeのTimeline状態を保持する。振り返りはHome右上のNavigationLinkから開く。
- 投稿成功Navigationは`ThoughtStore.PostNavigationRequest`へ集約する。Rootの`MainTabView`がHomeを選択して各タブのNavigation rootを再生成し、`TimelineView`が作成されたThoughtへスクロールして短時間ハイライトする。キャンセルや生成・保存失敗では成功イベントを発行せず、現在のSheetと入力を保持する。
- `TimelineView`: Home専用。右上の鉛筆から開く投稿Composer、投稿者フィルター、Lazy Timeline、Detail、相対日時、操作メニュー、削除確認、Empty State、エラー表示。検索・振り返り・設定の重複Toolbar導線は持たない。
- `MentionsView`: 保存済みMention relationと`repliesTo` relationから、Human／AI Persona宛ての受信項目を新しい順で表示する。
- `SearchTabView`: 現在はThought本文検索を提供し、将来Persona／Tag／Knowledge検索を追加できる独立タブ境界。
- `InsightsContentView`: Home右上から開き、Daily Summary Calendar、週間振り返り、Thought Analyticsをまとめる分析ハブ。
- `ToolsView`: `SecondBrainAppRepository`から読み込んだcatalogを3列の正方形タイルで表示する。Nativeは閉じたfeature route、Web／Local Web／ExternalはSwiftUI `openURL`へ渡し、OSが受理しない場合は画面内Alertを表示する。
- `WeeklyReviewListView`／`WeeklyReviewDetailView`: 完了した暦週（月曜〜日曜）を選び、Human Thought限定の週間サマリーを送信前確認後に生成する。次週プランは保存済みSummaryを入力に別AI callで候補生成し、編集・明示確定まで永続化しない。
- `ActorProfileView`: Human／AI共通のプロフィール表示。自分のProfileタブでは編集とSettingsへのToolbar導線を追加する。AIではPersona別External Brain設定、Repository、Keychain token、同期済みAGENT cacheをローカル評価し、明示GET確認が成功した場合だけ接続済みの緑ライトを表示する。
- `ThoughtAnalyticsView`: 直近30日の基本サマリー、日別／曜日別／時間帯別分布、上位タグ、Continuation件数を標準SwiftUIの縦Sectionと簡易バーで表示する完全ローカル画面。
- `AIAPIUsageAnalyticsView`: 今日／7日／30日／全期間のAI Call、成功率、文字数または完全な実測token、Feature／Persona／Provider・Model／Error、Latency、External Brain、日別推移をSQLiteだけで表示する。
- `AIProviderSettingsView`: Gemini／OpenAI／Claudeのプロバイダー別設定入口。Geminiはbundle内のFirebase設定、OpenAIはKeychain itemの有無をローカル評価し、緑ライトは設定検出だけを意味する。API疎通済みとは扱わず、生成経路を持たないClaudeは未対応表示に固定する。OpenAI secretの保存・置換・削除は`OpenAIProviderSettingsView`だけが`ThoughtStore`経由で行う。
- `DailySummaryCalendarView`: 月単位で要約済み／Thoughtあり未要約／Thoughtなしを表示し、日別詳細と明示生成の送信前プレビューへ遷移する。
- `DailySummaryContent` / `PrepareDailySummary`: `fetchHumanThoughts(from:to:)`から期間内・未削除のHuman Thoughtだけを取得し、Humanタグ、共通時間帯、Human同士の日内Relationをtyped previewへ固定する。AI本文は取得・prompt化せず、新規v3応答の`aiInteractions`も保存前に空へ矯正する。v1／v2保存JSONは後方互換decodeし、将来のAI Summaryは別model／画面の責務とする。
- `DailySummaryThoughtTagSuggestion`: AI応答のprompt連番をPreview内のHuman Thought IDへ検証付きで解決する提案モデル。生成時はTagを変更せず、Detailの明示的な追加操作だけが既存Tag repositoryを呼ぶ。
- `ReviewSummaryClient`: Gemini用Firebase AI Logic clientとOpenAI用直接Responses API clientを`AIProvider`でrouteする通信境界。通常起動はprovider router、UIテスト／CoreテストはMockを使用する。`AIGenerationProfile`が用途別の思考量と最大出力を一元管理し、providerとともに生成requestへ固定する。Persona投稿／手動返信／自動返信はPersonaのproviderと`concisePersona`（low／1,024 token）、Daily SummaryはOpenAI固定の`dailySummary`（medium／8,192 token）、Knowledge DraftはSettingsのproviderと`knowledgeDraft`（medium／4,096 token）を使う。
- `ReviewSummaryGeneratingTransport`: Firebase SDK importをapp layerへ閉じ込め、request変換、応答変換、空応答、typed errorを外部通信なしでテストする境界。
- `ThoughtDetailView`: 選択Thoughtの投稿者・本文・タグと、`continues`／`repliesTo`を統合したConversation Treeを表示する。通常の「返信を書く」は全Conversationの最新leafへ接続し、選択した過去Thoughtへの返信は「この投稿から返信を分岐」で明示する。タグ、Knowledge Draft、削除は`…`へ分離する。
- `ThoughtStore`: Timeline／本文検索／タグ／Continuation draftとHistory画面状態を各use caseへ接続。
- `ThoughtTimeline`: 投稿validation、日時降順sort、50件単位のTimelineページ状態、soft delete、保存の調停。
- `Thought` / `ThoughtDraft`: 原文モデルと140文字ルール。
- `Persona` / `PersonaRepository` / `AuthoredThoughtRepository`: 人間／AIに共通する投稿者モデル、複数Personaの管理、任意Persona IDとThoughtを同一transactionで保存する境界。固定IDの人間Personaは無効化できない。
- `AIPersonaConfiguration` / `GenerateAIPost`: Personaごとの役割・指示、ユーザー依頼からimmutableな送信前previewを作り、明示確定後の応答だけをAI名義で投稿する。140文字を超える応答や空応答は保存しない。
- `AIThoughtReplyPrompt` / `GenerateAIThoughtReply`: Reply先から解決したAI、対象Thought、直近Reply chain、Persona設定、同Personaの直近発言、任意のExternal Brainからimmutable requestを作る。モデル応答はまず未保存`AIThoughtReplyDraft`として返し、手動AI返信では「AI返信の確認クッション」がONならHumanの「投稿する」後、OFFなら生成直後にAI名義Thought、`repliesTo` Relation、reply生成来歴を同一transactionで保存する。設定はUserDefaultsへ保存し、既定はOFF。Humanの@メンションで起動するPersona AI自動返信は確認を挟まず生成・投稿する。
- `ExternalBrainCache` / `ExternalBrainIndex` / `ExternalBrainRetriever`: 単一GitHub RepositoryのMarkdownをSHA差分同期し、front matterを解析してheading単位に分割した派生cacheをSQLite FTS5で検索する。PersonaのAGENT.mdからrouteとrulesを解決し、最大5件をAI Replyまたは独立Persona Postの参考資料としてimmutable previewへ固定する。Personaを持たないDaily Summaryにはrouteしない。
- `ExternalBrainManager` / `GitHubExternalBrainRemote`: Repository設定とPersona別設定、同期状態を管理するapp層。GitHub tokenはKeychainへ保存し、GitHub APIはtree／contentsのGETだけを使う。
- `KnowledgeDraft` / `GenerateKnowledgeDraft`: AI Reply、Persona Post、Daily Summaryを明示操作後に再利用可能なMarkdown候補へ変換する。ローカルFTSの関連候補は最大3件で追加AI Callを使わず、生成Usageだけを`Knowledge Draft`として記録する。
- `KnowledgeDraftRepository` / `KnowledgeDocument`: Draftと正式Knowledgeを分離し、Review状態、provenance、GitHub metadataをschema v12へ保存する。Draft専用FTSはtitle／body／tags／sourceを検索し、正式KnowledgeはPromote後のread-only snapshotとして保持する。
- `KnowledgeQualityAnalyzer` / `KnowledgeQualityCandidate`: active Knowledgeをローカル比較し、duplicate／similar／stale候補だけを生成する。candidateのopen／resolved／dismissedはKnowledge本文・状態と独立し、解析はAI APIを使わない。
- Knowledge usage policy: AI Reply／Persona Post retrievalで取得された正式pathをSQLiteへbest-effort記録する。activeだけを集計し、Archive／Supersedeの明示操作時はローカルExternal Brain indexから除外する。
- `ExternalBrainDraftWriter` / `GitHubExternalBrainDraftWriter`: read境界から分離したwrite専用境界。アプリ側で`drafts/YYYY-MM-DD-safe-slug.md`を生成し、GitHub Contents APIでshaなしの新規作成だけを許可する。同名、権限、network失敗時はPreviewのDraftを保持する。
- `AIReplyContextRepository`: 対象から`repliesTo`だけを逆向きに辿り、削除済み本文を除いた直近最大5件を投稿者付き・古い順で返す。PreviewはThought・Relation・Personaを固定し、生成直前の再取得結果と異なる場合は通信前に中止する。
- `ThoughtMention` / `ThoughtMentionRepository`: Thought本文の文字列解析ではなく、ThoughtとAI Persona IDの単一メンション関連をatomic保存・一括取得する。メンション作成自体はAI clientを呼ばない。
- `ThoughtRepository`: create、全Timeline query、作成日時・UUIDをcursorにするTimeline page query、literal部分一致検索、日付範囲query、ID取得、全件取得、soft deleteの保存境界。
- `ThoughtTag` / `ThoughtTagRepository`: Thought原文から独立したタグ、正規化、付与・解除transaction、Thought別／全タグ／タグ別Thought queryの境界。
- `ThoughtAnalytics` / `ThoughtAnalyticsRepository`: typed集計結果、Calendar由来の日／時間帯境界、SQLite集計専用read境界。CRUD RepositoryやAI通信から分離する。
- `SecondBrainApp` / `SecondBrainAppRepository`: Apps / Tools catalogの独立DomainとCRUD境界。不変UUID、表示情報、`SecondBrainAppKind`、分離した`SecondBrainAppLaunchTarget`、お気に入り、表示順を持つ。ThoughtはApp項目に含めずCoreとして維持する。生成時にHTTPS、Local Webのlocal host、危険scheme、kind／target整合性を検証する。
- `ThoughtRelation`: Thought本文から独立した文脈モデル。sourceは新しいThought、targetは元のThoughtで、`continues`と`repliesTo`を区別する。
- `ThoughtRelationRepository`: Relation作成、source／target方向の1ステップ取得境界。
- `ThoughtContinuationRepository`: 新規Thoughtと`continues` Relationを同一transactionで作成する境界。
- `LoadConversationThread`: 現在Thoughtから両Relationを遡ってrootを求め、全node／edge、選択地点までのcurrent path、leaf、最新leafを再構築する。`ThoughtHistory`は旧Continuation表示との互換用に保持する。
- `SQLiteThoughtRepository`: schema v22、Thought／Persona／Mention／Tag／Relation／AI生成情報／Persona別Auto Reply・Provider／Daily Summary／Weekly Summary／Weekly Plan／Apps catalog／AI Usage metadata、Knowledge Review／Quality／usage metadataとDraft FTS query、旧JSON importと2世代backupを所有する正本実装。`secondbrain_apps`は既存domain tableへの外部キーを持たず、v20→v21で空tableとして追加する。v21→v22ではDefault Catalogの適用済みApp IDとcatalog versionを保持する`secondbrain_default_app_seed_history`を追加する。履歴にはApp tableへの外部キーを付けず、ユーザーがDefault Appを削除しても再生成しない。version値だけでなく実table／column／Relation制約を照合し、安全に補修可能な不足列、旧Relation制約、旧`account_id`単独UNIQUE制約は非破壊で補修する。旧PersonaはGeminiへ移行する。旧期間要約tableは既存データ互換のため維持する。
- `ThoughtExporter`: Repositoryから未削除Thoughtを取得し、Markdown／JSONを生成。
- `ShareSheet`: ExportファイルをiOS標準共有UIへ渡すUIKit bridge。
- `ExternalBackupManager`: Filesフォルダpicker、security-scoped bookmark、バックアップ状態と確認UIのpresentation境界。
- `ExternalBackupService`: RepositoryのOnline Backup snapshotを外部フォルダへmanifest付きで作成・検証し、`latest`／`previous`をtransaction的に回転。
- `RestoreCoordinator`: 選択世代をApplication Supportへstageしてpending化し、次回起動のRepository生成前に検証・置換・rollbackする境界。

## Data Flow

Timeline入力はBindingで140 Character以内に制限し、投稿時に前後空白を除去します。投稿とMention relationを先にatomic保存してTimelineへ即時反映し、activeかつ自動返信ONのAI Personaだけを非同期生成します。Human mentionは生成せず、AI生成Thoughtから自動生成を開始しません。生成中／失敗は元Thought配下の一時UI stateとして表示し、成功時は通常Thought、author、`repliesTo`、生成metadataを既存transactionで保存します。同じ対象にはPersona単位で一度だけ返信でき、複数AIの各1返信を許可します。

Timelineは`ScrollView`と`LazyVStack`で構成します。初回はSQLiteから最新50件だけを取得し、HomeまたはMentionsの末尾が表示された時点で次の50件を追加します。SQLite queryは`thoughts_timeline_idx`に沿った作成日時・UUIDの降順と、最後に取得したThoughtを基準にするkeyset cursorを使います。次ページの有無は51件目の存在だけで判定し、件数取得や全件読込、深い`OFFSET`を行いません。Home右上の鉛筆アイコンから投稿Composerをsheet表示し、入力欄へ自動focusします。Navigation barの投稿ボタンは有効な文字入力時だけ有効になり、投稿成功時だけsheetを閉じます。行は本文を主役にし、日時と削除メニューを補助情報として表示します。

Thought DetailはrootからContinuationをdepth-firstで並べた静かな縦型Historyです。現在位置を控えめな背景とlabelで示し、削除済みThoughtはRelationを切らず「削除されたThought」と表示します。Continuation成功後は新Thoughtを現在位置にし、同じThoughtをTimelineにも即時反映します。

振り返りUIはDaily Summaryへ統一します。Calendarの日境界で1日を開始inclusive／終了exclusiveとして扱い、月カレンダーから過去日の日別Thought、既存タグ、Continuation件数、保存済みSummaryを確認します。生成は送信前プレビューを経由し、確認後に対象が変わった場合は送信しません。

ローカル分析は今日を含む直近30暦日を固定対象にします。Coreが端末Calendar／timezoneから30個の日境界と各日の0／6／12／18時境界を生成し、SQLiteは境界CTEへactive ThoughtをLEFT JOINして日別・時間帯別に`COUNT`／`GROUP BY`します。曜日分布は日別集計だけをCalendar weekdayへ畳み込み、ViewへThought原文全件を渡しません。タグは期間内active ThoughtをJOINして件数降順・正規化名・ID順の上位5件、Continuationは期間内のactiveな親子が持つ`continues` Relationの親distinct件数です。集計はSELECTだけでbackupやDB更新を行いません。

Thought検索はtrim後の空文字をUI stateで初期状態として扱い、非空文字だけを`ThoughtRepository.search(query:)`へ渡します。SQLite実装は`%`、`_`、escape文字をliteralへescapeしたbind parameterを`LIKE ... ESCAPE`へ渡し、`deleted_at IS NULL`で絞って作成日時・UUIDの降順で返します。SwiftUIはSQLを知らず、将来FTSへ移行する場合もRepository実装を差し替える境界です。検索はread-onlyでbackup作成を含むDB更新を行いません。

タグは表示名を前後trimしてUnicode正規合成し、POSIX localeの小文字表現を`normalized_name`として一意化します。Thought Detailからの追加は、タグの`INSERT OR IGNORE`と`thought_tags`付与を同一transactionで行います。解除も中間行だけをtransaction内で削除し、Thought本文とタグmasterは変更しません。Timeline／本文検索は本文queryと分離したタグ取得を表示に合成し、タグ絞り込みは`ThoughtTagRepository`の独立queryを使います。

Daily SummaryはHumanの概要・テーマ・思考、既存Humanタグ別、任意の時間帯InsightをThought原文と別に1日1件保存します。SQLiteはThought・投稿者Relation・PersonaをJOINしてHumanだけを一括取得し、AI本文をCoreへ渡しません。Preview後も同じHuman限定queryで本文・時刻・投稿者・タグ・Human同士の日内Relationを再取得し、一致したpayloadだけを明示送信します。未要約日と要約済みの過去日は同じPreview／生成境界を使い、再生成の通信・decode・保存前検証に失敗した場合は旧Summaryを保持し、成功時だけ`day_start`単位のupsertで置き換えます。prompt versionはv3で、既存`content_json`と保存済みv1／v2 Summaryを維持するためDB migrationはありません。

## Persistence

`Application Support/ExternalBrain/files`、`manifest.json`、`index.sqlite3`はGitHub Markdownを正本とする削除・再生成可能な派生データです。Thought DBと外部完全backupには含めません。

日記閲覧は同期済み`type: journal`を対象とし、日付・title・本文が一致する`active`と`draft`が共存する場合はPromote後の`active`だけを表示する。別内容のDraftは正式化前の日記として表示を維持し、表示上の重複排除ではGitHubファイルを削除しない。

Knowledge Draftは生成成功時にReview用SQLiteへ永続化し、編集可能Previewでも保持します。Humanが明示的に保存した場合だけGitHubの`drafts/`へ新規作成し、既存fileの更新・削除は行いません。`status: draft`により同期後も通常Retrieval indexから除外されます。正式KnowledgeへのPromote、Archive、Supersedeもそれぞれ独立した明示操作です。

schema v9の`personas`と`thought_authors`は既存Thoughtを固定のデフォルト人間Personaへ移行し、新規Thought／Continuationの作成と投稿者関連を同一transactionで保存します。`ai_post_generations`は生成種別と返信先Thought IDも保持し、`thought_relations`はContinuationとAI返信を区別します。`thought_mentions`は投稿とAI Personaの関連を保存します。

`Application Support/ThoughtTimeline/thought-timeline.sqlite3`が正本です。日時はUnix epoch秒の`REAL`、UUIDは`TEXT`で保存し、削除は`deleted_at`を設定するsoft deleteです。schema v9はPersona、AI設定・生成来歴、メンション、`continues`／`repliesTo` Relationを保持します。既存の独立AI投稿は`standalone`として移行し、返信は`reply`と返信先IDを保存します。soft deleteでは中間行を保持し、通常queryがdeleted Thoughtを除外します。

初期化成功後とcreate／soft delete成功後にSQLite Online Backup APIでスナップショットを作り、`.backup.1`と`.backup.2`だけを保持します。バックアップ失敗は成功済み投稿を失敗扱いにせずログへ記録し、破損時の自動巻き戻しは行いません。

Repository初期化はmigration後、バックアップ更新前に`PRAGMA quick_check`、`PRAGMA foreign_key_check`、必須table／column、`thought_relations`の`repliesTo`対応制約を検査します。`user_version`が最新でも実schemaが不整合なら検知します。schema v18は過去版の`personas.account_id`単独UNIQUE制約をindex実定義から検知し、Foreign Keyを一時停止したtransaction内でPersona IDと内容を保持したままtableを再構築します。`account_id`は単一ローカルアカウントへの所属情報であり、デフォルトHumanと複数AIで共有できます。Actor handleは引き続き`COLLATE NOCASE`のグローバルUNIQUEです。安全な既知パターンだけをmigrationで補修し、それ以外の欠落・破損は正本DBを上書きせず初期化を中止して、Consoleに詳細、UIに削除せず復元する案内を表示します。

外部完全バックアップは選択されたFilesフォルダ配下の`AiText Backup/latest`と`previous`に、SQLite全体と`manifest.json`を保存します。作成中はUUID付き一時directoryを使い、integrity、schema、サイズ、SHA-256を検証できた新snapshotだけをlatestへ切り替えます。Restoreは外部ファイルを直接正本にせずApplication Supportへcopy・再検証してpendingにし、次回起動時にSQLite connection生成前に正本・WAL・SHMをrollback用へ退避して適用します。適用後のSQLite確認が失敗すれば元の組を戻します。

## External Services / Authentication

application composition rootはローカル`GoogleService-Info.plist`を検証し、DebugではApp Check Debug Provider、ReleaseではApp Attest Providerを設定してからFirebaseを初期化します。App Attest entitlementはRelease configurationだけに付与し、Personal Teamを使うDebug実機buildでは要求しません。Git管理外のルート`GoogleService-Info.plist`は存在する場合だけapp bundleへcopyし、未配置でもbuildと起動を継続します。GeminiはFirebase AI Logicから`gemini-3.7-flash`を呼び、requestのgeneration profileを`ThinkingConfig`と`maxOutputTokens`へ変換する。OpenAIは個人所有端末限定の暫定運用として、Settingsで入力したAPI keyを`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`のKeychainへ保存し、Responses APIの`gpt-5.6-luna`を`store: false`で直接呼ぶ。Responses requestにはprofile由来の`reasoning.effort`と`max_output_tokens`を明示する。キーはUserDefaults、SQLite、Export、backup、ログ、Gitへ含めない。ただしKeychainはサーバー側Secretと同等の防御境界ではないため、TestFlight／App Store／第三者配布を開始する前に直接通信を廃止し、認証・濫用防止を備えたバックエンドとSecret管理へ移行する。実応答のprovider／modelを保存メタデータへ渡し、Firebase未設定、OpenAI key未設定／認証失敗、App Check、rate limit、network、その他APIをtyped errorへ分類します。Files／iCloud DriveアクセスにはiOS標準document pickerとsecurity-scoped bookmarkだけを使います。
## GitHub Repository Settings

External Brainのowner／repository／branchは`ExternalBrainManager`が既存UserDefaults keyへ保存し、Read、sync、Draft new-file-only保存、Promoteの全経路が同じ設定を参照する。PATは`ExternalBrainTokenStore`だけがKeychainへ保存し、UserDefaults、SQLite、Markdown、Usageへ渡さない。接続確認は既存`GitHubExternalBrainRemote`によるGETだけでAuthentication、Repository、Branchを検証し、repository permissionsのpush値からDraft／Knowledge capabilityを推定する。接続確認は設定保存とは独立し、失敗しても設定とローカルKnowledgeを保持する。

AI Personaプロフィールの接続チェッカーはAI生成clientを呼ばない。未確認時はPersona有効化、AGENT path、Repository、Keychain token、同期済みcacheだけを端末内で判定し、明示確認時はRepositoryとBranchの2 GETだけを行う。Repository応答自体で認証とread権限を確認できるため、独立した`/user`照会は行わない。緑表示は直近の明示確認でAuthentication／Repository／Branchがすべて成功し、そのPersonaのAGENT.mdも同期済みの場合に限定する。GitHubだけ確認できてAGENT.mdが未同期なら同期が必要な橙表示とし、設定またはtoken変更時は確認結果と日時を破棄する。

## Current Product Boundary

現行実装が外部通信するのは、Gemini用Firebase AI Logic / App Check、OpenAI Responses API、External Brain／Knowledge用GitHub APIです。Files／iCloud Driveはユーザーが選択した保存先へのBackup / Restoreに利用します。独自バックエンド、利用者アカウント、クラウド同期、Claude生成はまだ存在しません。

Apps / Toolsは`SecondBrainApp`、Repository境界、schema v21の`secondbrain_apps`、schema v22のDefault Catalog適用履歴、SwiftUIの3列タイル画面、Native route resolution、外部URLを開くapp layerまで実装済みです。Default Catalog v2は固定UUIDのShared Memo／My Wiki／Study／Study App／Toolを新規・移行DBへmissing-onlyで登録します。v1適用済みDBには新しいStudy Appだけを追加します。同じIDの既存Appは変更せず履歴だけを記録し、適用済みAppの編集を上書きせず、削除後も再生成しません。catalog versionは追加時点を履歴へ保存します。Preview／test fixtureはDefault Catalogと分離しています。Catalog編集UI、到達確認、WebViewは未実装です。App間データ共有、AIによるApp操作、Context連携はv1の範囲外です。
