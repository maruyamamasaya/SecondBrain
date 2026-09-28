# Current Project Status

最終照合日: 2026-09-28

## Project

`SecondBrain`は、Thoughtを中核にAI Persona、振り返り、Knowledge、External Brain、Apps / Toolsへの入口を統合する個人用AIワークスペースです。現行実装は`AiTextApp_iOS`リポジトリ内のSwiftUI製iPhoneアプリ`AiTextApp`と、Core package `ThoughtCore`です。Apps / Tools HubはDomainとSQLite永続化までWindowsで実装済みで、UIと起動処理は未実装です。

## 現在のフェーズ

Thought、AI Persona、Daily／Weekly Review、Knowledge、External Brain、Apps / Tools HubのDomain／Persistenceまでコード実装済みです。SQLite schemaはv21です。2026-09-13時点ではSwift Testing全140件とgeneric iOS Simulator向けDebug buildに成功しました。その後追加した週間振り返りv1と日記のDraft／active二重表示修正は、2026-09-14のMac/Xcode 26.6検証で`ThoughtCore/ExternalBrain.swift`のSwift 6.3型推論compile errorによりtest／buildへ到達できていません。Apps / Tools Hub追加分もWindows実装のため未compileです。

### 現在の検証blocker

- `ExternalBrainCache.journalEntries()`内の`compactMap`で要素型を推論できず、Swift 6.3 compileが失敗する。週間振り返りtest、schema v20 migration確認、日記重複表示test、Simulator UI確認は未完了。
- 最新の検証手順と記録は`MAC_VALIDATION.md`および`sessions/2026-09-14-weekly-review-v1.md`を正本とする。このblockerを解消して検証baselineを回復するまで、最新追加分を「テスト済み」と扱わない。
- Apps / Tools Hub v1: **Windowsで実装済み／Mac/Xcode compile未確認／Swift Testing未実施／実機確認未実施**。

## 実装済み

- Apps / Tools Hub v1のDomain／Persistence基盤。`SecondBrainApp`はUUID、名前、説明、icon、kind、launch target、category、お気に入り、表示順、作成・更新日時を持つ。Native／Web／Local Web／Externalと起動先を分離し、HTTPS、local HTTP、危険scheme、kindとの組み合わせをDomainで検証する。schema v21の独立`secondbrain_apps` tableへCRUDを保存し、Thought関連tableとは関係を持たない。HomeMuseum／Baby Media／GitHub Monitorはtest fixtureだけにあり、本番DBへ自動登録しない。UIとURL起動は未実装。

- 日記カレンダーはPromote後もGitHubに保持される元Draftと正式版を二重表示せず、日付・title・本文が一致する`active`日記を優先する。別内容の未正式化Draftは引き続き表示し、GitHub上のファイルやKnowledge Review履歴は変更しない。

- 週間振り返りv1。完了した月曜〜日曜のHuman Thoughtだけを対象に、`gpt-5.6-terra`／medium／最大8,192 tokenで週間サマリーを明示生成する。過去の理解と次週の意思決定を分離し、次週プランはTerra／low／最大4,096 tokenで候補を作り、ユーザーが編集・確定した場合だけ保存する。schema v20の独立tableへ週単位で保存し、サマリー再生成成功時だけ同週を置換し、確定済みPlanは自動変更しない。振り返りの週間入口とサマリー閲覧一覧へ接続済み。

- デイリーサマリーなどから作るGitHub下書きの保存名に永続UUIDを追加。同日・同タイトルでも別下書きは衝突せず、保存済みの旧pathは維持する。既存ファイルの上書き禁止は継続する。未昇格Draftは詳細画面の確認付き削除から消せる。GitHub保存済みの場合はGitHub上のファイル削除に成功してからローカル記録も削除し、失敗時はローカル記録を保持する。
- Daily Summaryの日別画面に「日記を作る」を追加し、その日のHuman Thoughtから日付を維持したjournal Draftを直接生成する。日記の閲覧はDaily Summaryから分離し、振り返りの独立した日記カレンダーで行う。GitHub同期済みの`type: journal`を`created`日付でカレンダーへ表示し、日別詳細で本文・状態・pathを読める。GitHub同期も日記カレンダーから実行できる。
- デイリーサマリーと日記のカレンダーは、端末言語に依存せず月・曜日・日付を日本語で表示する。日記本文はGitHub上のMarkdownを変更せず、閲覧画面で見出し、箇条書き、引用、インライン強調を読みやすい表示へ変換し、GitHub pathは折りたたんで表示する。

- AIプロバイダー設定の独立画面。AI機能タブからGemini／OpenAI／Claudeそれぞれの詳細へ進み、一覧のランプと「設定済み／未設定／未対応」の文言で状態を確認できる。OpenAI API keyの保存・置換・削除はOpenAI詳細へ移動し、既存の端末限定Keychain運用を維持する。Geminiはbundle内のFirebase設定検出、OpenAIはKeychain保存状態を表示し、どちらもAPI疎通済みとは区別する。Claudeは生成経路未実装のため設定入力を有効にせず「未対応」と明示する。
- Gemini／OpenAIのAI Provider切替と用途別生成Profile。AI Personaごとの投稿・手動返信・自動返信はPersona設定でGemini／OpenAIを選択し、両Providerとも`low`、最大出力1,024 tokenで生成する。Daily SummaryはOpenAIの`medium`、最大8,192 tokenへ固定し、Knowledge DraftはSettingsでProviderを選択して`medium`、最大4,096 tokenで生成する。個人所有端末だけへXcodeから導入する暫定運用として、OpenAI API keyは`WhenUnlockedThisDeviceOnly`のKeychainへ保存し、Responses APIへ直接送る。schema v19でPersona設定にproviderを非破壊追加し、生成開始時のprovider／model／generation profileをrequestへ固定する。TestFlight／App Store／第三者配布へ進む前に、API keyを端末から除去してバックエンド＋Secret管理へ移行する。

- Conversation中心のAI返信／投稿履歴。Human ThoughtでactiveなAI Personaを@メンションすると、元ThoughtとMentionを先に保存・表示してから各AIが自動返信する。生成中／失敗／再試行をTimelineとConversationへ表示し、失敗しても元Thoughtを保持する。AI返信は通常Thought＋author＋`repliesTo`＋生成metadataとして保存し、同一対象・同一AIの二重返信を拒否しつつ複数AI返信を許可する。
- `continues`／`repliesTo`を統合する`LoadConversationThread`を追加し、root、nodes、edges、currentPath、leaves、最新leafをDBから再構築する。Thought DetailはConversation表示へ移行し、通常返信は選択Thoughtではなく最新leafへ、過去地点への返信は`…`内の「この投稿から返信を分岐」へ分離した。会話Primary Actionとタグ／Knowledge Draft／削除などの管理操作も分離した。

- AI Persona追加を妨げていた旧`personas.account_id`単独UNIQUE制約をschema v18で非破壊補修する。旧実機DBはPersona tableをtransaction内で再構築し、Humanの`account_id`へ既存／新規AIを所属させる。Thought author、Mention、AI ConfigurationなどのPersona ID参照を維持し、handleの大文字小文字を無視した一意性は継続する。
- ユーザー向け表示の日本語化。Home／Mentions／AI機能／Insights／Profileの5タブ、各画面タイトル、テーマ、AI使用状況、GitHub接続、外部ブレイン、ナレッジ下書きの主な表示を日本語に統一した。開発ドキュメントも日本語を基本とする。
- 投稿後Navigation統一。AI機能タブの「AI返信の確認クッション」を任意でONにでき、初期値はOFF、選択は端末へ永続化する。OFFでは手動AI返信も生成からatomic投稿まで連続実行し、ONでは生成内容を確認してから投稿する。@メンションによるPersona AIの自動返信には承認を挟まない。生成・保存失敗時は画面と再試行導線を保持する。通常投稿、Human Reply、Continuation、AI Reply、Persona Postの成功は共通イベントでHome rootへ戻り、新規Thoughtを一時ハイライトする。
- AI Persona管理とPersona Post依頼を分離。AI Personas一覧は各AIのプロフィール／編集へのリンクを中心とし、投稿操作はAI機能タブの独立した「AIに投稿を依頼」画面でPersonaを選択して依頼文を入力し、既存の送信前Previewへ進む。

- UI演出プリセットとしてのTheme v1。Default／Dynamic Aurora／Pulse Neon／Blue Cosmosを`Primitive → Semantic → Theme → Effect`で解決し、Home／Mentionsは静かな強度、AI機能／Insights／Profileは強めの強度で同じ画面構造へ適用する。Profile > Settings > Appearance / Themeでライブプレビュー付き選択を行い、UserDefaultsへ永続化する。AI Thoughtは本文を発光させず専用Edge／Glowだけを加え、Reduce Motion時はambient animationを停止する。

- @ID／Mention／Reply v1。HumanとAI Personaを不変UUIDの共通Actorとして扱い、3〜30文字の一意な小文字handleを設定できる。Composerの`@`候補はHuman／AIを表示し、保存時にActor ID・handle snapshot・UTF-16範囲をschema v16のRelationへ保存する。既存`repliesTo` chain、返信先preview、Actor Profileをhandle表示へ接続し、handle変更後もRelationを維持する。

- GitHub Repository Settings v1。Settings > External Brainからowner／repository／branchを既存UserDefaultsへ、PATを既存Keychainへ分離保存し、Token置換・確認付き削除、Repository変更時のローカルKnowledge保持警告を提供する。既存GitHub Contents clientのread-only接続確認でAuthentication／Repository／Branchとpush権限由来のDraft／Knowledge capability、分類済み接続エラー、rate limit残数を表示する。各AI Personaプロフィールでも設定・同期済みcacheをローカル判定し、明示的なGET接続確認に成功してPersonaのAGENT.mdも同期済みの場合だけ緑ライトと最終確認日時を表示する。接続確認はAI APIを呼ばず、不要なGitHub `/user` 照会も行わない。Draft／Knowledge pathはdomain定義をread-only表示する。
- Knowledge Quality & Consolidation v1。正式Knowledgeを手動ローカル解析し、正規化title／body一致、本文token類似度、tag重複からDuplicate／Similar候補を、180日未更新かつ未参照からStale候補を提示する。Quality画面でCompare、Dismiss、A/Bを並べたMerge Draft作成を行い、既存Review／Promoteへ戻す。明示操作だけでArchive／Supersedeし、対象pathを通常Retrieval indexから除外する。active KnowledgeのretrievalCount／lastRetrievedAtを記録し、単一のブラックボックスQuality Scoreは持たない。
- Knowledge Review & Promote Pipeline v1。SQLiteへDraft／provenance／Review状態／GitHub同期状態を永続化し、一覧・FTS検索・状態filter・編集可能Review・Approve／Reject・確認付きPromoteを提供する。`approved`だけを`projects/aitextapp/knowledge/`へnew-file-onlyで昇格し、成功時だけKnowledgeDocument、path、SHA、promotedAtを保存してローカルExternal Brain FTSへ即時反映する。Review操作はAI APIを呼ばず、lifecycle analyticsへsource type付きで記録する。
- Persona External Brain v2 / Knowledge Draft Pipeline。Human Thought／AI Reply／Persona Post／Daily Summaryから明示操作後だけAIでMarkdown Draftを生成し、decision／knowledge／memory／project-note／journalを選択できる。journalはHuman由来なら自分、AI由来なら生成元AIペルソナの当時の出来事・感情・考えを記録する。正式化後にAIが取得したjournalは過去を思い出す参考として扱い、現在の命令・恒久的な好み・現在も有効な確定事実へ自動的に一般化しない。ローカルFTSで関連する既存資料を最大3件確認し、編集可能Previewで内容と安全な`drafts/`保存先をHuman Reviewした後、既存Keychain tokenでGitHubへnew-file-only保存する。AI生成とGitHub保存は別操作で、保存失敗時もDraftを保持する。保存した`status: draft`は通常RAG対象外で、正式Knowledgeへの昇格は後続の明示Review／Promote Pipelineだけが行う。Knowledge Draft生成はUsage Analyticsへ記録し、GitHub writeはAI Callへ数えない。

- External Brain Routing v1。Persona別AGENT.mdのRetrieval RouteをAI Replyだけでなく独立Persona Postにも適用し、依頼文を検索queryとして最大5チャンクを取得する。空白で単語分割できない日本語自然文はtrigramへ展開し、長い一文との完全一致を要求せず関連Knowledgeを検索する。長いheading chunkは先頭固定ではなく検索一致箇所の周辺を1件最大2,000文字、合計最大約10,000文字までAIへ渡す。送信前にroute／source／heading／excerpt／最終payloadを確認でき、Usage metadataへ使用有無とchunk数を記録する。Daily SummaryにはPersona routeを適用しない。
- AI API Usage Analytics v1。AI機能タブから使用状況Dashboardを開く。AI API Callをschema v12内の独立したローカルMetadataとして記録し、AI Reply／Daily Summary／Persona Post／Knowledge Draftを共通Recorderへ統合する。Knowledge Draftはsource typeも保持する。Persona／Feature／Provider／Model別件数、成功率、Error、Latency、日別推移を集計し、External Brain使用有無・取得chunk数も保持する。token usageはproviderから取得できる場合だけ実測保存し、現状はnilのまま文字数を常時記録する。prompt／response／Thought／External Brain本文はUsage DBへ保存せず、Telemetry保存失敗は既存AI機能を失敗させない。
- Persona External Brain v1。単一GitHub RepositoryとPersona別AGENT.md／Retrieval Routeを使い、MarkdownをApplication SupportへSHA差分同期してheading単位のSQLite FTS5 indexから最大5チャンクを取得する。AI Reply送信前Previewで資料と最終payloadを確認できる。GitHubはread-only、tokenはKeychain保存で、障害時はcacheまたはExternal Brainなしで返信を継続する。
- 外部ブレイン接続済みPersonaの識別表示。GitHub接続確認に成功し、PersonaのAGENT.mdも同期済みのAIだけ、プロフィール・AI Persona一覧・Timeline・選択UIの名前横へメダル型バッジを表示する。設定済みだけ、未確認、同期待ち、接続失敗では表示しない。

- `TabView`によるHome／Mentions／AI機能／Insights／Profileの5タブ。各タブは独立した`NavigationStack`を持つ。Home上部の検索欄で本文検索し、右上の鉛筆から投稿Composerを開き、隣のフィルターから投稿者単位でTimelineを絞り込む。MentionsはHuman／AI Persona宛てのMentionとReplyをセグメントで分け、Homeと同じThought行デザインで表示する。AI機能はAI投稿依頼、AIペルソナ設定、AI使用状況、生成設定、OpenAI API key、外部ブレイン、ナレッジ下書きを集約する。InsightsはDaily Summary／Analytics、Profileは投稿一覧を持たない共通Actor Profile UIを表示し、一般設定はProfile右上へ置く。
- ローカルの単一人間Persona基盤。SQLite schema v6の`personas`／`thought_authors`で既存・新規Thoughtを固定のデフォルト人間へ紐づけ、表示名と512px以下へ正方形化したJPEGアイコンをSQLite内へ保存する。
- Timelineの投稿者名・丸型アイコン表示と、写真選択／削除／表示名編集を行うプロフィール画面。未設定時は標準人物アイコンを表示し、プロフィール変更を既存Thoughtへ一括反映する。
- 複数AI Personaの作成・編集・無効化UIと、投稿ごとの実Persona表示。任意Persona IDでThoughtを原子的に保存でき、通信はユーザーの明示操作時だけ行う。
- AI Personaごとの役割・指示設定と、明示的な「投稿を依頼」導線。ユーザー依頼と最終payloadをプレビューし、確定後だけFirebase AI Logicを呼び、140文字以内の成功応答だけをAI Persona名義でTimelineへ保存する。
- SQLite schema v7の`ai_persona_configurations`／`ai_post_generations`。AI設定と生成来歴をThought本文から分離し、Thought・投稿者・provider／model／prompt version／ユーザー依頼を同一transactionで保存する。自動投稿は行わない。
- AI Personaへの単一メンションv1。Timeline ComposerでactiveなAIを選択すると本文に`@handle`を挿入し、別Personaへの切替時は選択済みhandleを置換、解除時は本文からも除く。schema v8の`thought_mentions`へ本文と同じtransactionでPersona IDを保存する。Timelineは現在のPersona名を`@名前`で表示し、メンションだけではAI通信を開始しない。
- メンション付きThoughtから明示的に依頼するAI返信v1。送信前にAI、対象Thought、役割、指示、最終payload、provider／modelを確認し、対象Thoughtだけを送る。成功した140文字以内の応答はAI名義Thought、`repliesTo` Relation、返信先を含む生成来歴としてschema v9へatomic保存する。同一Thoughtへの複数返信を許可し、Detailで返信一覧を確認できる。
- AI Reply Context v1。対象Thoughtから`repliesTo`だけを遡る直近最大5件を、Human／AI投稿者付き・古い順で送信前previewとpromptへ含める。削除済み本文、Continuation、重複、cycleを除外し、送信直前のContext再取得でThought・Relation・投稿者・対象が変わっていればAIを呼ばない。Mentionだけでは通信しない。AI Replyへの人間返信は相手AIを自動メンションして同じReply chainへatomic保存する。
- AI Persona Reply v2。HumanがAI ThoughtへReplyすると相手AIをRelationから引き継ぎ、Reply Thread、Role／Instructions、同Personaの直近5発言、任意のExternal Brainで既存AI Reply promptを組み立てる。同一Human ReplyへのAI生成済みReplyはCore／SQLite双方で拒否する。Persona別`Auto Reply`はschema v17へ永続化し、既定ON。ONではHumanの@メンションを起点に承認なしで生成・atomic投稿する。AI投稿を起点にしないためAI同士の自動連鎖は行わない。
- Timeline Reply Context。Human／AI双方の返信を通常Timelineへ独立Thoughtとして表示し、`repliesTo`から取得した返信先Personaと本文を1行の文脈として添える。長い返信先本文は末尾を省略し、返信行の縦間隔を通常Thoughtより詰める。Human／AI返信の保存が成功したらDetailを閉じてTimelineへ戻り、失敗時は入力と画面を保持する。返信先本文は複製保存せず、削除済みの場合もRelationを保持してplaceholderを表示する。schema v15は`user_version`だけ進んで旧`continues`限定制約が残ったDBを実定義から検知・非破壊補修し、起動時DB health checkでその他の破損・必須schema欠落を即時検知する。
- Homeの返信表示切替。Homeはデフォルトで、rootに対する最初の返信だけを残し、返信への返信（2件目以降）を畳む。Home右上の会話ボタンで全返信との表示を切り替え、投稿直後の返信は畳み中でも一時表示して投稿結果を確認できる。
- Daily Summary v3。`ThoughtRepository.fetchHumanThoughts(from:to:)`が`thought_authors`と`personas.kind`をRepository／SQLite JOINで判定し、期間内・未削除のHuman Thoughtだけを取得する。AI投稿／自動返信／返信／フリートーク本文はprompt・件数・タグ・テーマ・思考の流れ・Continuation集計から完全に除外する。Mention先は判定に影響しない。要約済みの過去日も「この日を再生成」から最新promptで送信前Previewへ進み、新しい生成が成功した場合だけ日付単位で旧Summaryを置き換える。既存v1／v2 Summaryと`aiInteractions`は削除せず後方互換で読めるが、新規v3生成では`aiInteractions`を要求・保存しない。AI側の活動は将来の独立したAI Summaryの責務とする。
- サマリー閲覧専用ページ。振り返りから生成済みサマリーを種別・対象日・概要付きで新しい順に確認でき、詳細には再生成・外部脳保存・タグ追加などの変更操作を置かない。現時点の種別はデイリーだけだが、生成カレンダーと閲覧導線を分離して将来の週次／月次追加先を明確にする。
- AI Tag Suggestions。Daily SummaryがHuman Thoughtのprompt連番単位でタグ名・理由を提案し、生成後に有効なHuman indexだけを内部Thought IDへ解決する。確定タグ分析とは分離し、不正indexとAI Thought候補を除外する。Detailの「追加」を押した場合だけ既存`ThoughtTagRepository`の独立transactionで確定タグにする。
- 振り返り導線をDaily Summaryへ統一。TimelineのHistory Review入口と画面、旧期間AI要約UIを外し、既存の`review_summaries`はデータ互換のためSQLite内に保持する。
- Timelineトップバーの独立タグ一覧ボタンを外し、Thoughtに付いたタグは`tag.fill`と名前を組み合わせて文脈内で識別しやすく表示する。

- 端末Calendar／timezoneの1日境界で明示生成するDaily Summary v3。月カレンダーで要約済み／Human Thoughtあり未要約／Human Thoughtなしと今日を区別し、過去日の日別詳細、Human Thoughtだけの送信前preview、構造化結果の表示と再読込を提供する。
- SQLite schema v5の`daily_summaries`。Thought原文と分離した1日1件の正式Summaryとして構造化結果と生成メタデータを保存し、AI候補からタグ／Thought／Continuationを自動変更しない。
- タグチップ、タグ追加、タグ編集ボタンの操作領域を44pt以上へ拡大。

- 140文字制限、空白除去、空投稿防止を備えた投稿Composer。
- 新しい順のTimeline、投稿日時、削除確認と即時反映。
- UUIDと作成・更新・削除日時を持つThought原文モデル。
- Application Support配下のSQLiteを正本にしたローカル保存、query順序、ソフトデリート。
- 既存JSONをtransaction内で検証して一度だけ取り込む、再実行可能なmigration。
- `PRAGMA user_version`によるschema version管理（現在v21）。v14は実カラム補修、v15はReply Relation制約補修、v16はActor handle／Mention snapshot、v17はAI Persona Auto Reply、v18は旧`account_id`単独UNIQUE制約の非破壊補修、v19はAI Persona provider、v20は週間Summary／Plan、v21は独立したApps / Tools catalogを非破壊追加する。
- Home右上の鉛筆アイコンから開き、入力へ自動focusする投稿Composer。投稿操作はNavigation bar右上に置き、空入力や140文字超過時は無効化する。
- Lazy Timeline、自然な相対日時、Thought本文のコピー、メニュー内削除、Empty State。Timeline・詳細・会話履歴の各操作メニューから本文全体をペーストボードへコピーできる。Home／Mentionsは初回50件だけをSQLiteから取得し、末尾到達時に50件ずつ追加取得する。追加取得は`OFFSET`ではなく作成日時とUUIDのkeyset cursorを使い、全件読込を避ける。
- interactiveなキーボードdismiss、Dynamic Type、Dark Mode、VoiceOver向けsemantic UI。
- iOS 16以降用SwiftUIアプリ、Xcode project/shared scheme。
- 投稿ルール、順序、Unicode、削除、ファイル再読込のSwift Testingテスト。
- Repository経由のMarkdown／JSON ExportとiOS標準Share Sheet。
- SQLiteの直近2世代ローリングバックアップ。
- 投稿・削除主要フローのXCUITest target。
- Thought本文と分離した`ThoughtRelation`モデル（`continues`）と、source=新しいThought／target=元Thoughtの固定方向。
- SQLite schema v2、Relationの外部キー・index・重複／self relation制約。
- parent／continuationの1ステップ取得と、Thought作成＋Relation作成の原子的transaction境界。
- Soft Delete後もRelationを保持するThought History基盤と、単純なcycle防止。
- Timelineから開くThought Detail、現在位置を示す縦型History、履歴内移動。
- 既存140文字ルールとatomic transactionを使う「続きを書く」Composer。
- 分岐Continuationの安定順表示と、削除済みThoughtのHistory placeholder。
- Timeline／History／Continuation操作のVoiceOver labelとaccessibility identifier。
- `createdAt`昇順の安定したReview表示、Thought Detailへの遷移、Continuation件数の軽量表示。
- SQLiteの日付範囲query（開始inclusive／終了exclusive）とRelation件数の一括query。
- Files／iCloud Driveのユーザー選択フォルダへSQLite Online Backup APIの完全snapshotを保存する外部災害復旧バックアップ。
- Thought原文と分離したSQLite schema v3の`review_summaries`と、通信／保存を抽象化した要約use case。
- Firebase Apple SDK 12.17.0以降の`FirebaseAILogic`／`FirebaseAppCheck`／`FirebaseCore`依存と、Gemini／OpenAIをrequest単位で選ぶcomposition root。
- Daily Summaryの確定promptをOpenAI `gpt-5.6-luna`へmediumで送り、成功時だけ既存SQLite保存へ進む実クライアント。Gemini transportはPersona系と選択時のKnowledge Draftに利用する。
- Firebase未設定、App Check、rate limit、network、その他API、空応答を区別するエラー境界。DebugはApp Check Debug Provider、ReleaseはApp AttestをFirebase初期化前に設定する。
- SDK非依存transportによるFirebaseクライアント変換テスト。MockクライアントはCore／UIテスト用として維持。
- 選択期間ごとのAI要約履歴画面。再要約結果を新しい順に表示し、最新、生成日時、対象件数、生成元を確認可能。
- AI要約履歴から要約ID単位で削除する確認付き操作。最新要約の再選択、全件削除後の未生成表示、失敗表示に対応。
- AI要約の送信前プレビュー。対象期間、件数、最終payload文字数、本文文字数、日時順Thoughtを表示し、明示確定時だけ送信。
- プレビュー時の最終requestを固定し、送信直前に期間内Thoughtを再取得して一致しない場合は送信を中止する整合性確認。
- AI要約履歴の各レコードをMarkdown／JSONで個別Exportする形式選択とiOS標準Share Sheet導線。
- Thought本文・promptを含まないAI要約専用Export modelと、将来の解析／再Importを見据えたJSON schema v1。
- `latest`／`previous`の外部2世代、version・schema・サイズ・SHA-256を持つmanifest、作成後検証と失敗時rollback。
- security-scoped bookmarkによる保存先再利用、Restore事前検証・確認UI・次回起動前のatomic適用と現DB rollback。
- Home上部の標準`.searchable`で本文の部分一致検索を入力中に更新し、0件表示、日時、新しい順、Detail遷移を提供。
- `ThoughtRepository.search(query:)`検索境界と、SQLiteのbind済み`LIKE ... ESCAPE` query、テスト用Memory Repository実装。前後空白、`%`／`_`のliteral検索、deleted除外に対応（検索導入自体ではschema変更なし）。
- Thought原文と分離した`ThoughtTag`／`ThoughtTagRepository`、SQLite schema v4の`tags`／`thought_tags`。正規化名と複合主キーでタグ名・付与の重複を防止。
- Thought Detailのタグ確認・編集、既存タグ付与、新規タグ作成、個別解除。Timeline／本文検索結果の最大2件＋省略表示、タグ一覧、タグ別Thought一覧、既存Detailへの遷移。
- タグ追加／解除transaction、deleted Thoughtを除外するタグ一覧・タグ別query、v1〜v3から既存Thoughtを保持するmigration経路。
- Timelineから開くローカル分析画面。今日／過去7日／過去30日、活動日数、1活動日平均、30日の日別カレンダー（件数・濃淡・今日の枠線）、曜日別・時間帯別分布、上位5タグ、Continuationを持つThought数を表示。
- typed分析model、端末Calendarから30日の日／時間帯境界を構築する`LoadThoughtAnalytics`、CRUDから分離したread-only `ThoughtAnalyticsRepository`。
- Daily Summary v3: Calendar日境界、RepositoryでのHuman限定取得、Humanタグ／Relation／時間帯分析、OpenAI `medium`の構造化応答、既存Summary互換の独立SQLite保存、月間カレンダー、日別詳細、Timeline統合。AI Summaryは未実装で別責務。
- SQLiteの境界CTE＋`COUNT`／`GROUP BY`、タグJOIN集計、activeな期間内親子のRelation集計。原文全件をViewへ取得せず、deleted／期間外ThoughtをSQLで除外する。

## 未実装

- Release用App Attest providerのFirebase Console登録と実機通信。Debug Providerは実機で実通信とSQLite保存を確認済み。
- Apps / Tools Hubの一覧／追加／編集UI、Native route解決、URL／Local Web／Deep Link起動。WebViewは未導入。
- AI側の活動だけを対象にした独立AI Summary、Monthly Review。
- 利用者アカウント、独自バックエンド、クラウド同期、複数端末同期、Claude生成経路。
- CI/CD、配布用の署名・bundle identifier設定。

## 外部APIの現在地

- Gemini: Firebase AI LogicとApp Checkを使い、AI Persona投稿／返信と選択時のKnowledge Draftを生成する。Debug Providerの実機接続は確認済み。Release App AttestのFirebase Console登録と実機通信が未確認。
- OpenAI: 個人所有端末限定の暫定構成として、Keychain保存keyからResponses APIへ直接接続する。Daily Summary、Weekly Review、Persona系、Knowledge Draftに用途別profileを適用する。配布前にバックエンド＋Secret管理へ移行する。
- GitHub: External Brainのread／sync、Knowledge Draft保存・削除、PromoteにGitHub APIを利用する。PATはKeychainへ保存する。
- Claude: 設定画面の未対応表示だけで、生成APIは呼ばない。

秘密情報、用途別model、接続手順、配布前の移行条件は`OPERATIONS.md`と`decisions/0005-firebase-ai-logic-app-check.md`、`decisions/0007-personal-device-openai-keychain.md`を参照する。

## 既知の問題

- Swift 6.3で`ThoughtCore/ExternalBrain.swift`の`compactMap`要素型を推論できず、最新の`swift test`とDebug Simulator buildがcompileで停止する。
- schema v20の新規DB round-trip testは存在するが、明示的なschema v19 fixtureからv20へのmigration testが未追加。
- Apps / Tools HubのDomain、SQLite CRUD、schema v20→v21 migration testは追加済みだが、Windows環境のため未実行。
- 週間振り返りと日記の最新修正はSimulatorでの画面確認が未完了。
- Daily Summary統一後を含む最新XCUITest、Light／Dark Mode、Dynamic Type、VoiceOverの回帰確認が必要。
- 破損した移行元JSONは自動復旧せず、SQLiteへの移行を中止してエラー表示し、原本を保持します。

## 次に行うこと

1. Swift 6.3 compile blockerを局所修正し、`swift test`とDebug Simulator buildを回復する。
2. schema v19→v20 migration testを追加し、追加済みのv20→v21 migration testと合わせて実行する。
3. `MAC_VALIDATION.md`の残項目を実施し、最新baselineを確定する。
4. Apps / Tools一覧／編集の最小SwiftUIと、起動前確認を持つapp layerのlaunch policyをMacで実装・検証する。
5. Release App Attestを実機確認する。配布を検討する場合はOpenAI直接接続の廃止を先に行う。

次期候補の比較、Apps / Tools Hub v1のscope、security checklist、設計開始条件は`NEXT_FEATURES.md`を参照する。
